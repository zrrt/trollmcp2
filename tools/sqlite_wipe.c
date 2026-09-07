/*
 * sqlite_wipe — TrollAgent 内置工具（v2.9.96）
 * 以 root 直改 /var/Keychains/keychain-2.db，删除指定 access group 的钥匙串条目。
 * 用法: sqlite_wipe <group> [group2 ...]
 * 编译(iOS arm64): xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=14.0 sqlite_wipe.c -lsqlite3 -o sqlite_wipe
 */
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void esc(char *buf, size_t n, const char *s) {
    size_t i = 0, o = 0;
    while (s[i] && o + 2 < n) {
        if (s[i] == '\'') { buf[o++] = '\''; buf[o++] = '\''; }
        else { buf[o++] = s[i]; }
        i++;
    }
    buf[o] = '\0';
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: sqlite_wipe <group>...\n"); return 2; }
    sqlite3 *h = NULL;
    if (sqlite3_open("/var/Keychains/keychain-2.db", &h) != SQLITE_OK) {
        fprintf(stderr, "open keychain db failed\n"); return 1;
    }
    /* 收集转义后的 group 列表 */
    char escgroups[16][256];
    int ng = argc - 1;
    if (ng > 16) ng = 16;
    for (int i = 0; i < ng; i++) esc(escgroups[i], sizeof(escgroups[i]), argv[i + 1]);

    char sql[8192];
    size_t off = 0;
    const char *tables[3] = { "genp", "inet", "keys" };
    for (int t = 0; t < 3; t++) {
        off += snprintf(sql + off, sizeof(sql) - off, "DELETE FROM %s WHERE agrp IN (", tables[t]);
        for (int i = 0; i < ng; i++)
            off += snprintf(sql + off, sizeof(sql) - off, "%s'%s'", i > 0 ? "," : "", escgroups[i]);
        off += snprintf(sql + off, sizeof(sql) - off, ");");
    }
    char *err = NULL;
    if (sqlite3_exec(h, sql, NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "exec failed: %s\n", err ? err : "?");
        sqlite3_free(err);
        sqlite3_close(h);
        return 1;
    }
    int total = sqlite3_total_changes(h);
    sqlite3_close(h);
    printf("wiped %d item(s) for %d group(s)\n", total, ng);
    return 0;
}
