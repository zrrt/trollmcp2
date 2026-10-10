#include "launch.h"

#include <spawn.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/wait.h>

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

/*
 * v6.0.x: 管道捕获式 spawn——gputest 沙盒 GPU 诊断（决定性方案）。
 * 不设 persona（继承调用方 mobile 身份）。子进程 stdout+stderr dup2 到管道写端，
 * 主 App 从管道读端读取（管道在主 App 侧，不受子进程沙盒写文件限制），再 waitpid 取退出码。
 * 无论子进程崩不崩、能否写文件，只要 exec 起来且 printf 过，输出都能被捕获。
 * outbuf: 主 App 提供的缓冲区；buflen: 缓冲大小；exit_code: 子进程退出码(或 spawn rc)。
 */
int troll_launch_capture(const char *path, const char *const *argv, char *outbuf, size_t buflen, int *exit_code) {
    if (!path || !argv || !outbuf || !buflen) return -1;
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;
    posix_spawnattr_t attr = NULL;
    posix_spawn_file_actions_t fa = NULL;
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDERR_FILENO);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, &fa, &attr, (char *const *)argv, NULL);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        close(pipefd[0]); close(pipefd[1]);
        outbuf[0] = '\0';
        if (exit_code) *exit_code = rc;
        return rc;
    }
    close(pipefd[1]);  // 父进程关闭写端
    size_t n = read(pipefd[0], outbuf, buflen - 1);
    if (n < 0) n = 0;
    outbuf[n] = '\0';
    close(pipefd[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    if (exit_code) {
        if (WIFEXITED(st))      *exit_code = WEXITSTATUS(st);
        else if (WIFSIGNALED(st)) *exit_code = 128 + WTERMSIG(st);
        else                    *exit_code = -1;
    }
    return rc;
}
