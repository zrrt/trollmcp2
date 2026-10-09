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
    FILE *f = fopen("/tmp/gputest.log", "w");
    if (!f) f = fopen("/var/mobile/Documents/gputest.log", "w");
    if (!f) return 2;
    logline(f, "gputest v1 uid=%d euid=%d gid=%d egid=%d argv0=%s",
            getuid(), geteuid(), getgid(), getegid(), argc ? argv[0] : "?");

    id<MTLDevice> def = MTLCreateSystemDefaultDevice();
    logline(f, "MTLCreateSystemDefaultDevice = %@", def ? @"OK" : @"nil");
    if (def) logline(f, "default name = %s", def.name.UTF8String);

    NSArray<id<MTLDevice>> *devs = MTLCopyAllDevices();
    logline(f, "MTLCopyAllDevices count = %lu", (unsigned long)devs.count);
    if (devs.count) logline(f, "copyall[0] name = %s", devs[0].name.UTF8String);

    // 尝试创建一个 command queue / 最小 Metal 对象，确认不是空壳
    id<MTLCommandQueue> cq = def ? [def newCommandQueue] : nil;
    logline(f, "newCommandQueue = %@", cq ? @"OK" : @"nil");

    fclose(f);
    return (def != nil) ? 0 : 1;
}
