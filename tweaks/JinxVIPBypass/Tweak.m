// Jinx VIP Bypass — 纯 ObjC runtime swizzle 版（无 substrate 依赖）
// 不链接 CydiaSubstrate，因此注入后不依赖 App 内置的加密 substrate，
// 避免 TrollStore 184(附加加密二进制)导致 dylib 加载失败闪退。
// 通过 method_setImplementation 把 VIPManager / RealPaidVIPManager 的
// VIP 判定 getter 强制改为返回 YES。
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static void _forceReturnYES(Class cls, SEL sel) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    // 用 block imp 替换原实现：任何调用都返回 YES
    method_setImplementation(m, imp_implementationWithBlock(^(id _self) {
        return YES;
    }));
}

__attribute__((constructor))
static void _jinxVIPInit(void) {
    Class vip = NSClassFromString(@"VIPManager");
    if (vip) {
        _forceReturnYES(vip, @selector(isVIP));
        _forceReturnYES(vip, @selector(isRealPaidVIP));
        _forceReturnYES(vip, @selector(isPaidUser));
        _forceReturnYES(vip, @selector(isFreeTrialVIP));
    }
    Class real = NSClassFromString(@"RealPaidVIPManager");
    if (real) {
        _forceReturnYES(real, @selector(isVIP));
        _forceReturnYES(real, @selector(isRealPaidVIP));
    }
}
