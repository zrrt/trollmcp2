//
//  HUDApp.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//
//  TrollAgent 改造：作为独立 HUD 二进制 main——直接进入 HUD 悬浮模式，
//  去掉原版"同一二进制 -hud 分支"的主 App 分支与 roothide(JBROOT) 依赖。
//  HUD 用 root persona 拉起后，以无沙盒 + 系统 entitlements 创建全局系统窗口，
//  并接收全局 HID 触摸事件（让悬浮小女孩可点可拖）。
//

#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>
#import <objc/runtime.h>

#import "IOKit+SPI.h"
#import "HUDHelper.h"
#import "TSEventFetcher.h"
#import "BackboardServices.h"
#import "AXEventRepresentation.h"
#import "UIApplication+Private.h"

#define PID_PATH "/var/mobile/Library/Caches/trollagent.hud.pid"

static __used
NSString *mDeviceModel(void) {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
}

static __used
void _HUDEventCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    static UIApplication *app = [UIApplication sharedApplication];
    log_debug(OS_LOG_DEFAULT, "_HUDEventCallback => %{public}@", event);

    if (@available(iOS 15.1, *)) {}
    else {
        [app _enqueueHIDEvent:event];
    }

    BOOL shouldUseAXEvent = YES;

    BOOL isExactly15 = NO;
    static NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (version.majorVersion == 15 && version.minorVersion == 0 && version.patchVersion == 0) {
        NSString *deviceModel = mDeviceModel();
        if (![deviceModel hasPrefix:@"iPhone13,"] && ![deviceModel hasPrefix:@"iPhone14,"]) {
            isExactly15 = YES;
        }
    }

    if (@available(iOS 15.0, *)) {
        shouldUseAXEvent = !isExactly15;
    } else {
        shouldUseAXEvent = NO;
    }

    if (shouldUseAXEvent)
    {
        static Class AXEventRepresentationCls = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
            AXEventRepresentationCls = objc_getClass("AXEventRepresentation");
        });

        AXEventRepresentation *rep = [AXEventRepresentationCls representationWithHIDEvent:event hidStreamIdentifier:@"UIApplicationEvents"];

        dispatch_async(dispatch_get_main_queue(), ^(void) {
            static UIWindow *keyWindow = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                keyWindow = [[app windows] firstObject];
#pragma clang diagnostic pop
            });

            UIView *keyView = [keyWindow hitTest:[rep location] withEvent:nil];

            UITouchPhase phase = UITouchPhaseEnded;
            if ([rep isTouchDown])
                phase = UITouchPhaseBegan;
            else if ([rep isMove])
                phase = UITouchPhaseMoved;
            else if ([rep isCancel])
                phase = UITouchPhaseCancelled;
            else if ([rep isLift] || [rep isInRange] || [rep isInRangeLift])
                phase = UITouchPhaseEnded;

            NSInteger pointerId = [[[[rep handInfo] paths] firstObject] pathIdentity];
            if (pointerId > 0)
                [TSEventFetcher receiveAXEventID:MIN(MAX(pointerId, 1), 98) atGlobalCoordinate:[rep location] withTouchPhase:phase inWindow:keyWindow onView:keyView];
        });
    }
}

int main(int argc, char *argv[])
{
    @autoreleasepool
    {
        NSString *pidPath = @(PID_PATH);

        // -exit：根据 pid 文件杀掉 HUD 进程（主 App 关闭悬浮用）
        if (argc > 1 && strcmp(argv[1], "-exit") == 0)
        {
            NSString *pidString = [NSString stringWithContentsOfFile:pidPath
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
            if (pidString)
            {
                pid_t pid = (pid_t)[pidString intValue];
                kill(pid, SIGKILL);
                unlink([pidPath UTF8String]);
            }
            return EXIT_SUCCESS;
        }

        // -check：查 HUD 是否在跑（主 App 判断悬浮状态用）
        if (argc > 1 && strcmp(argv[1], "-check") == 0)
        {
            NSString *pidString = [NSString stringWithContentsOfFile:pidPath
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
            if (pidString)
            {
                pid_t pid = (pid_t)[pidString intValue];
                int alive = kill(pid, 0);
                return (alive == 0 ? EXIT_FAILURE : EXIT_SUCCESS);
            }
            else return EXIT_SUCCESS;
        }

        // 直接进入 HUD 悬浮模式（独立 HUD 二进制，无需 -hud 参数）
        log_debug(OS_LOG_DEFAULT, "HUD launched");

        pid_t pid = getpid();
        NSString *pidString = [NSString stringWithFormat:@"%d", pid];
        [pidString writeToFile:pidPath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:nil];

        [UIScreen initialize];
        CFRunLoopGetCurrent();

        GSInitialize();
        BKSDisplayServicesStart();
        UIApplicationInitialize();

        UIApplicationInstantiateSingleton(objc_getClass("HUDMainApplication"));
        static id<UIApplicationDelegate> appDelegate = [[objc_getClass("HUDMainApplicationDelegate") alloc] init];
        [UIApplication.sharedApplication setDelegate:appDelegate];
        [UIApplication.sharedApplication _accessibilityInit];

        [NSRunLoop currentRunLoop];
        BKSHIDEventRegisterEventCallback(_HUDEventCallback);

        if (@available(iOS 15.0, *)) {
            GSEventInitialize(0);
            GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
        }

        [UIApplication.sharedApplication __completeAndRunAsPlugin];

        CFRunLoopRun();
        return EXIT_SUCCESS;
    }
}
