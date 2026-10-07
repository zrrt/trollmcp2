//
//  HUDMainApplicationDelegate.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <objc/runtime.h>

#import "HUDMainApplicationDelegate.h"
#import "HUDMainWindow.h"
#import "HUDRootViewController.h"

#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"

@implementation HUDMainApplicationDelegate {
    HUDRootViewController *_rootViewController;
    SBSAccessibilityWindowHostingController *_windowHostingController;
    UIBackgroundTaskIdentifier _backgroundTask;
}

- (instancetype)init
{
    if (self = [super init])
    {
        log_debug(OS_LOG_DEFAULT, "- [HUDMainApplicationDelegate init]");
    }
    return self;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    log_debug(OS_LOG_DEFAULT, "- [HUDMainApplicationDelegate application:%{public}@ didFinishLaunchingWithOptions:%{public}@]", application, launchOptions);

    _rootViewController = [[HUDRootViewController alloc] init];

    self.window = [[HUDMainWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window setRootViewController:_rootViewController];
    
    [self.window setWindowLevel:10000010.0];
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

    _windowHostingController = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init];
    unsigned int _contextId = [self.window _contextId];
    double windowLevel = [self.window windowLevel];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    // [_windowHostingController registerWindowWithContextID:_contextId atLevel:windowLevel];
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:_windowHostingController];
    [invocation setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [invocation setArgument:&_contextId atIndex:2];
    [invocation setArgument:&windowLevel atIndex:3];
    [invocation invoke];
#pragma clang diagnostic pop

    return YES;
}

// 保活（抄 TheBall FloatingBallBackgroundManager）：HUD 是 posix_spawn 后台进程，
// 没有 beginBackgroundTask 会被系统当后台进程迅速杀掉。进后台即申请后台任务保持存活。
- (void)applicationDidEnterBackground:(UIApplication *)application
{
    _backgroundTask = [application beginBackgroundTaskWithName:@"trollagent.hud.keepalive" expirationHandler:^{
        [application endBackgroundTask:self->_backgroundTask];
        self->_backgroundTask = UIBackgroundTaskInvalid;
    }];
    log_debug(OS_LOG_DEFAULT, "HUD keepalive beginBackgroundTask=%lu", (unsigned long)_backgroundTask);
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    if (_backgroundTask != UIBackgroundTaskInvalid) {
        [application endBackgroundTask:_backgroundTask];
        _backgroundTask = UIBackgroundTaskInvalid;
    }
}

@end
