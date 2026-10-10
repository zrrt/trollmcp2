// gputest.m — Live2D A 方案最小验证：测一个"沙盒 + mobile 身份"的进程能否拿到 Metal GPU
// 用法：由主 App/HUD 以 persona 0 (mobile) 拉起；结果写 /tmp/gputest.log
// 目的：确认"沙盒 helper 进程能否拿 GPU"——能则 A 方案（沙盒渲染进程 + 帧传 HUD）可行。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <stdarg.h>
#import <unistd.h>

static void logline(FILE *f, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fprintf(f, "\n"); fflush(f);
}

int main(int argc, char **argv) {
    // 启动标记立即写 stderr——由主 App posix_spawn file_actions 重定向捕获，确认 gputest 是否真的 exec 起来
    fprintf(stderr, "GPUTEST BOOT argv0=%s\n", argc ? argv[0] : "?"); fflush(stderr);

    // 日志写到多个候选路径（沙盒进程写 /tmp/全局 Documents 可能被拒，App 容器最可靠）
    FILE *f = NULL;
    const char *paths[] = { "/var/mobile/Documents/gputest.log", "/tmp/gputest.log", NULL };
    NSString *home = NSHomeDirectory();               // 沙盒进程 = App 容器，100% 可写
    NSString *homeDoc = [home stringByAppendingPathComponent:@"Documents/gputest.log"];
    f = fopen(homeDoc.UTF8String, "w");
    for (int i = 0; !f && paths[i]; i++) f = fopen(paths[i], "w");
    if (!f) f = fopen("/dev/null", "w");              // 全失败也不崩，结果走 stdout/stderr 重定向
    if (f) {
        logline(f, "gputest v3 home=%s uid=%d euid=%d gid=%d egid=%d argv0=%s",
                home.UTF8String, getuid(), geteuid(), getgid(), getegid(), argc ? argv[0] : "?");
    }

    id<MTLDevice> def = MTLCreateSystemDefaultDevice();
    NSString *defS = def ? [NSString stringWithFormat:@"OK name=%@", def.name] : @"nil";
    printf("MTLCreateSystemDefaultDevice = %s\n", defS.UTF8String); fflush(stdout);
    if (f) logline(f, "MTLCreateSystemDefaultDevice = %@", def ? def.name : @"nil");

    NSArray<id<MTLDevice>> *devs = MTLCopyAllDevices();
    printf("MTLCopyAllDevices count = %lu\n", (unsigned long)devs.count); fflush(stdout);
    if (devs.count) printf("copyall[0] name = %s\n", devs[0].name.UTF8String);
    if (f) logline(f, "MTLCopyAllDevices count = %lu", (unsigned long)devs.count);

    // 尝试创建一个 command queue / 最小 Metal 对象，确认不是空壳
    id<MTLCommandQueue> cq = def ? [def newCommandQueue] : nil;
    printf("newCommandQueue = %@\n", cq ? @"OK" : @"nil"); fflush(stdout);
    if (f) logline(f, "newCommandQueue = %@", cq ? @"OK" : @"nil");

    if (f) fclose(f);
    printf("GPUTEST EXIT code=%d\n", (def != nil) ? 0 : 1); fflush(stdout);
    return (def != nil) ? 0 : 1;
}
