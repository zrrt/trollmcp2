/* ============================================================================
 * kfd_helper.c — TrollAgent 免越狱信任注入 helper (iOS 16.x) — 胶水版 v3.6.18
 *
 * 目标: 在 TrollStore 假签名、非越狱环境下，让 NECP 认可 packet-tunnel 扩展，
 *       使 system VPN 真连。
 *
 * 本版本为【胶水实现】（路线 A）：不再自行 kopen/patchfind/kalloc/调用内核，
 * 而是把注入工作交给同目录下的 FuckKfdHelper 注入引擎（来自 Fuck 工具箱，
 * 已在 iOS 16.3 巨魔上验证有效，机制已完整逆向）：
 *
 *   本程序职责：
 *     1) 从 VpnTunnel.appex 的 Mach-O 里提取 20 字节 cdhash（40 位 hex）
 *     2) posix_spawn 同目录下 Resources/bin/fuck_helper，把 cdhash 传给它
 *     3) fuck_helper 内部：kopen(puaf_landa) → patchfind pmap_image4_trust_caches
 *        → IOSurface kalloc 内核内存 → kwrite 写 trust_cache → DMA 物理写注册
 *        → kread 校验 → kclose 退出（免越狱、不留痕）
 *     4) 返回其退出码（0=注入成功，可继续起 VPN）
 *
 * 用法（与旧版完全兼容，TrustEnabler 无需改动）:
 *   kfd_helper --cdhash <hex40>          # 直接给 cdhash（40 位 hex）
 *   kfd_helper <appex_macho_path>        # 自动提取 VpnTunnel.appex 的 cdhash
 *
 * 依赖: 无（纯 C + CommonCrypto + posix_spawn），不依赖 libkfd。
 *       FuckKfdHelper 的机制逆向见 Support/kfd/README.md。
 * ========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <libgen.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <CommonCrypto/CommonDigest.h>   // CC_SHA256 / CC_SHA1 — 算 cdhash

/* mach-o/codesign.h 在 iPhoneOS SDK 缺失（macOS 私有头）。
 * 所需 cs_superblob/cs_blobindex/cs_codedirectory 结构已在本文件自定义。 */
#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0u
#define CSSLOT_CODEDIRECTORY       0
#define CS_HASHTYPE_SHA1           1
#define CS_HASHTYPE_SHA256         2

/* ------------------------------------------------------------------ */
/* cdhash 提取（读 Mach-O 的 LC_CODE_SIGNATURE → superblob → CD）      */
/* 注意：codesign 的 superblob/blobindex 整段是 big-endian（magic      */
/* 0xfade0cc0 存为 fa de 0c c0），必须显式大小端转换，否则提取失败。   */
/* ------------------------------------------------------------------ */
static inline uint32_t be32(uint32_t x) { return __builtin_bswap32(x); }
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
    uint8_t *buf = malloc((size_t)sz); if (!buf) { fclose(f); return -1; }
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
    /* fat 头？取 arm64 slice。注意 fat 也是 big-endian：文件里 magic 存为
     * ca fe ba be，小端读得 0xbebafeca = FAT_CIGAM（不是 FAT_MAGIC）。 */
    if (len >= sizeof(struct fat_header) && ((struct fat_header *)macho)->magic == FAT_CIGAM) {
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
    uint32_t sigoff = 0;
    uint32_t off = 0;
    for (uint32_t i = 0; i < ncmd; i++) {
        struct load_command *lc = (struct load_command *)(cmds + off);
        if (lc->cmd == LC_CODE_SIGNATURE) {
            sigoff = ((struct linkedit_data_command *)lc)->dataoff;
            break;
        }
        off += lc->cmdsize;
    }
    if (sigoff == 0 || sigoff + 4096 > plen) return -1;

    cs_superblob *sb = (cs_superblob *)(p + sigoff);
    if (be32(sb->magic) != CSMAGIC_EMBEDDED_SIGNATURE) return -1;
    uint32_t sbcount = be32(sb->count);
    if (sbcount > 0x1000) return -1; /* 防御：异常 count 防越界 */
    cs_blobindex *idx = (cs_blobindex *)((uint8_t *)sb + sizeof(cs_superblob));
    for (uint32_t i = 0; i < sbcount; i++) {
        if (be32(idx[i].type) == CSSLOT_CODEDIRECTORY) {
            uint32_t cdoff = be32(idx[i].offset);
            /* 注意：blobindex.length 不代表 CD 总长（常为 2），cdhash 的 hash
             * 作用于整个 CodeDirectory，长度必须用 CD 自身 header 的 length 字段
             * （big-endian，cs_codedirectory 第 2 个字段）。 */
            uint64_t cdabs = (uint64_t)sigoff + cdoff;
            if (cdabs + 44 > plen) return -1;              /* 至少读到 length+hashType */
            cs_codedirectory *cd = (cs_codedirectory *)((uint8_t *)sb + cdoff);
            uint32_t cdlen = be32(cd->length);
            if (cdlen < 44 || cdabs + cdlen > plen) return -1; /* 越界保护 */
            if (cd->hashType == CS_HASHTYPE_SHA256) {
                uint8_t dig[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256((uint8_t *)cd, cdlen, dig);
                memcpy(cdhash, dig, 20);
                return 0;
            } else if (cd->hashType == CS_HASHTYPE_SHA1) {
                CC_SHA1((uint8_t *)cd, cdlen, cdhash);
                return 0;
            }
        }
    }
    return -1;
}

/* ------------------------------------------------------------------ */
/* codesign 诊断：提取失败时 dump superblob/CD 详情到 stderr，便于定位  */
/* 真机 TrollStore 重签后为何无法提取 cdhash。                         */
/* ------------------------------------------------------------------ */
static void dump_codesign(const uint8_t *macho, size_t len) {
    struct mach_header_64 *mh = (struct mach_header_64 *)macho;
    if (mh->magic != MH_MAGIC_64) { fprintf(stderr, "diag: not MH_MAGIC_64 (magic=%08x)\n", mh->magic); return; }
    const uint8_t *cmds = macho + sizeof(struct mach_header_64);
    uint32_t ncmd = mh->ncmds, sigoff = 0, off = 0;
    for (uint32_t i = 0; i < ncmd; i++) {
        struct load_command *lc = (struct load_command *)(cmds + off);
        if (lc->cmd == LC_CODE_SIGNATURE) { sigoff = ((struct linkedit_data_command *)lc)->dataoff; break; }
        off += lc->cmdsize;
    }
    fprintf(stderr, "diag: sigoff=%u filelen=%zu\n", sigoff, len);
    if (sigoff == 0 || sigoff + 12 > len) { fprintf(stderr, "diag: no/invalid code signature\n"); return; }
    cs_superblob *sb = (cs_superblob *)(macho + sigoff);
    fprintf(stderr, "diag: superblob magic=%08x length=%u count=%u\n",
            be32(sb->magic), be32(sb->length), be32(sb->count));
    uint32_t cnt = be32(sb->count);
    cs_blobindex *idx = (cs_blobindex *)((uint8_t *)sb + sizeof(cs_superblob));
    for (uint32_t i = 0; i < cnt && i < 8; i++) {
        fprintf(stderr, "diag: idx[%u] type=%u off=%u len=%u\n",
                i, be32(idx[i].type), be32(idx[i].offset), be32(idx[i].length));
        if (be32(idx[i].type) == CSSLOT_CODEDIRECTORY && be32(idx[i].offset) + 44 <= len - sigoff) {
            cs_codedirectory *cd = (cs_codedirectory *)((uint8_t *)sb + be32(idx[i].offset));
            fprintf(stderr, "diag:   cd magic=%08x len=%u hashSize=%u hashType=%u\n",
                    be32(cd->magic), be32(cd->length), cd->hashSize, cd->hashType);
        }
    }
}

/* ------------------------------------------------------------------ */
/* posix_spawn 调用同目录下的 fuck_helper（FuckKfdHelper 注入引擎）     */
/* ------------------------------------------------------------------ */
static int run_fuck_helper(const char *helper_path, const char *cdhash_hex) {
    pid_t pid = 0;
    char *const argv[] = { (char *)helper_path, (char *)cdhash_hex, NULL };
    char *const envp[] = { "HOME=/var/mobile", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };

    int rc = posix_spawn(&pid, helper_path, NULL, NULL, argv, envp);
    if (rc != 0) {
        fprintf(stderr, "[kfd-helper] spawn %s failed rc=%d\n", helper_path, rc);
        return -1;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status)) {
        fprintf(stderr, "[kfd-helper] fuck_helper did not exit normally (status=%d)\n", status);
        return -1;
    }
    int code = WEXITSTATUS(status);
    fprintf(stderr, "[kfd-helper] fuck_helper exit=%d\n", code);
    return code == 0 ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* main                                                              */
/* ------------------------------------------------------------------ */
int main(int argc, char **argv) {
    /* 所有 fprintf(stderr,...) 同时落到日志文件（TrollStore 装的无沙盒，可写）。
     * 用户/排查可直接看 /var/mobile/Documents/kfd_helper.log 的每步卡点。 */
    freopen("/var/mobile/Documents/kfd_helper.log", "w", stderr);

    if (argc < 2) {
        fprintf(stderr, "usage: %s --cdhash <hex40> | <appex_macho_path>\n", argv[0]);
        return 1;
    }

    uint8_t cdhash[20];
    char cdhash_hex[41];
    const char *arg = argv[1];

    /* --diag <path>：只 dump 签名结构（superblob/CD），不注入、不 spawn fuck_helper。
     * 用于真机诊断 TrollStore 重签后 VpnTunnel 的签名格式（安全，不会触发 kfd/panic）。 */
    if (strcmp(arg, "--diag") == 0) {
        if (argc < 3) {
            fprintf(stderr, "--diag requires <appex_macho_path>\n");
            return 1;
        }
        uint8_t *macho; size_t len;
        if (load_file(argv[2], &macho, &len) != 0) {
            fprintf(stderr, "cannot read %s\n", argv[2]); return 1;
        }
        fprintf(stderr, "[kfd-helper] diag mode: %s (%zu bytes)\n", argv[2], len);
        dump_codesign(macho, len);
        free(macho);
        return 0;
    }

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
        memcpy(cdhash_hex, argv[2], 40); cdhash_hex[40] = 0;
    } else {
        uint8_t *macho; size_t len;
        if (load_file(arg, &macho, &len) != 0) {
            fprintf(stderr, "cannot read %s\n", arg); return 1;
        }
        if (extract_cdhash(macho, len, cdhash) != 0) {
            fprintf(stderr, "cannot extract cdhash from %s\n", arg);
            dump_codesign(macho, len);
            free(macho); return 1;
        }
        free(macho);
        for (int i = 0; i < 20; i++) snprintf(cdhash_hex + i * 2, 3, "%02x", cdhash[i]);
        fprintf(stderr, "[kfd-helper] extracted cdhash=%s\n", cdhash_hex);
    }

    /* 定位同目录下的 fuck_helper：argv[0] 所在目录 + "/fuck_helper"。
     * 包内布局：<app>/bin/kfd_helper 与 <app>/bin/fuck_helper 同目录。 */
    char helper_path[4096];
    const char *self = argv[0];
    if (strchr(self, '/')) {
        char buf[4096];
        snprintf(buf, sizeof(buf), "%s", self);
        snprintf(helper_path, sizeof(helper_path), "%s/fuck_helper", dirname(buf));
    } else {
        snprintf(helper_path, sizeof(helper_path), "./fuck_helper");
    }
    if (access(helper_path, X_OK) != 0) {
        fprintf(stderr, "[kfd-helper] fuck_helper not found/executable: %s\n", helper_path);
        return 1;
    }
    fprintf(stderr, "[kfd-helper] invoking %s %s\n", helper_path, cdhash_hex);

    int rc = run_fuck_helper(helper_path, cdhash_hex);

    fprintf(stderr, "[kfd-helper] %s\n", rc == 0 ? "ok (trust injected)" : "failed");
    return rc == 0 ? 0 : 1;
}
