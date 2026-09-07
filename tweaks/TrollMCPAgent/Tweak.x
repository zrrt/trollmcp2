#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// TrollMCPAgent v4.0 — 通用 agent dylib（通知驱动版）
// 由 v3 老成品二进制重写为源码：v3 注入任意 App 闪退（无源码不可修），
// v4 设计原则：加载时零 UI 操作，只注册通知；所有 UI 操作主线程 + nil 保护；
// 不依赖任何具体 App 类名/结构，兼容 iOS 14-18。
// 协议：监听 dev.trollmcp.automation-command / TROLLMCP_AUTOMATE_V1（NSNotification，
//       object=userInfo JSON dict），执行后发 dev.trollmcp.automation-result / TROLLMCP_RESULT_V1
// 命令 payload: {"id":"xxx","action":"status|get_ui_tree|tap|swipe|type|scroll",
//                "x":..,"y":..,"x1":..,"y1":..,"x2":..,"y2":..,"duration":..,"text":"..","direction":".."}
// 结果 payload: {"id":"xxx","success":true/false,"data":{...},"error":".."}

#define kCmdName   @"dev.trollmcp.automation-command"
#define kCmdV1Name @"TROLLMCP_AUTOMATE_V1"
#define kResName   @"dev.trollmcp.automation-result"
#define kResV1Name @"TROLLMCP_RESULT_V1"
#define kMaxUITreeNodes 500

static NSString *safeStr(id v) {
    return v && [v isKindOfClass:[NSString class]] ? v : @"";
}

// ---------- UI 辅助（与 ControlAgent 同源，已修正窗口兜底死递归） ----------
static NSArray<UIWindow *> *agentAllWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
    }
    if (windows.count == 0) {
        // fallback：iOS 14 兼容（iOS 15+ 该方法已废弃但可用）
        [windows addObjectsFromArray:[[UIApplication sharedApplication] windows]];
    }
    return windows;
}

static UIWindow *agentKeyWindow(void) {
    NSArray *windows = agentAllWindows();
    for (UIWindow *w in windows) {
        if (w.isKeyWindow) return w;
    }
    return windows.firstObject;
}

@interface UIView (TMAgent_FirstResponder)
- (UIView *)tma_findFirstResponder;
@end
@implementation UIView (TMAgent_FirstResponder)
- (UIView *)tma_findFirstResponder {
    if (self.isFirstResponder) return self;
    for (UIView *sub in self.subviews) {
        UIView *found = [sub tma_findFirstResponder];
        if (found) return found;
    }
    return nil;
}
@end

static void agentSimulateTouch(CGPoint point, UIWindow *window) {
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"locationInWindow"];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"previousLocationInWindow"];
    [touch setValue:window forKey:@"window"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:@(1) forKey:@"tapCount"];
    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
    [window sendEvent:event];
    [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
    [window sendEvent:event];
}

static NSMutableDictionary *agentUITree(UIView *view, NSInteger depth, NSInteger *counter) {
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    if (!view || *counter >= kMaxUITreeNodes) return node;
    (*counter)++;
    node[@"idx"] = @(*counter);
    node[@"class"] = NSStringFromClass(view.class) ?: @"";
    NSString *accLabel = view.accessibilityLabel;
    if (accLabel.length) node[@"acc"] = accLabel;
    NSString *t = nil;
    if ([view isKindOfClass:[UILabel class]]) t = ((UILabel *)view).text;
    else if ([view isKindOfClass:[UIButton class]]) t = ((UIButton *)view).currentTitle;
    else if ([view isKindOfClass:[UITextField class]]) t = ((UITextField *)view).text;
    else if ([view isKindOfClass:[UITextView class]]) t = ((UITextView *)view).text;
    if (t.length) node[@"text"] = t;
    CGRect f = view.frame;
    node[@"frame"] = @{@"x": @(f.origin.x), @"y": @(f.origin.y),
                       @"w": @(f.size.width), @"h": @(f.size.height)};
    node[@"alpha"] = @(view.alpha);
    node[@"hidden"] = @(view.hidden);
    NSMutableArray *children = [NSMutableArray array];
    if (depth < 6) {
        for (UIView *sub in view.subviews) {
            NSMutableDictionary *cn = agentUITree(sub, depth + 1, counter);
            if (cn.count) [children addObject:cn];
        }
    }
    if (children.count) node[@"children"] = children;
    return node;
}

// ---------- 命令处理 ----------
static NSDictionary *actionStatus(void) {
    NSBundle *b = [NSBundle mainBundle];
    NSDictionary *info = b.infoDictionary;
    UIApplication *app = [UIApplication sharedApplication];
    return @{
        @"app": safeStr(info[@"CFBundleDisplayName"]).length ? safeStr(info[@"CFBundleDisplayName"]) : safeStr(info[@"CFBundleName"]),
        @"bundle_id": safeStr(b.bundleIdentifier),
        @"version": safeStr(info[@"CFBundleShortVersionString"]),
        @"windows": @(agentAllWindows().count),
        @"agent_version": @"4.0"
    };
}

static NSDictionary *actionGetUITree(void) {
    UIWindow *key = agentKeyWindow();
    if (!key) return @{@"error": @"no key window", @"nodes": @[]};
    NSInteger counter = 0;
    NSMutableDictionary *root = agentUITree(key, 0, &counter);
    return @{@"nodes": root[@"children"] ?: @[], @"node_count": @(counter)};
}

static NSDictionary *actionTap(NSDictionary *p) {
    CGFloat x = [p[@"x"] doubleValue], y = [p[@"y"] doubleValue];
    UIWindow *key = agentKeyWindow();
    if (!key) return @{@"error": @"no key window"};
    CGPoint point = CGPointMake(x, y);
    UIView *hit = [key hitTest:point withEvent:nil];
    agentSimulateTouch(point, key);
    return @{@"tapped": @YES,
             @"view": hit ? (NSStringFromClass(hit.class) ?: @"") : @"",
             @"frame": hit ? NSStringFromCGRect(hit.frame) : @""};
}

static NSDictionary *actionSwipe(NSDictionary *p) {
    CGFloat x1 = [p[@"x1"] doubleValue], y1 = [p[@"y1"] doubleValue];
    CGFloat x2 = [p[@"x2"] doubleValue], y2 = [p[@"y2"] doubleValue];
    CGFloat dur = [p[@"duration"] doubleValue] > 0 ? [p[@"duration"] doubleValue] : 0.3;
    UIWindow *key = agentKeyWindow();
    if (!key) return @{@"error": @"no key window"};
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:[NSValue valueWithCGPoint:CGPointMake(x1, y1)] forKey:@"locationInWindow"];
    [touch setValue:[NSValue valueWithCGPoint:CGPointMake(x1, y1)] forKey:@"previousLocationInWindow"];
    [touch setValue:key forKey:@"window"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:@(1) forKey:@"tapCount"];
    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
    [key sendEvent:event];
    NSUInteger steps = MAX(4, (NSUInteger)(dur * 30));
    for (NSUInteger i = 1; i <= steps; i++) {
        CGFloat t = (CGFloat)i / steps;
        CGPoint now = CGPointMake(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
        [touch setValue:[NSValue valueWithCGPoint:now] forKey:@"locationInWindow"];
        [touch setValue:@(UITouchPhaseMoved) forKey:@"phase"];
        [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
        [key sendEvent:event];
        usleep(16000);
    }
    [touch setValue:[NSValue valueWithCGPoint:CGPointMake(x2, y2)] forKey:@"locationInWindow"];
    [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
    [key sendEvent:event];
    return @{@"swiped": @YES};
}

static NSDictionary *actionType(NSDictionary *p) {
    NSString *text = safeStr(p[@"text"]);
    UIView *fr = [agentKeyWindow() tma_findFirstResponder];
    if (!fr) return @{@"error": @"no first responder"};
    if ([fr conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> input = (id<UITextInput>)fr;
        [input insertText:text];
        return @{@"typed": @(text.length)};
    }
    if ([fr isKindOfClass:[UITextField class]]) {
        ((UITextField *)fr).text = text;
        return @{@"typed": @(text.length), @"mode": @"assign"};
    }
    return @{@"error": @"target not text input"};
}

static NSDictionary *actionScroll(NSDictionary *p) {
    NSString *dir = safeStr(p[@"direction"]);
    CGFloat dy = 0, dx = 0;
    if ([dir isEqualToString:@"up"]) dy = 200;
    else if ([dir isEqualToString:@"down"]) dy = -200;
    else if ([dir isEqualToString:@"left"]) dx = 200;
    else if ([dir isEqualToString:@"right"]) dx = -200;
    UIWindow *key = agentKeyWindow();
    if (!key) return @{@"error": @"no key window"};
    CGSize sz = key.bounds.size;
    return actionSwipe(@{@"x1": @(sz.width/2), @"y1": @(sz.height/2),
                         @"x2": @(sz.width/2 + dx), @"y2": @(sz.height/2 + dy),
                         @"duration": @(0.25)});
}

static void handleCommand(NSDictionary *payload) {
    NSString *action = safeStr(payload[@"action"]);
    NSString *cmdId = safeStr(payload[@"id"]);
    NSDictionary *data = nil;
    BOOL ok = YES;
    if ([action isEqualToString:@"status"]) {
        data = actionStatus();
    } else if ([action isEqualToString:@"get_ui_tree"]) {
        data = actionGetUITree();
    } else if ([action isEqualToString:@"tap"]) {
        data = actionTap(payload);
    } else if ([action isEqualToString:@"swipe"]) {
        data = actionSwipe(payload);
    } else if ([action isEqualToString:@"type"]) {
        data = actionType(payload);
    } else if ([action isEqualToString:@"scroll"]) {
        data = actionScroll(payload);
    } else {
        ok = NO;
        data = @{@"error": [NSString stringWithFormat:@"unknown action: %@", action]};
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (cmdId.length) result[@"id"] = cmdId;
    result[@"action"] = action;
    result[@"success"] = @(ok);
    if (data[@"error"]) result[@"error"] = data[@"error"];
    result[@"data"] = data ?: @{};
    [[NSNotificationCenter defaultCenter] postNotificationName:kResName object:nil userInfo:result];
    [[NSNotificationCenter defaultCenter] postNotificationName:kResV1Name object:nil userInfo:result];
    // 兜底：写 UserDefaults（主 App 可用进程内/跨进程读取）
    if (cmdId.length) {
        NSString *key = [NSString stringWithFormat:@"trollmcp_result_%@", cmdId];
        NSData *jdata = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (jdata) {
            [[NSUserDefaults standardUserDefaults] setObject:[[NSString alloc] initWithData:jdata encoding:NSUTF8StringEncoding] forKey:key];
        }
    }
}

static void observeCommandNotification(NSNotification *note) {
    id obj = note.object;
    NSDictionary *payload = nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        payload = obj;
    } else if ([obj isKindOfClass:[NSData class]]) {
        payload = [NSJSONSerialization JSONObjectWithData:obj options:0 error:nil];
    } else if (note.userInfo) {
        payload = note.userInfo;
    }
    if (![payload isKindOfClass:[NSDictionary class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            handleCommand(payload);
        } @catch (NSException *e) {
            NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:payload];
            r[@"success"] = @NO;
            r[@"error"] = [NSString stringWithFormat:@"exception: %@", e.reason];
            [[NSNotificationCenter defaultCenter] postNotificationName:kResName object:nil userInfo:r];
        }
    });
}

__attribute__((constructor))
static void trollmcp_agent_init(void) {
    // 加载时只注册通知监听，绝不触碰 UI —— 保证注入任何 App 都不闪退
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:kCmdName object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { observeCommandNotification(note); }];
    [nc addObserverForName:kCmdV1Name object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { observeCommandNotification(note); }];
}
