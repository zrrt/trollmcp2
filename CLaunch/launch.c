#include "launch.h"

#include <spawn.h>
#include <unistd.h>
#include <dlfcn.h>

/*
 * posix_spawnattr_setpersona_np 等是 iOS 私有 API：运行时在 libspawn 里存在，
 * 但 macOS 交叉编译 iOS 的 SDK .tbd 不含这些符号（静态链接会 undefined symbol）。
 * 这里用 dlsym 动态加载（运行时从主 App 进程的 libspawn 找），TrollSpeed/TheBall 同款语义。
 * posix_spawnattr_t 在 C 里是 void*。
 */
typedef int (*setpersona_fn)(posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*setuid_fn)(posix_spawnattr_t *, uid_t);
typedef int (*setgid_fn)(posix_spawnattr_t *, gid_t);
/* POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 是私有宏，iOS 公开 SDK spawn.h 不导出，这里自行定义（=1，TrollSpeed 同款）。 */
#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif

int troll_launch_hud(const char *path, const char *const *argv, int persona_override) {
    if (!path || !argv) return -1;

    posix_spawnattr_t attr = NULL;
    if (posix_spawnattr_init(&attr) != 0) {
        return -1;
    }

    if (persona_override) {
        /* persona 99 = root；需调用方（主 App）带 platform-application + persona-mgmt entitlements。
           dlsym 动态加载（SDK .tbd 无这些符号，静态链接会 undefined symbol）。 */
        setpersona_fn sp = (setpersona_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        setuid_fn su = (setuid_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        setgid_fn sg = (setgid_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
        int rp = sp ? sp(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE) : -999;
        int ru = su ? su(&attr, 0) : -999;
        int rg = sg ? sg(&attr, 0) : -999;
        /* 提权结果写 /tmp/hud.launch.log，真机确证 HUD 是否 root persona 拉起 */
        FILE *lf = fopen("/tmp/hud.launch.log", "w");
        if (lf) {
            fprintf(lf, "persona symbols: sp=%s su=%s sg=%s\nrc: persona=%d uid=%d gid=%d\n",
                    sp ? "OK" : "MISS", su ? "OK" : "MISS", sg ? "OK" : "MISS", rp, ru, rg);
            fclose(lf);
        }
    }

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, &attr, (char *const *)argv, NULL);
    posix_spawnattr_destroy(&attr);
    return rc;
}
