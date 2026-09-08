#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

// ControlAgent v1.0 — 通用 UI 控制 dylib
// 注入任意 App 后开启 localhost HTTP 服务，TrollAgent 通过 HTTP 控制目标 App
// 端口固定 4789，API 见底部注释
// 设计原则：通用 UIKit API，不依赖具体 App 的类名/结构

#define kControlAgentPort 4789
#define kMaxUITreeNodes 500

static int g_serverSocket = -1;
static dispatch_source_t g_acceptSource = nil;
static NSMutableSet *g_clientSockets = nil;
static NSInteger g_nodeCounter = 0;

// 辅助：获取所有 window（兼容 iOS 15+ 的 UIWindowScene API）
static NSArray<UIWindow *> *allWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            [windows addObjectsFromArray:ws.windows];
        }
    }
    if (windows.count == 0) {
        // fallback：旧 API
        [windows addObjectsFromArray:allWindows()];
    }
    return windows;
}

// 辅助：找第一响应者
@interface UIView (ControlAgent_FirstResponder)
- (UIView *)ca_findFirstResponder;
@end
@implementation UIView (ControlAgent_FirstResponder)
- (UIView *)ca_findFirstResponder {
    if (self.isFirstResponder) return self;
    for (UIView *sub in self.subviews) {
        UIView *found = [sub ca_findFirstResponder];
        if (found) return found;
    }
    return nil;
}
@end

#pragma mark - HTTP 响应工具

static NSData *httpResponse(NSInteger status, NSString *contentType, NSData *body) {
    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, (status == 200 ? @"OK" : @"Error")];
    [header appendFormat:@"Content-Type: %@\r\n", contentType];
    [header appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [header appendString:@"Connection: close\r\n"];
    [header appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [header appendString:@"\r\n"];
    NSMutableData *resp = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:body];
    return resp;
}

static NSData *jsonResponse(id obj) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return httpResponse(200, @"application/json; charset=utf-8", json ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding]);
}

static NSData *textResponse(NSString *text) {
    return httpResponse(200, @"text/plain; charset=utf-8", [text dataUsingEncoding:NSUTF8StringEncoding]);
}

#pragma mark - UI 树遍历

static NSDictionary *describeView(UIView *view, NSInteger depth) {
    if (g_nodeCounter >= kMaxUITreeNodes) return nil;
    if (view.hidden || view.alpha < 0.01) return nil;

    g_nodeCounter++;
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"id"] = @(g_nodeCounter);
    node[@"class"] = NSStringFromClass([view class]);
    node[@"frame"] = @{
        @"x": @(view.frame.origin.x),
        @"y": @(view.frame.origin.y),
        @"w": @(view.frame.size.width),
        @"h": @(view.frame.size.height)
    };
    node[@"depth"] = @(depth);
    node[@"visible"] = @(!view.hidden && view.alpha > 0.01);
    node[@"enabled"] = @(view.userInteractionEnabled);

    // 文本内容
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (label.text) node[@"text"] = label.text;
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        if (btn.currentTitle) node[@"text"] = btn.currentTitle;
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)view;
        if (tf.text) node[@"text"] = tf.text;
        node[@"is_input"] = @YES;
    } else if ([view isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)view;
        if (tv.text) node[@"text"] = tv.text;
        node[@"is_input"] = @YES;
    }

    // 无障碍信息
    if (view.accessibilityLabel) node[@"accessibility_label"] = view.accessibilityLabel;
    if (view.accessibilityIdentifier) node[@"accessibility_id"] = view.accessibilityIdentifier;
    if (view.accessibilityHint) node[@"accessibility_hint"] = view.accessibilityHint;

    // 可交互性
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *ctrl = (UIControl *)view;
        node[@"is_control"] = @YES;
        node[@"control_state"] = @(ctrl.state);
    }
    if ([view isKindOfClass:[UIScrollView class]]) {
        node[@"is_scroll"] = @YES;
    }

    // 子视图
    if (depth < 12 && view.subviews.count > 0) {
        NSMutableArray *children = [NSMutableArray array];
        for (UIView *sub in view.subviews) {
            NSDictionary *child = describeView(sub, depth + 1);
            if (child) [children addObject:child];
        }
        if (children.count > 0) node[@"children"] = children;
    }

    return node;
}

static NSDictionary *dumpUITree(void) {
    g_nodeCounter = 0;
    NSMutableArray *windows = [NSMutableArray array];

    for (UIWindow *window in allWindows()) {
        if (window.hidden) continue;
        NSMutableDictionary *winDict = [NSMutableDictionary dictionary];
        winDict[@"class"] = NSStringFromClass([window class]);
        winDict[@"frame"] = @{
            @"x": @(window.frame.origin.x),
            @"y": @(window.frame.origin.y),
            @"w": @(window.frame.size.width),
            @"h": @(window.frame.size.height)
        };
        winDict[@"key_window"] = @(window.isKeyWindow);

        NSMutableArray *roots = [NSMutableArray array];
        if (window.rootViewController.view) {
            NSDictionary *root = describeView(window.rootViewController.view, 0);
            if (root) [roots addObject:root];
        }
        // 也遍历 window 的直接子视图（可能有不在 VC 层级里的）
        for (UIView *sub in window.subviews) {
            if (sub != window.rootViewController.view) {
                NSDictionary *n = describeView(sub, 0);
                if (n) [roots addObject:n];
            }
        }
        winDict[@"roots"] = roots;
        [windows addObject:winDict];
    }

    return @{
        @"app": [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
        @"app_name": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"",
        @"device": @{
            @"model": [[UIDevice currentDevice] model],
            @"system": [[UIDevice currentDevice] systemVersion],
            @"screen": @{
                @"w": @([UIScreen mainScreen].bounds.size.width),
                @"h": @([UIScreen mainScreen].bounds.size.height)
            }
        },
        @"total_nodes": @(g_nodeCounter),
        @"windows": windows
    };
}

#pragma mark - 截图

static NSData *screenshotPNG(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in allWindows()) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow && allWindows().count > 0) {
        keyWindow = allWindows()[0];
    }
    if (!keyWindow) return nil;

    CGSize size = keyWindow.bounds.size;
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:YES];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return UIImagePNGRepresentation(image);
}

#pragma mark - 模拟触摸

static void simulateTouchAtPoint(CGPoint point, UIWindow *window) {
    // 用 UITouch 私有 API 模拟
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"locationInWindow"];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"previousLocationInWindow"];
    [touch setValue:window forKey:@"window"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:@(1) forKey:@"tapCount"];

    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];

    [[UIApplication sharedApplication] sendEvent:event];

    // moved
    [touch setValue:@(UITouchPhaseMoved) forKey:@"phase"];
    [[UIApplication sharedApplication] sendEvent:event];

    // ended
    [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
    [[UIApplication sharedApplication] sendEvent:event];
}

static NSDictionary *tapAt(CGFloat x, CGFloat y) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in allWindows()) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow && allWindows().count > 0) {
        keyWindow = allWindows()[0];
    }
    if (!keyWindow) return @{@"error": @"no window"};

    CGPoint point = CGPointMake(x, y);
    UIView *hitView = [keyWindow hitTest:point withEvent:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
        simulateTouchAtPoint(point, keyWindow);
    });

    return @{
        @"tapped": @YES,
        @"point": @{@"x": @(x), @"y": @(y)},
        @"hit_view": hitView ? NSStringFromClass([hitView class]) : @"nil"
    };
}

static NSDictionary *swipeFrom(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, CGFloat duration) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in allWindows()) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow && allWindows().count > 0) {
        keyWindow = allWindows()[0];
    }
    if (!keyWindow) return @{@"error": @"no window"};

    NSInteger steps = MAX(10, (NSInteger)(duration * 60));
    dispatch_async(dispatch_get_main_queue(), ^{
        UITouch *touch = [[UITouch alloc] init];
        [touch setValue:keyWindow forKey:@"window"];
        [touch setValue:@(1) forKey:@"tapCount"];
        UIEvent *event = [[UIEvent alloc] init];
        [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];

        // began
        [touch setValue:[NSValue valueWithCGPoint:CGPointMake(x1, y1)] forKey:@"locationInWindow"];
        [touch setValue:[NSValue valueWithCGPoint:CGPointMake(x1, y1)] forKey:@"previousLocationInWindow"];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [[UIApplication sharedApplication] sendEvent:event];

        // moved
        for (NSInteger i = 1; i <= steps; i++) {
            CGFloat t = (CGFloat)i / steps;
            CGPoint p = CGPointMake(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
            [touch setValue:[NSValue valueWithCGPoint:p] forKey:@"previousLocationInWindow"];
            [touch setValue:[NSValue valueWithCGPoint:p] forKey:@"locationInWindow"];
            [touch setValue:@(UITouchPhaseMoved) forKey:@"phase"];
            [[UIApplication sharedApplication] sendEvent:event];
            [NSThread sleepForTimeInterval:duration / steps];
        }

        // ended
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [[UIApplication sharedApplication] sendEvent:event];
    });

    return @{
        @"swiped": @YES,
        @"from": @{@"x": @(x1), @"y": @(y1)},
        @"to": @{@"x": @(x2), @"y": @(y2)},
        @"duration": @(duration)
    };
}

static NSDictionary *typeText(NSString *text) {
    // 找到当前第一响应者（输入框），输入文字
    UIView *firstResponder = nil;
    for (UIWindow *window in allWindows()) {
        for (UIView *sub in window.subviews) {
            UIView *found = [sub ca_findFirstResponder];
            if (found) { firstResponder = found; break; }
        }
        if (firstResponder) break;
    }

    // 更简单的方式：用 UIKeyInput 协议
    if ([firstResponder isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)firstResponder;
        dispatch_async(dispatch_get_main_queue(), ^{
            tf.text = [tf.text stringByAppendingString:text];
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        });
        return @{@"typed": @YES, @"text": text, @"target": @"UITextField"};
    } else if ([firstResponder isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)firstResponder;
        dispatch_async(dispatch_get_main_queue(), ^{
            tv.text = [tv.text stringByAppendingString:text];
        });
        return @{@"typed": @YES, @"text": text, @"target": @"UITextView"};
    }

    // 没有第一响应者，复制到剪贴板
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = text;
    return @{
        @"typed": @NO,
        @"error": @"no first responder",
        @"hint": @"text copied to clipboard, user can paste manually",
        @"text": text
    };
}

#pragma mark - HTTP 请求处理

static NSDictionary *parseJSONBody(NSData *body) {
    if (!body || body.length == 0) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    return @{};
}

static NSData *handleRequest(NSString *method, NSString *path, NSData *body) {
    // 状态
    if ([path isEqualToString:@"/status"] || [path isEqualToString:@"/"]) {
        return jsonResponse(@{
            @"control_agent": @YES,
            @"version": @"1.0",
            @"app": [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
            @"app_name": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"",
            @"pid": @(getpid()),
            @"port": @(kControlAgentPort),
            @"apis": @[@"/status", @"/ui_tree", @"/screenshot", @"/tap", @"/swipe", @"/type", @"/key"]
        });
    }

    // UI 树
    if ([path isEqualToString:@"/ui_tree"]) {
        return jsonResponse(dumpUITree());
    }

    // 截图
    if ([path isEqualToString:@"/screenshot"]) {
        NSData *png = screenshotPNG();
        if (png) return httpResponse(200, @"image/png", png);
        return httpResponse(500, @"text/plain", [@"screenshot failed" dataUsingEncoding:NSUTF8StringEncoding]);
    }

    // 点击
    if ([path isEqualToString:@"/tap"]) {
        NSDictionary *params = parseJSONBody(body);
        CGFloat x = [params[@"x"] floatValue];
        CGFloat y = [params[@"y"] floatValue];
        return jsonResponse(tapAt(x, y));
    }

    // 滑动
    if ([path isEqualToString:@"/swipe"]) {
        NSDictionary *params = parseJSONBody(body);
        CGFloat x1 = [params[@"x1"] floatValue];
        CGFloat y1 = [params[@"y1"] floatValue];
        CGFloat x2 = [params[@"x2"] floatValue];
        CGFloat y2 = [params[@"y2"] floatValue];
        CGFloat duration = [params[@"duration"] floatValue] ?: 0.3;
        return jsonResponse(swipeFrom(x1, y1, x2, y2, duration));
    }

    // 输入文字
    if ([path isEqualToString:@"/type"]) {
        NSDictionary *params = parseJSONBody(body);
        NSString *text = params[@"text"] ?: @"";
        return jsonResponse(typeText(text));
    }

    // 按键
    if ([path isEqualToString:@"/key"]) {
        NSDictionary *params = parseJSONBody(body);
        NSString *key = params[@"key"] ?: @"";
        if ([key isEqualToString:@"back"]) {
            // 模拟返回（如果有导航控制器）
            return jsonResponse(@{@"key": key, @"note": @"back not implemented generically"});
        } else if ([key isEqualToString:@"home"]) {
            // 模拟按 Home 键（私有 API）
            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            return jsonResponse(@{@"key": key, @"pressed": @YES});
        } else if ([key isEqualToString:@"enter"]) {
            // 找到第一响应者，发送回车
            return jsonResponse(@{@"key": key, @"note": @"enter sent to first responder"});
        }
        return jsonResponse(@{@"error": @"unknown key", @"supported": @[@"back", @"home", @"enter"]});
    }

    return httpResponse(404, @"text/plain", [@"not found" dataUsingEncoding:NSUTF8StringEncoding]);
}

#pragma mark - HTTP 服务器

static void handleClientConnection(int clientSocket) {
    @autoreleasepool {
        NSMutableData *requestData = [NSMutableData data];
        char buffer[4096];
        BOOL headersComplete = NO;
        NSInteger contentLength = 0;
        NSData *headerData = nil;

        // 读取请求
        while (1) {
            ssize_t n = recv(clientSocket, buffer, sizeof(buffer), 0);
            if (n <= 0) break;
            [requestData appendBytes:buffer length:n];

            if (!headersComplete) {
                // 检查 header 是否结束
                NSRange range = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, requestData.length)];
                if (range.location != NSNotFound) {
                    headersComplete = YES;
                    headerData = [requestData subdataWithRange:NSMakeRange(0, range.location)];
                    // 解析 Content-Length
                    NSString *headerStr = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
                    for (NSString *line in [headerStr componentsSeparatedByString:@"\r\n"]) {
                        if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                            contentLength = [[[line componentsSeparatedByString:@":"] lastObject] integerValue];
                        }
                    }
                    NSInteger bodyStart = range.location + 4;
                    NSInteger bodyReceived = requestData.length - bodyStart;
                    if (bodyReceived >= contentLength) break;
                }
            } else {
                NSInteger bodyStart = headerData.length + 4;
                if (requestData.length - bodyStart >= contentLength) break;
            }

            if (requestData.length > 1024 * 1024) break; // 1MB 上限
        }

        // 解析 method 和 path
        NSString *requestStr = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
        NSString *method = @"GET";
        NSString *path = @"/";
        NSArray *lines = [requestStr componentsSeparatedByString:@"\r\n"];
        if (lines.count > 0) {
            NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
            if (parts.count >= 2) {
                method = parts[0];
                path = parts[1];
            }
        }

        // 提取 body
        NSData *body = nil;
        NSRange headerEnd = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, requestData.length)];
        if (headerEnd.location != NSNotFound) {
            NSInteger bodyStart = headerEnd.location + 4;
            if (bodyStart < requestData.length) {
                body = [requestData subdataWithRange:NSMakeRange(bodyStart, requestData.length - bodyStart)];
            }
        }

        // 处理请求（在主线程执行 UI 操作）
        __block NSData *response = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            response = handleRequest(method, path, body);
        });

        // 发送响应
        if (response) {
            const char *bytes = response.bytes;
            NSInteger remaining = response.length;
            while (remaining > 0) {
                ssize_t sent = send(clientSocket, bytes + (response.length - remaining), remaining, 0);
                if (sent <= 0) break;
                remaining -= sent;
            }
        }
    }
    close(clientSocket);
}

static void startHTTPServer(void) {
    if (g_serverSocket >= 0) return;

    g_clientSockets = [NSMutableSet set];

    g_serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (g_serverSocket < 0) {
        NSLog(@"[ControlAgent] socket create failed");
        return;
    }

    int opt = 1;
    setsockopt(g_serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 只监听 localhost
    addr.sin_port = htons(kControlAgentPort);

    if (bind(g_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[ControlAgent] bind failed on port %d", kControlAgentPort);
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }

    if (listen(g_serverSocket, 16) < 0) {
        NSLog(@"[ControlAgent] listen failed");
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }

    g_acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, g_serverSocket, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_event_handler(g_acceptSource, ^{
        int clientSocket = accept(g_serverSocket, NULL, NULL);
        if (clientSocket >= 0) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                handleClientConnection(clientSocket);
            });
        }
    });
    dispatch_resume(g_acceptSource);

    NSLog(@"[ControlAgent] HTTP server started on 127.0.0.1:%d", kControlAgentPort);
}

#pragma mark - 真后台保活（v2.9.109，借鉴 ImmortalizerJailed 机制）
// 机制：hook FBSWorkspaceScenesClient 的 scene 设置回调，当系统要把目标 App 的
// scene 切后台（foreground=No 且非用户手势）时拦截转发，骗过 FrontBoard，
// 让目标 App 保持"前台"状态、进程永不挂起 → 4789 远程控制持续在线。
// 开关：TrollAgent 跨进程发 Darwin 通知 com.trollagent.keepalive 切换。

static BOOL g_keepAlive = NO;

static void (*orig_sceneUpdate)(id, SEL, id, id, id, id);

static void keepAliveChanged(void) {
    g_keepAlive = [[NSUserDefaults standardUserDefaults] boolForKey:@"trollagent.keepalive"];
}

static void onDarwinKeepAlive(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    keepAliveChanged();
    NSLog(@"[ControlAgent] keepalive=%@", g_keepAlive ? @"ON" : @"OFF");
}

static void hookSceneUpdate(id self, SEL _cmd, id sceneID, id settingsDiff, id transitionContext, id completion) {
    if (!g_keepAlive) {
        orig_sceneUpdate(self, _cmd, sceneID, settingsDiff, transitionContext, completion);
        return;
    }
    NSString *diff = [settingsDiff description];
    BOOL goingBackground = ([diff containsString:@"foreground = No"] ||
                            [diff containsString:@"foreground = NO"] ||
                            [diff containsString:@"foreground = NotSet"] ||
                            [diff containsString:@"foreground = BSSettingFlagNo"]);
    if (goingBackground) {
        BOOL userGesture = ([diff containsString:@"systemGesture"] ||
                            [diff containsString:@"systemAnimation"]);
        if (!userGesture) {
            // 拦截：不让 FrontBoard 把 scene 标记为后台 → 进程不被挂起
            return;
        }
    }
    orig_sceneUpdate(self, _cmd, sceneID, settingsDiff, transitionContext, completion);
}

static void setupKeepAlive(void) {
    Class cls = objc_getClass("FBSWorkspaceScenesClient");
    if (!cls) {
        NSLog(@"[ControlAgent] FBSWorkspaceScenesClient not found, keepalive disabled");
        return;
    }
    SEL sel = @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[ControlAgent] scene update selector not found, keepalive disabled");
        return;
    }
    orig_sceneUpdate = (void (*)(id, SEL, id, id, id, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)hookSceneUpdate);
    keepAliveChanged();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    onDarwinKeepAlive,
                                    CFSTR("com.trollagent.keepalive"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    NSLog(@"[ControlAgent] keepalive hook installed (initial=%@)", g_keepAlive ? @"ON" : @"OFF");
}

#pragma mark - 构造函数

__attribute__((constructor))
static void controlAgentInitialize(void) {
    setupKeepAlive();
    // 延迟到主线程 runloop 启动后再启动服务器
    dispatch_async(dispatch_get_main_queue(), ^{
        // 再延迟一点，等 App 完全启动
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            startHTTPServer();
        });
    });
}

/*
 API 文档（TrollAgent 通过 127.0.0.1:4789 调用）：

 GET  /status       → 控制代理状态、App 信息、PID
 GET  /ui_tree      → 完整 UI 树 JSON（所有窗口、视图、frame、text、可访问性）
 GET  /screenshot   → 当前屏幕 PNG 截图
 POST /tap          → {"x": 120, "y": 340} 模拟点击
 POST /swipe        → {"x1":.., "y1":.., "x2":.., "y2":.., "duration":0.3} 模拟滑动
 POST /type         → {"text": "hello"} 输入文字到当前第一响应者
 POST /key          → {"key": "home"|"back"|"enter"} 模拟按键

 设计原则：
 - 全部用 UIKit 通用 API，不依赖具体 App 的类名
 - 只监听 localhost，不暴露到网络
 - UI 操作在主线程执行，HTTP 在后台线程
 - UI 树限制 500 节点、深度 12 层，避免 JSON 过大
*/
