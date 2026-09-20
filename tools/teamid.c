// teamid —— 从 pid（或路径）提取目标 App 可执行文件 CodeSignature CodeDirectory 的 TeamID。
// v3.0.53: 注入链用——ct_bypass 签名需要目标 App 的真实 Team ID（TrollFools teamIdentifierOfMachO 同款逻辑，
// 只是直接解析 Mach-O，不依赖 MachOKit）。
// 用法: teamid <pid>  或  teamid <path-to-macho>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <libproc.h>

#define MH_MAGIC_64   0xfeedfacf
#define MH_CIGAM_64   0xcffaedfe
#define FAT_MAGIC     0xcafebabe
#define FAT_CIGAM     0xbebafeca
#define LC_CODE_SIGNATURE 0x1d
#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_CODEDIRECTORY 0xfade0c02
#define CPU_TYPE_ARM64 0x0100000c
#define CPU_SUBTYPE_ARM64_ALL 0

struct fat_header { uint32_t magic; uint32_t nfat_arch; };
struct fat_arch { uint32_t cputype; uint32_t cpusubtype; uint32_t offset; uint32_t size; uint32_t align; };
struct mach_header_64 { uint32_t magic; uint32_t cputype; uint32_t cpusubtype; uint32_t filetype; uint32_t ncmds; uint32_t sizeofcmds; uint32_t flags; uint32_t reserved; };
struct load_command { uint32_t cmd; uint32_t cmdsize; };
struct linkedit_data_command { uint32_t cmd; uint32_t cmdsize; uint32_t dataoff; uint32_t datasize; };
struct CS_BlobIndex { uint32_t type; uint32_t offset; };
struct CS_SuperBlob { uint32_t magic; uint32_t length; uint32_t count; struct CS_BlobIndex index[]; };
struct CS_CodeDirectory {
    uint32_t magic; uint32_t length; uint32_t version; uint32_t flags;
    uint32_t hashOffset; uint32_t identOffset; uint32_t nSpecialSlots; uint32_t nCodeSlots;
    uint32_t codeLimit; uint8_t hashSize; uint8_t hashType; uint8_t platform; uint8_t pageSize;
    uint32_t spare2; uint32_t scatterOffset; uint32_t teamOffset; uint32_t spare3;
    uint64_t codeLimit64; uint64_t execSegBase; uint64_t execSegLimit; uint64_t execSegFlags;
    uint32_t runtime; uint32_t preEncryptOffset; uint32_t spare4;
};

static uint32_t be32(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}
static uint32_t le32(const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return ((uint32_t)b[3] << 24) | ((uint32_t)b[2] << 16) | ((uint32_t)b[1] << 8) | b[0];
}

// 从一个 Mach-O 文件里解析 teamID，写进 out（最大 32B）。返回 0 找到，-1 未找到。
static int parseTeamID(FILE *f, long base, long size, char *out) {
    (void)size;
    uint8_t *buf = malloc(size);
    if (!buf) return -1;
    fseek(f, base, SEEK_SET);
    if (fread(buf, 1, size, f) != (size_t)size) { free(buf); return -1; }
    // Mach-O header
    uint32_t magic = le32(buf);
    int swap = 0;
    if (magic == MH_CIGAM_64) { swap = 1; magic = MH_MAGIC_64; }
    if (magic != MH_MAGIC_64) { free(buf); return -1; }
    const struct mach_header_64 *mh = (const struct mach_header_64 *)buf;
    uint32_t ncmds = swap ? be32(&mh->ncmds) : le32(&mh->ncmds);
    uint32_t sizeofcmds = swap ? be32(&mh->sizeofcmds) : le32(&mh->sizeofcmds);
    if (sizeofcmds > size) { free(buf); return -1; }
    const uint8_t *cmds = buf + sizeof(struct mach_header_64);
    const uint8_t *cmdsEnd = cmds + sizeofcmds;
    uint32_t sigOff = 0, sigSize = 0;
    while (cmds + sizeof(struct load_command) <= cmdsEnd) {
        const struct load_command *lc = (const struct load_command *)cmds;
        uint32_t cmd = swap ? be32(&lc->cmd) : le32(&lc->cmd);
        uint32_t cmdsize = swap ? be32(&lc->cmdsize) : le32(&lc->cmdsize);
        if (cmdsize < sizeof(struct load_command) || cmds + cmdsize > cmdsEnd) break;
        if (cmd == LC_CODE_SIGNATURE && cmdsize >= sizeof(struct linkedit_data_command)) {
            const struct linkedit_data_command *ld = (const struct linkedit_data_command *)cmds;
            sigOff = swap ? be32(&ld->dataoff) : le32(&ld->dataoff);
            sigSize = swap ? be32(&ld->datasize) : le32(&ld->datasize);
        }
        cmds += cmdsize;
    }
    free(buf);
    if (!sigOff || !sigSize) return -1;

    uint8_t *sbuf = malloc(sigSize);
    if (!sbuf) return -1;
    fseek(f, base + sigOff, SEEK_SET);
    if (fread(sbuf, 1, sigSize, f) != sigSize) { free(sbuf); return -1; }
    if (sigSize < 12) { free(sbuf); return -1; }
    uint32_t smagic = be32(sbuf);
    uint32_t scount = be32(sbuf + 8);
    if (smagic != CSMAGIC_EMBEDDED_SIGNATURE) { free(sbuf); return -1; }
    for (uint32_t i = 0; i < scount && (12 + 8 * (i + 1)) <= sigSize; i++) {
        uint32_t type = be32(sbuf + 12 + 8 * i);
        uint32_t off = be32(sbuf + 12 + 8 * i + 4);
        if (type == CSMAGIC_CODEDIRECTORY && off + 52 <= sigSize) {
            const struct CS_CodeDirectory *cd = (const struct CS_CodeDirectory *)(sbuf + off);
            uint32_t version = be32(&cd->version);
            uint32_t teamOffset = 0;
            // v2.0+ (0x20400) 才有 teamOffset；v1 (0x20000) 没有 TeamID 字段
            if (version >= 0x20400) {
                teamOffset = be32(&cd->teamOffset);
            }
            if (teamOffset && off + teamOffset < sigSize) {
                const char *team = (const char *)(sbuf + off + teamOffset);
                size_t tlen = strnlen(team, sigSize - off - teamOffset);
                if (tlen > 0 && tlen < 32) {
                    memcpy(out, team, tlen);
                    out[tlen] = '\0';
                    free(sbuf);
                    return 0;
                }
            }
            free(sbuf);
            return -1;
        }
    }
    free(sbuf);
    return -1;
}

int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: %s <pid | path>\n", argv[0]); return 1; }
    char path[PATH_MAX] = {0};
    const char *arg = argv[1];
    if (arg[0] >= '0' && arg[0] <= '9') {
        int pid = atoi(arg);
        int r = proc_pidpath(pid, path, sizeof(path));
        if (r <= 0) { fprintf(stderr, "proc_pidpath(%d) failed\n", pid); return 1; }
    } else {
        snprintf(path, sizeof(path), "%s", arg);
    }
    printf("path: %s\n", path);
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "open failed: %s\n", path); return 1; }
    uint8_t hdr[32];
    if (fread(hdr, 1, 32, f) != 32) { fclose(f); return 1; }
    uint32_t magic = le32(hdr);
    char team[32] = {0};
    int found = -1;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        uint32_t nfat = be32(hdr + 4);
        for (uint32_t i = 0; i < nfat && i < 16; i++) {
            uint8_t fa[20];
            fseek(f, 8 + 20 * i, SEEK_SET);
            if (fread(fa, 1, 20, f) != 20) break;
            uint32_t cputype = be32(fa);
            uint32_t offset = be32(fa + 8);
            uint32_t size = be32(fa + 12);
            if (cputype == CPU_TYPE_ARM64) {
                found = parseTeamID(f, offset, size, team);
                if (found == 0) break;
            }
        }
        if (found != 0) {
            // 兜底：任意 slice
            for (uint32_t i = 0; i < nfat && i < 16; i++) {
                uint8_t fa[20];
                fseek(f, 8 + 20 * i, SEEK_SET);
                if (fread(fa, 1, 20, f) != 20) break;
                uint32_t offset = be32(fa + 8);
                uint32_t size = be32(fa + 12);
                if (parseTeamID(f, offset, size, team) == 0) { found = 0; break; }
            }
        }
    } else {
        fseek(f, 0, SEEK_END);
        long size = ftell(f);
        found = parseTeamID(f, 0, size, team);
    }
    fclose(f);
    if (found == 0) {
        printf("team_id: %s\n", team);
        return 0;
    }
    printf("team_id: \n");
    return 0;
}
