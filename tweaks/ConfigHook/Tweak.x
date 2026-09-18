// ConfigHook v2.0 - 配置化 Hook 引擎（合并版）
// 合并自：ConfigHook v1.0（UI颜色/弹窗/方法日志）+ FakeDevice v1.1（设备伪装）
// 功能：导航栏颜色 / 弹窗 / 方法日志 / 设备伪装（UIDevice名称/型号/系统版本）
// 配置文件：/var/mobile/Documents/Workspace/hook_config.json
// 设备伪装配置：/var/mobile/Documents/Workspace/fake_device.json
// 设计原则：纯 runtime + Foundation/UIKit，零 substrate 依赖；配置缺失时静默跳过
//
// 配置格式：
// {
//   "navBarColor": "#1A73E8",                          // 导航栏背景色
//   "navBarTitleColor": "#FFFFFF",                     // 导航栏标题色
//   "windowTint": "#FF0000",                           // 全局 tintColor
//   "alert": {"title": "...", "message": "..."},       // 启动后弹窗
//   "methodLog": [                                     // 方法调用日志（runtime swizzle）
//     {"class": "ViewController", "selector": "viewDidLoad"}
//   ]
// }
//
// 设计原则：纯 runtime + Foundation/UIKit，零 substrate 依赖；配置缺失时静默跳过。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define kConfigPath @"/var/mobile/Documents/Workspace/hook_config.json"

#pragma mark - v2.0：FakeDevice 设备伪装（合并自 FakeDevice v1.1）

static NSDictionary *g_fakeDevice = nil;

static void fd_swizzleInstanceMethod(Class cls, SEL original, SEL replacement) {
    @try {
        Method origM = class_getInstanceMethod(cls, original);
        Method replM = class_getInstanceMethod(cls, replacement);
        if (!origM || !replM) return;
        method_exchangeImplementations(origM, replM);
    } @catch (NSException *e) {}
}

@interface UIDevice (ConfigHook_Fake)
- (NSString *)fd_name;
- (NSString *)fd_model;
- (NSString *)fd_localizedModel;
- (NSString *)fd_systemVersion;
@end
@implementation UIDevice (ConfigHook_Fake)
- (NSString *)fd_name { if (g_fakeDevice[@"name"]) return g_fakeDevice[@"name"]; return [self fd_name]; }
- (NSString *)fd_model { if (g_fakeDevice[@"model"]) return g_fakeDevice[@"model"]; return [self fd_model]; }
- (NSString *)fd_localizedModel { if (g_fakeDevice[@"model"]) return g_fakeDevice[@"model"]; return [self fd_localizedModel]; }
- (NSString *)fd_systemVersion { if (g_fakeDevice[@"systemVersion"]) return g_fakeDevice[@"systemVersion"]; return [self fd_systemVersion]; }
@end

@interface NSProcessInfo (ConfigHook_Fake)
- (NSOperatingSystemVersion)fd_operatingSystemVersion;
@end
@implementation NSProcessInfo (ConfigHook_Fake)
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

#pragma mark - 工具函数

static UIColor *ch_colorFromHex(NSString *hex) {
    if (!hex || hex.length < 6) return nil;
    NSString *s = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length < 6) return nil;
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:s] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:((rgb) & 0xFF) / 255.0
                           alpha:1.0];
}

#pragma mark - 方法日志 swizzle（methodLog）

@interface NSObject (ConfigHook)
@end
@implementation NSObject (ConfigHook)
+ (void)ch_hookMethodLogForClass:(NSString *)className selector:(NSString *)selectorName {
    Class cls = NSClassFromString(className);
    if (!cls) { NSLog(@"[ConfigHook] methodLog: class not found: %@", className); return; }
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    BOOL isClassMethod = NO;
    if (!m) {
        m = class_getClassMethod(cls, sel);
        isClassMethod = YES;
    }
    if (!m) { NSLog(@"[ConfigHook] methodLog: selector not found: %@.%@", className, selectorName); return; }

    Class targetCls = isClassMethod ? object_getClass(cls) : cls;
    IMP origImp = method_getImplementation(m);

    IMP newImp = imp_implementationWithBlock(^(id self_) {
        NSLog(@"[ConfigHook] method called: %@ - %@", NSStringFromClass([self_ class]), NSStringFromSelector(sel));
        void (*origFn)(id, SEL) = (void (*)(id, SEL))origImp;
        origFn(self_, sel);
    });
    method_setImplementation(m, newImp);
    NSLog(@"[ConfigHook] methodLog hooked: %@.%@", className, selectorName);
}
@end

#pragma mark - 配置应用

static void ch_applyConfig(NSDictionary *config) {
    if (!config || config.count == 0) {
        NSLog(@"[ConfigHook] empty config, skip");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 导航栏颜色
        NSString *navBarHex = config[@"navBarColor"];
        if (navBarHex) {
            UIColor *c = ch_colorFromHex(navBarHex);
            if (c) {
                if (@available(iOS 13.0, *)) {
                    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
                    [appearance configureWithOpaqueBackground];
                    appearance.backgroundColor = c;
                    NSString *titleHex = config[@"navBarTitleColor"];
                    if (titleHex) appearance.titleTextAttributes = @{NSForegroundColorAttributeName: ch_colorFromHex(titleHex) ?: UIColor.whiteColor};
                    [UINavigationBar appearance].standardAppearance = appearance;
                    [UINavigationBar appearance].scrollEdgeAppearance = appearance;
                } else {
                    [UINavigationBar appearance].barTintColor = c;
                }
                NSLog(@"[ConfigHook] navBarColor -> %@", navBarHex);
            }
        }

        // 2. 全局 tint
        NSString *tintHex = config[@"windowTint"];
        if (tintHex) {
            UIColor *c = ch_colorFromHex(tintHex);
            if (c) {
                UIWindow *key = [UIApplication sharedApplication].keyWindow;
                if (key) key.tintColor = c;
                [UIView appearance].tintColor = c;
                NSLog(@"[ConfigHook] windowTint -> %@", tintHex);
            }
        }

        // 3. 启动弹窗
        NSDictionary *alert = config[@"alert"];
        if (alert && [alert isKindOfClass:[NSDictionary class]]) {
            NSString *title = alert[@"title"] ?: @"TrollAgent";
            NSString *message = alert[@"message"] ?: @"";
            UIWindow *key = [UIApplication sharedApplication].keyWindow;
            if (key) {
                UIViewController *root = key.rootViewController;
                if (root) {
                    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
                    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [root presentViewController:ac animated:YES completion:nil];
                    NSLog(@"[ConfigHook] alert shown: %@", title);
                }
            }
        }

        // 4. 方法日志
        NSArray *methodLog = config[@"methodLog"];
        if (methodLog && [methodLog isKindOfClass:[NSArray class]]) {
            for (NSDictionary *item in methodLog) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *clsName = item[@"class"];
                NSString *selName = item[@"selector"];
                if (clsName && selName) {
                    [NSObject ch_hookMethodLogForClass:clsName selector:selName];
                }
            }
        }
    });
}

__attribute__((constructor))
static void chInit(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [NSThread sleepForTimeInterval:1.0];
        NSData *data = [NSData dataWithContentsOfFile:kConfigPath];
        if (data) {
            NSError *err = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (!err && [obj isKindOfClass:[NSDictionary class]]) {
                ch_applyConfig(obj);
            }
        }
        // v2.0：加载 FakeDevice 配置（合并自 FakeDevice v1.1）
        NSData *fdData = [NSData dataWithContentsOfFile:@"/var/mobile/Documents/Workspace/fake_device.json"];
        if (fdData) {
            NSError *err = nil;
            id fdObj = [NSJSONSerialization JSONObjectWithData:fdData options:0 error:&err];
            if (!err && [fdObj isKindOfClass:[NSDictionary class]]) {
                g_fakeDevice = fdObj;
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        fd_swizzleInstanceMethod([UIDevice class], @selector(name), @selector(fd_name));
                        fd_swizzleInstanceMethod([UIDevice class], @selector(model), @selector(fd_model));
                        fd_swizzleInstanceMethod([UIDevice class], @selector(localizedModel), @selector(fd_localizedModel));
                        fd_swizzleInstanceMethod([UIDevice class], @selector(systemVersion), @selector(fd_systemVersion));
                        fd_swizzleInstanceMethod([NSProcessInfo class], @selector(operatingSystemVersion), @selector(fd_operatingSystemVersion));
                    } @catch (NSException *e) {}
                });
            }
        }
    });
}

