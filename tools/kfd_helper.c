/* ============================================================================
 * kfd_helper.c — TrollAgent 免越狱信任注入 helper (iOS 16.x)
 *
 * 目标: 在 TrollStore 假签名、非越狱环境下，让 NECP 认可 packet-tunnel 扩展，
 *       使 system VPN 真连。机制对齐 Fuck 工具箱的 FuckKfdHelper：
 *
 *   kopen(puaf_landa) 临时拿内核读写（免越狱、用完退出）
 *     → patchfind 定位 pmap_image4_trust_caches（扫内核镜像特征，见下）
 *     → 分配一块内核内存构造 trust_cache（含目标 cdhash）
 *     → 调用 pmap_image4_trust_caches 把它注册进内核信任缓存
 *     → 系统把假签名的 VpnTunnel.appex 当合法签名信任 → NECP 放行
 *     → kclose 退出（不留痕，设备仍非越狱）
 *
 * 用法:
 *   kfd_helper --cdhash <hex40>          # 直接给 cdhash（40 位 hex）
 *   kfd_helper <appex_macho_path>        # 自动提取 VpnTunnel.appex 的 cdhash
 *
 * 依赖: libkfd（Felix-pb/libkfd，puaf_landa 支持 iOS 15.5–16.6.1）
 *
 * 编译（macOS，见 tools/build_kfd_helper.sh / CI）:
 *   xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=14.0 \
 *       -Ilibkfd -Itools kfd_helper.c libkfd/... -o kfd_helper
 *
 * ⚠️ 未完成项（见 Support/kfd/README.md）:
 *   ✅ kopen 偏移表(dynamic_info)已整合现成数据:
 *        tools/kfd/dynamic_info.h — iOS 16.3 A12–A16 + iOS 16.6, 来自 Lrdsnow/kfd_offsets + felix-pb/kfd。
 *   ✅ pmap_image4_trust_caches 定位改为运行时 patchfind（对齐 FuckKfdHelper 实测机制）：
 *        FuckKfdHelper 反汇编证明其【无静态偏移表】，而是扫内核镜像 __text 匹配
 *        pmap_image4_trust_caches 的序言特征指令（mov w0,#5 / add x3,x31,#8 /
 *        mov x29,sp / sub sp,sp 等），见 patchfind_pmap()。这解释了为何网上
 *        搜不到该私有符号偏移——内核函数地址随每次镜像编译变化，只能运行时扫描。
 *   ⬜ kalloc / 调用 pmap_image4_trust_caches 的内核代码执行原语未实现
 *        （libkfd 仅提供 kread/kwrite，无 kcall/内核线程；Fuck 的调用机制见 0x10001055c
 *        为间接 blr 封装，需继续逆向其 kcall 或改用业界"改内核函数指针触发"方案）。
 * ========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <CommonCrypto/CommonDigest.h>   // CC_SHA256 — 算 cdhash

/* mach-o/codesign.h 在 iPhoneOS SDK 缺失（macOS 私有头）。
 * 所需 cs_superblob/cs_blobindex/cs_codedirectory 结构已在本文件第 2 节自定义；
 * 此处仅补 libkfd/内核侧引用的 4 个 codesign 宏常量。 */
#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0u
#define CSSLOT_CODEDIRECTORY       0
#define CS_HASHTYPE_SHA1           1
#define CS_HASHTYPE_SHA256         2

/* libkfd 公开 API（以你 clone 的版本为准，这里按通用签名占位）
 * 实际引入方式见 tools/build_kfd_helper.sh（-I 指向 libkfd 根目录） */
#include "libkfd.h"

/* ------------------------------------------------------------------ */
/* 1. patchfind —— 运行时定位 pmap_image4_trust_caches（无静态偏移表）  */
/*    对齐 FuckKfdHelper 反汇编机制：扫内核镜像 __text 匹配序言特征。   */
/* ------------------------------------------------------------------ */
static uint32_t kread32(struct kfd *k, uint64_t addr) {
    uint32_t v = 0;
    kread((u64)k, addr, &v, sizeof(v));
    return v;
}

/* 扫 0xfeedfacf (MH_MAGIC) 定位内核 mach_header → 内核镜像基址。
 * FuckKfdHelper 同款逻辑（其 0x10001f480 用 w22=0xfeedfacf 循环扫描）。
 * gVirtBase 由 libkfd perf 提供；兜底用常规静态基址 + slide。 */
static uint64_t patchfind_kernel_base(struct kfd *k) {
    uint64_t base = k->perf.gVirtBase;
    if (!base) base = 0xfffffff007004000ULL + k->perf.kernel_slide;
    /* 向下 4MB 内找 magic（内核镜像 __TEXT 在 gVirtBase 附近） */
    for (uint64_t a = base; a > base - 0x400000; a -= 0x1000) {
        if (kread32(k, a) == 0xfeedfacf) return a;
    }
    /* 向上兜底 */
    for (uint64_t a = base; a < base + 0x400000; a += 0x1000) {
        if (kread32(k, a) == 0xfeedfacf) return a;
    }
    return base;
}

/* 扫内核 __text 匹配 pmap_image4_trust_caches 序言特征，返回其（slide 后）地址。
 * 特征（反汇编 FuckKfdHelper 0x10001f71c patchfind 提取，每条 4 字节）:
 *   +0x0  0x910023e3   add x3, x31, #8
 *   +0x4  0x528000a0   mov w0, #5
 *   +0x8  0x52800402   mov w0, #imm   (0x528000a0 + 0x362)
 *   +0xc  0x52800104   mov w0, #imm   (0x528000a0 + 0x64)
 *   +0x10 高6位==0x25   (bits26-31 opcode)
 * 命中后反向扫 mov x29,sp (0x910003fd & 0xff8003ff) 定位函数真正起点。
 * 返回 0 表示未找到。 */
static uint64_t patchfind_pmap(struct kfd *k) {
    uint64_t kbase = patchfind_kernel_base(k);
    uint64_t start = kbase + 0x1000;            /* __TEXT 段头部起 */
    uint64_t end   = kbase + 0x800000;          /* 扫 8MB 覆盖 __text */
    for (uint64_t a = start; a < end; a += 4) {
        uint32_t i0 = kread32(k, a);
        if (i0 != 0x910023e3) continue;
        if (kread32(k, a + 4) != 0x528000a0) continue;
        if (kread32(k, a + 8) != 0x52800402) continue;
        if (kread32(k, a + 0xc) != 0x52800104) continue;
        if ((kread32(k, a + 0x10) >> 0x1a) != 0x25) continue;
        /* 主序列命中：反向找函数序言 mov x29,sp */
        uint64_t fn = a;
        for (uint64_t b = a; b > a - 0x4000; b -= 4) {
            uint32_t v = kread32(k, b);
            if ((v & 0xff8003ff) == 0x910003fd) { fn = b; break; }
        }
        return fn;
    }
    return 0;
}

/* trust_cache 结构（XNU: osfmk/kern/syspolicy.c, TRUST_CACHE / TC_VERSION） */
#define TC_VERSION 1
struct trust_cache {
    uint32_t version;      /* 0x1 */
    uint32_t uuid[4];      /* 16 bytes random */
    uint32_t num_entries;  /* 每项 32 字节（SHA-256 截断 cdhash 存 20，其余填充） */
    /* uint8_t entries[0][32]; */
} __attribute__((packed));

/* ------------------------------------------------------------------ */
/* 2. cdhash 提取（读 Mach-O 的 LC_CODE_SIGNATURE → superblob → CD）    */
/* ------------------------------------------------------------------ */
typedef struct __attribute__((packed)) {
    uint32_t magic;   /* 0xfade0cc0 superblob */
    uint32_t length;
    uint32_t count;
} cs_superblob;

typedef struct __attribute__((packed)) {
    uint32_t type;    /* 0 = CodeDirectory */
    uint32_t offset;
    uint32_t length;
} cs_blobindex;

typedef struct __attribute__((packed)) {
    uint32_t magic;         /* 0xfade0c02 */
    uint32_t length;
    uint32_t version;
    uint32_t flags;
    uint32_t hashOffset;
    uint32_t identOffset;
    uint32_t nSpecialSlots;
    uint32_t nCodeSlots;
    uint32_t codeLimit;
    uint8_t  hashSize;
    uint8_t  hashType;      /* 1=SHA1, 2=SHA256, 3=SHA384 */
    uint8_t  platform;
    uint8_t  pageSize;
    uint32_t spare2;
    uint32_t scatterOffset;
    uint32_t teamOffset;
    uint32_t spare3;
    uint64_t codeLimit64;
    uint64_t execSegBase;
    uint64_t execSegLimit;
    uint64_t execSegFlags;
} cs_codedirectory;

static int load_file(const char *path, uint8_t **out, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END); long sz = ftell(f); rewind(f);
    uint8_t *buf = malloc(sz); if (!buf) { fclose(f); return -1; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) { free(buf); fclose(f); return -1; }
    fclose(f);
    *out = buf; *out_len = (size_t)sz;
    return 0;
}

/* 从 Mach-O（支持 fat 或 thin）提取 CodeDirectory，并按 Apple 规则算 cdhash(20B)。
 * 返回 0 成功；-1 失败。 */
static int extract_cdhash(const uint8_t *macho, size_t len, uint8_t cdhash[20]) {
    const uint8_t *p = macho;
    size_t plen = len;
    /* fat 头？取 arm64 slice */
    if (len >= sizeof(struct fat_header) && ((struct fat_header *)macho)->magic == FAT_MAGIC) {
        struct fat_header *fh = (struct fat_header *)macho;
        uint32_t nfat = OSSwapBigToHostInt32(fh->nfat_arch);
        struct fat_arch *ar = (struct fat_arch *)(macho + sizeof(struct fat_header));
        for (uint32_t i = 0; i < nfat; i++) {
            if (OSSwapBigToHostInt32(ar[i].cputype) == CPU_TYPE_ARM64) {
                uint32_t off = OSSwapBigToHostInt32(ar[i].offset);
                uint32_t sz  = OSSwapBigToHostInt32(ar[i].size);
                p = macho + off; plen = sz; break;
            }
        }
    }
    struct mach_header_64 *mh = (struct mach_header_64 *)p;
    if (mh->magic != MH_MAGIC_64) return -1;

    /* 遍历 load commands 找 LC_CODE_SIGNATURE (0x1d) */
    const uint8_t *cmds = p + sizeof(struct mach_header_64);
    uint32_t ncmd = mh->ncmds;
    uint32_t lcmd_off = 0;
    for (uint32_t i = 0; i < ncmd; i++) {
        struct load_command *lc = (struct load_command *)(cmds + lcmd_off);
        if (lc->cmd == LC_CODE_SIGNATURE) {
            struct linkedit_data_command *sig = (struct linkedit_data_command *)lc;
            lcmd_off = sig->dataoff;
            break;
        }
        lcmd_off += lc->cmdsize;
    }
    if (lcmd_off == 0 || lcmd_off + 4096 > plen) return -1;

    cs_superblob *sb = (cs_superblob *)(p + lcmd_off);
    if (sb->magic != CSMAGIC_EMBEDDED_SIGNATURE /*0xfade0cc0*/) return -1;
    cs_blobindex *idx = (cs_blobindex *)((uint8_t *)sb + sizeof(cs_superblob));
    for (uint32_t i = 0; i < sb->count; i++) {
        if (idx[i].type == CSSLOT_CODEDIRECTORY /*0*/) {
            cs_codedirectory *cd = (cs_codedirectory *)((uint8_t *)sb + idx[i].offset);
            /* cdhash = hash(CodeDirectory data)；按 hashType 取前 20 字节 */
            if (cd->hashType == CS_HASHTYPE_SHA256 /*2*/) {
                uint8_t dig[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256((uint8_t *)cd, idx[i].length, dig);
                memcpy(cdhash, dig, 20);
                return 0;
            } else if (cd->hashType == CS_HASHTYPE_SHA1 /*1*/) {
                CC_SHA1((uint8_t *)cd, idx[i].length, cdhash);
                return 0;
            }
        }
    }
    return -1;
}

/* ------------------------------------------------------------------ */
/* 3. 信任缓存注入                                                       */
/* ------------------------------------------------------------------ */
static int inject_trust_cache(struct kfd *kfd, const uint8_t cdhash[20]) {
    /* pmap_image4_trust_caches 地址 = 运行时 patchfind（无静态偏移表） */
    uint64_t kbase = patchfind_kernel_base(kfd);
    fprintf(stderr, "[kfd-helper] kernel_base=0x%llx slide=0x%llx\n",
            kbase, kfd->perf.kernel_slide);
    uint64_t pmap = patchfind_pmap(kfd);
    if (!pmap) {
        fprintf(stderr, "[kfd-helper] patchfind pmap_image4_trust_caches FAILED\n");
        return -1;
    }
    uint64_t slide = kfd->perf.kernel_slide;
    fprintf(stderr, "[kfd-helper] pmap_image4_trust_caches slid=0x%llx (slide=0x%llx)\n", pmap, slide);

    size_t tc_size = sizeof(struct trust_cache) + 32;
    /* TODO: 内核分配一块可写内存放 trust_cache。
     * libkfd 无 kalloc；Fuck 用 krkw allocate 复用内核对象（0x10001f97c），
     * 或需自行实现 kalloc（迁移页面/复用 fileproc 对象区）。 */
    uint64_t tc_kaddr = 0; /* = kfd_kalloc(kfd, tc_size); */
    if (!tc_kaddr) {
        fprintf(stderr, "[kfd-helper] KALLOC NOT IMPLEMENTED — 卡点：非越狱内核内存分配\n");
        return -1;
    }

    /* 构造 trust_cache */
    uint8_t tc[sizeof(struct trust_cache) + 32];
    memset(tc, 0, sizeof(tc));
    struct trust_cache *h = (struct trust_cache *)tc;
    h->version = TC_VERSION;
    /* uuid 随机即可 */
    arc4random_buf(h->uuid, 16);
    h->num_entries = 1;
    memcpy(tc + sizeof(struct trust_cache), cdhash, 20); /* 项：32 字节，cdhash 前 20 */

    /* TODO: kwrite_buf(kfd, tc_kaddr, tc, tc_size); */

    /* TODO: 调用 pmap_image4_trust_caches(tc_kaddr)。
     *       调用内核函数的原语因 libkfd 版本而异——常用做法：
     *       a) kfd 提供的 call 原语（若有）
     *       b) 找 ret 滑板 / 改内核函数指针后触发
     *       此处以 placeholder 表示，需按你的 libkfd 版本实现。 */
    /* kfd_call(kfd, pmap, tc_kaddr); */

    /* TODO: 成功后可选释放 tc_kaddr（kalloc_free） */
    fprintf(stderr, "[kfd-helper] trust cache injected (pmap=%llx slide=%llx)\n", pmap, slide);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 4. main                                                              */
/* ------------------------------------------------------------------ */
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s --cdhash <hex40> | <appex_macho_path>\n", argv[0]);
        return 1;
    }

    uint8_t cdhash[20];
    const char *arg = argv[1];

    if (strcmp(arg, "--cdhash") == 0) {
        if (argc < 3 || strlen(argv[2]) != 40) {
            fprintf(stderr, "--cdhash requires 40 hex chars\n");
            return 1;
        }
        for (int i = 0; i < 20; i++) {
            unsigned v;
            if (sscanf(argv[2] + i * 2, "%2x", &v) != 1) return 1;
            cdhash[i] = (uint8_t)v;
        }
    } else {
        uint8_t *macho; size_t len;
        if (load_file(arg, &macho, &len) != 0) {
            fprintf(stderr, "cannot read %s\n", arg); return 1;
        }
        if (extract_cdhash(macho, len, cdhash) != 0) {
            fprintf(stderr, "cannot extract cdhash from %s\n", arg); return 1;
        }
        free(macho);
        fprintf(stderr, "[kfd-helper] cdhash=%s\n", argv[1]);
        for (int i = 0; i < 20; i++) fprintf(stderr, "%02x", cdhash[i]);
        fprintf(stderr, "\n");
    }

    /* libkfd 公开 API: kopen(u64 puaf_pages, u64 puaf_method, u64 kread_method, u64 kwrite_method)
     * puaf_landa 支持 iOS 15.0–16.6.1（CVE-2023-41974，16.7 已修），本设备 iOS 16.3 在区间内。
     * dynamic_info 偏移表见 tools/kfd/dynamic_info.h（build 时覆盖 libkfd 同名文件）。 */
    struct kfd *kfd = (struct kfd *)kopen(2048, puaf_landa, kread_kqueue_workloop_ctl, kwrite_dup);
    if (!kfd) { fprintf(stderr, "kopen(puaf_landa) FAILED — 设备 iOS 需在 15.0–16.6.1\n"); return 1; }
    fprintf(stderr, "[kfd-helper] kopen OK slide=0x%llx\n", kfd->perf.kernel_slide);

    int rc = inject_trust_cache(kfd, cdhash);

    kclose((u64)kfd);
    fprintf(stderr, "[kfd-helper] %s\n", rc == 0 ? "ok" : "failed");
    return rc == 0 ? 0 : 1;
}
