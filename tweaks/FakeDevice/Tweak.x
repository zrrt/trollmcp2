// FakeDevice v1.1 - 设备伪装 dylib（借鉴绿盾守护思路，独立实现）
// 注入目标 App 后，读取 /var/mobile/Documents/Workspace/fake_device.json（TrollAgent 工作区），
// 将 UIDevice / NSProcessInfo 返回的设备信息替换为配置值（机型名称、型号标识、系统版本等）。
//
// 配置格式：
// {
//   "name": "iPhone 16 Pro Max",
//   "model": "iPhone",                // UIDevice -model 返回值
//   "modelIdentifier": "iPhone17,2",  // 无法直接 hook sysctl，仅作信息字段
//   "systemVersion": "18.0"
// }
//
// v1.1 加固（v2.9.93）：
// - swizzle 全部移到主线程执行（后台线程交换实现可能触发 App 崩溃）
// - 所有 swizzle 包 @try/@catch，异常只影响伪装，绝不 crash 宿主
// - 移除未使用的类方法 swizzle 工具

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define kFakeDevicePath @"/var/mobile/Documents/Workspace/fake_device.json"

static NSDictionary *g_fakeDevice = nil;

#pragma mark - Swizzle 工具

static void fd_swizzleInstanceMethod(Class cls, SEL original, SEL replacement) {
    @try {
        Method origM = class_getInstanceMethod(cls, original);
        Method replM = class_getInstanceMethod(cls, replacement);
        if (!origM || !replM) return;
        method_exchangeImplementations(origM, replM);
    } @catch (NSException *e) {
        NSLog(@"[FakeDevice] swizzle %@ failed: %@", NSStringFromSelector(original), e);
    }
}

#pragma mark - UIDevice 伪装

@interface UIDevice (FakeDevice)
- (NSString *)fd_name;
- (NSString *)fd_model;
- (NSString *)fd_localizedModel;
- (NSString *)fd_systemVersion;
@end

@implementation UIDevice (FakeDevice)
- (NSString *)fd_name {
    if (g_fakeDevice[@"name"]) return g_fakeDevice[@"name"];
    return [self fd_name];
}
- (NSString *)fd_model {
    if (g_fakeDevice[@"model"]) return g_fakeDevice[@"model"];
    return [self fd_model];
}
- (NSString *)fd_localizedModel {
    if (g_fakeDevice[@"model"]) return g_fakeDevice[@"model"];
    return [self fd_localizedModel];
}
- (NSString *)fd_systemVersion {
    if (g_fakeDevice[@"systemVersion"]) return g_fakeDevice[@"systemVersion"];
    return [self fd_systemVersion];
}
@end

#pragma mark - NSProcessInfo 伪装

@interface NSProcessInfo (FakeDevice)
- (NSOperatingSystemVersion)fd_operatingSystemVersion;
@end

@implementation NSProcessInfo (FakeDevice)
- (NSOperatingSystemVersion)fd_operatingSystemVersion {
    NSOperatingSystemVersion v = [self fd_operatingSystemVersion];
    if (g_fakeDevice[@"systemVersion"]) {
        NSArray *parts = [g_fakeDevice[@"systemVersion"] componentsSeparatedByString:@"."];
        if (parts.count > 0) v.majorVersion = [parts[0] integerValue];
        if (parts.count > 1) v.minorVersion = [parts[1] integerValue];
        if (parts.count > 2) v.patchVersion = [parts[2] integerValue];
    }
    return v;
}
@end

#pragma mark - 入口

__attribute__((constructor))
static void fdInit(void) {
    // 延迟到主线程执行：等 App 启动完成 + 主 runloop 就绪，避免早期 swizzle 与 UIKit 初始化竞争
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            NSData *data = [NSData dataWithContentsOfFile:kFakeDevicePath];
            if (!data) {
                NSLog(@"[FakeDevice] no config at %@, skip", kFakeDevicePath);
                return;
            }
            NSError *err = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (err || ![obj isKindOfClass:[NSDictionary class]]) {
                NSLog(@"[FakeDevice] config parse failed: %@", err);
                return;
            }
            g_fakeDevice = obj;
            NSLog(@"[FakeDevice] config loaded: %@", g_fakeDevice);

            // 主线程 + @try 保护下挂 swizzle，任何异常都不会让宿主 App 崩溃
            fd_swizzleInstanceMethod([UIDevice class], @selector(name), @selector(fd_name));
            fd_swizzleInstanceMethod([UIDevice class], @selector(model), @selector(fd_model));
            fd_swizzleInstanceMethod([UIDevice class], @selector(localizedModel), @selector(fd_localizedModel));
            fd_swizzleInstanceMethod([UIDevice class], @selector(systemVersion), @selector(fd_systemVersion));
            fd_swizzleInstanceMethod([NSProcessInfo class], @selector(operatingSystemVersion), @selector(fd_operatingSystemVersion));
            NSLog(@"[FakeDevice] swizzles applied");
        } @catch (NSException *e) {
            NSLog(@"[FakeDevice] init crashed: %@", e);
        }
    });
}
