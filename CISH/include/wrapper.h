#ifndef CISH_WRAPPER_H
#define CISH_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 初始化 iSH 内核：挂载 fakefs rootfs、成为 init 进程、创建设备节点、挂载 /proc。
/// @param data_path fakefs 的 data 目录绝对路径（Documents/alpine-rootfs/data）
/// @return 0 成功，负数为 iSH 错误码
int cish_boot(const char *data_path);

/// 内核是否已 boot
int cish_is_booted(void);

/// 启动一个 guest 进程（串行语义：同一时刻全局只有一个 notify 接收者）。
/// @param path     guest 可执行文件（如 /bin/sh）
/// @param argv_buf NUL 分隔的参数字符串、末尾双 NUL（含 argv[0]）
/// @param envp_buf NUL 分隔的环境变量、末尾双 NUL；传 NULL 用内置默认环境
/// @param argc     argv_buf 中参数个数
/// @param stdin_fd guest stdin 对应的 host fd（-1 = /dev/null）
/// @param out_fd   guest stdout 对应的 host fd（-1 = 忽略）
/// @param err_fd   guest stderr 对应的 host fd（-1 = 忽略）
/// @param notify_fd 退出通知管道写端（guest 退出时写 8 字节：int32 pid + int32 code）
/// @return guest pid（>0 成功），负数为错误码
long cish_spawn(const char *path, const char *argv_buf, const char *envp_buf,
                int argc, int stdin_fd, int out_fd, int err_fd, int notify_fd);

/// 向 guest 进程发信号
int cish_kill(long pid, int sig);

/// 清掉 guest 进程组：SIGKILL 该 pgid 全部任务（pid<=1 拒绝，防误杀 init）
int cish_killpg(long pid);

#ifdef __cplusplus
}
#endif
#endif
