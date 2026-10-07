#include "launch.h"

#include <spawn.h>
#include <unistd.h>

/*
 * posix_spawnattr_setpersona_np 等是 iOS 私有 API（libspawn 符号，未在公开 SDK 头声明），
 * 这里按 C 声明直接链接——符号在 iOS 系统库存在，TrollSpeed/TheBall 均如此调用。
 * posix_spawnattr_t 在 C 里是 void*。
 */
extern int posix_spawnattr_setpersona_np(posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_setuid_np(posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_setgid_np(posix_spawnattr_t *, gid_t);

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
        /* persona 99 = root；需调用方（主 App）带 platform-application + persona-mgmt entitlements */
        (void)posix_spawnattr_setpersona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        (void)posix_spawnattr_setuid_np(&attr, 0);
        (void)posix_spawnattr_setgid_np(&attr, 0);
    }

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, &attr, (char *const *)argv, NULL);
    posix_spawnattr_destroy(&attr);
    return rc;
}
