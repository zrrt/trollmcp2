// ConfigHook v1.0 - 配置化 Hook 引擎（借鉴 FuckEngine hookType/hookValue 设计，独立实现）
// 注入任意 App 后，读取 /var/mobile/Documents/Workspace/hook_config.json（TrollAgent 工作区），
// 按配置对 UIKit 应用修改，无需重新编译 dylib。
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
        if (!data) {
            NSLog(@"[ConfigHook] no config at %@, skip", kConfigPath);
            return;
        }
        NSError *err = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (err || ![obj isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ConfigHook] config parse failed: %@", err);
            return;
        }
        ch_applyConfig(obj);
    });
}
