#ifndef CLaunch_launch_h
#define CLaunch_launch_h

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * 以 root persona (99) 提权 spawn 一个可执行文件（桌面悬浮 HUD 正解，TrollSpeed HUDHelper.mm）。
 * 放在 C 层：posix_spawnattr_t 在 C 里是 void*，无 Swift 的类型混乱问题。
 *
 * path:  目标可执行文件绝对路径
 * argv:  以 NULL 结尾的参数数组（argv[0] 应为可执行路径）
 * persona_override: 非 0 则 persona 99 提权 + uid/gid 0
 *
 * 返回 posix_spawn 的返回值（0 = 成功拉起，子进程已脱离父进程常驻）。
 */
int troll_launch_hud(const char *path, const char *const *argv, int persona_override);

/*
 * v6.0.x: 管道捕获式 spawn（不设 persona，继承调用方 mobile 身份）。
 * 用于 gputest 沙盒 GPU 诊断：子进程 stdout+stderr dup2 到管道，主 App 读管道 + waitpid。
 * 不受子进程沙盒写文件限制，崩溃也能捕获已 printf 的输出。
 */
int troll_launch_capture(const char *path, const char *const *argv, char *outbuf, size_t buflen, int *exit_code);

#ifdef __cplusplus
}
#endif

#endif /* CLaunch_launch_h */
