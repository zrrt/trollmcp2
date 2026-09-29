#import <UIKit/UIKit.h>

// Jinx VIP Bypass
// Hook VIPManager / RealPaidVIPManager 的 VIP 判定 getter 强制返回 YES。
// isVIP / isRealPaidVIP / isPaidUser / isFreeTrialVIP 为 ObjC 可见 selector。

%hook VIPManager
- (BOOL)isVIP {
    return YES;
}
- (BOOL)isRealPaidVIP {
    return YES;
}
- (BOOL)isPaidUser {
    return YES;
}
- (BOOL)isFreeTrialVIP {
    return YES;
}
%end

%hook RealPaidVIPManager
- (BOOL)isVIP {
    return YES;
}
- (BOOL)isRealPaidVIP {
    return YES;
}
%end
