// CISH — iSH-ARM64 C 包装层（TrollAgent 专用，串行执行语义）
// 参考 OpenMinis（AGPLv3，本文件独立重写，仅复用公开 API 调用方式）：
//   deps/ISH_INTEGRATION.md、src/ios/iSH/ISHKernel.m、ISHShellExecutor.m
// 编译宏（由 meson/SPM 提供）：-DGUEST_ARM64=1 -DISH_INTERNAL

#include "wrapper.h"

#include "ish/kernel/init.h"
#include "ish/kernel/task.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/fs.h"
#include "ish/kernel/signal.h"
#include "ish/kernel/memory.h"
#include "ish/kernel/errno.h"
#include "ish/fs/fd.h"
#include "ish/fs/stat.h"
#include "ish/fs/tty.h"
#include "ish/fs/fake.h"
#include "ish/fs/real.h"
#include "ish/fs/poll.h"
#include "ish/fs/dev.h"
#include "ish/fs/devices.h"
#include "ish/emu/cpu.h"
#include "ish/platform/platform.h"
#include "ish/misc.h"
#include "ish/debug.h"

#include <pthread.h>
#include <stdatomic.h>

// 退出通知钩子（iSH 全局）：guest 进程退出时被调
extern void (*exit_hook)(struct task *task, int code);

static atomic_int g_booted = 0;

// 通知管道写端（串行：一次只有一个在跑的命令会收到退出通知）
static pthread_mutex_t g_notify_mtx = PTHREAD_MUTEX_INITIALIZER;
static int g_notify_fd = -1;

static void cish_exit_hook(struct task *task, int code) {
    if (task == NULL) return;
    int32_t pid = (int32_t)task->pid;
    int32_t rc = (int32_t)code;
    pthread_mutex_lock(&g_notify_mtx);
    int fd = g_notify_fd;
    if (fd >= 0) {
        // 写 8 字节 (pid, code)。管道满等罕见；一次只写 8 字节不会阻塞
        ssize_t wr = write(fd, &pid, 4);
        if (wr == 4) {
            wr = write(fd, &rc, 4);
        }
    }
    pthread_mutex_unlock(&g_notify_mtx);
}

int cish_is_booted(void) {
    return atomic_load(&g_booted);
}

int cish_boot(const char *data_path) {
    if (atomic_load(&g_booted)) return 0;
    if (data_path == NULL) return -1001;

    int err = mount_root(&fakefs, (char *)data_path);
    if (err < 0) return err;

    err = become_first_process();
    if (err < 0) return err;
    current->thread = pthread_self();

    // 设备节点（OpenMinis ISHKernel 同款）
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty2", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 2));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_MAJOR, 0));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, 2));
    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));

    int e2 = do_mount(&procfs, "proc", "/proc", "", 0);
    (void)e2;

    exit_hook = cish_exit_hook;
    atomic_store(&g_booted, 1);
    return 0;
}

long cish_spawn(const char *path, const char *argv_buf, const char *envp_buf,
                int argc, int stdin_fd, int out_fd, int err_fd, int notify_fd) {
    if (!atomic_load(&g_booted)) return -1000;
    if (path == NULL || argv_buf == NULL || argc <= 0) return -1002;

    struct task *saved_current = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        return err;
    }
    struct task *task = current;

    // stdio 管道接线（OpenMinis 同款：adhoc fd 包 host fd）
    if (stdin_fd >= 0) {
        struct fd *f = adhoc_fd_create(&realfs_fdops);
        if (f != NULL) {
            int real = dup(stdin_fd);
            if (real >= 0) { f->real_fd = real; task->files->files[0] = f; }
        }
    } else {
        struct fd *f = adhoc_fd_create(&realfs_fdops);
        if (f != NULL) {
            int real = open("/dev/null", O_RDONLY);
            if (real >= 0) { f->real_fd = real; task->files->files[0] = f; }
        }
    }
    if (out_fd >= 0) {
        struct fd *f = adhoc_fd_create(&realfs_fdops);
        if (f != NULL) {
            int real = dup(out_fd);
            if (real >= 0) { f->real_fd = real; task->files->files[1] = f; }
        }
    }
    if (err_fd >= 0) {
        struct fd *f = adhoc_fd_create(&realfs_fdops);
        if (f != NULL) {
            int real = dup(err_fd);
            if (real >= 0) { f->real_fd = real; task->files->files[2] = f; }
        }
    }

    // 注册通知管道（串行）
    pthread_mutex_lock(&g_notify_mtx);
    g_notify_fd = notify_fd;
    pthread_mutex_unlock(&g_notify_mtx);

    const char *env = envp_buf != NULL ? envp_buf : "";
    err = do_execve(path, argc, (char *)argv_buf, (char *)env);
    if (err < 0) {
        pthread_mutex_lock(&g_notify_mtx);
        g_notify_fd = -1;
        pthread_mutex_unlock(&g_notify_mtx);
        current = saved_current;
        return err;
    }

    long pid = (long)task->pid;
    task_start(task);
    current = saved_current;
    return pid;
}

int cish_kill(long pid, int sig) {
    if (pid <= 1) return -1;
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *t = pid_get_task((dword_t)pid);
    if (t != NULL) {
        send_signal(t, (dword_t)sig, info);
    }
    unlock(&pids_lock);
    return t != NULL ? 0 : -1;
}

int cish_killpg(long pid) {
    if (pid <= 1) return -1;
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *rootTask = pid_get_task((dword_t)pid);
    pid_t_ pgid = 0;
    if (rootTask != NULL) {
        pgid = rootTask->group->pgid;
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task(i);
            if (t == NULL) continue;
            int byPgid = (pgid != 0 && t->group->pgid == pgid);
            if (byPgid) {
                send_signal(t, SIGKILL_, info);
            }
        }
    }
    unlock(&pids_lock);
    return rootTask != NULL ? 0 : -1;
}
