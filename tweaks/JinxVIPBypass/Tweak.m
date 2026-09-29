// Jinx VIP Bypass — 纯 ObjC runtime swizzle 版（无 substrate 依赖）+ 诊断日志
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static void _logMsg(NSString *msg) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.count ? paths[0] : @"/tmp";
    NSString *lp = [docs stringByAppendingPathComponent:@"vip_hook.log"];
    NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:lp];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:lp contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:lp];
    }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
}

static BOOL _swizzleYES(Class cls, SEL sel, NSString *tag) {
    if (!cls) { _logMsg([tag stringByAppendingString:@": CLASS nil"]); return NO; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { _logMsg([tag stringByAppendingString:@": METHOD nil"]); return NO; }
    method_setImplementation(m, imp_implementationWithBlock(^(id _self){ return YES; }));
    _logMsg([tag stringByAppendingString:@": SWIZZLED OK"]);
    return YES;
}

static void _tryHook(void) {
    Class vip = NSClassFromString(@"VIPManager");
    Class real = NSClassFromString(@"RealPaidVIPManager");
    _logMsg([NSString stringWithFormat:@"tryHook: VIPManager=%@ RealPaidVIPManager=%@",
             vip ? @"YES" : @"NO", real ? @"YES" : @"NO"]);
    if (vip) {
        _swizzleYES(vip, @selector(isVIP), @"VIPManager.isVIP");
        _swizzleYES(vip, @selector(isRealPaidVIP), @"VIPManager.isRealPaidVIP");
        _swizzleYES(vip, @selector(isPaidUser), @"VIPManager.isPaidUser");
        _swizzleYES(vip, @selector(isFreeTrialVIP), @"VIPManager.isFreeTrialVIP");
    }
    if (real) {
        _swizzleYES(real, @selector(isVIP), @"RealPaidVIP.isVIP");
        _swizzleYES(real, @selector(isRealPaidVIP), @"RealPaidVIP.isRealPaidVIP");
    }
}

__attribute__((constructor))
static void _jinxVIPInit(void) {
    _logMsg(@"=== ctor fired ===");
    // 延迟重试：等类注册（Swift @objc 类延迟注册时也能捕获）
    for (int i = 0; i < 12; i++) {
        _tryHook();
        Class vip = NSClassFromString(@"VIPManager");
        Class real = NSClassFromString(@"RealPaidVIPManager");
        // 只要找到且任意 swizzle 成功就停（避免长时间阻塞启动）
        if ((vip && class_getInstanceMethod(vip, @selector(isVIP)))
            || (real && class_getInstanceMethod(real, @selector(isVIP)))) break;
        usleep(300000); // 0.3s
    }
    _logMsg(@"=== ctor done ===");
}
