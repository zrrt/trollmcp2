#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

// TrollMCPAgent v4.1 — 通用 agent dylib（HTTP + 通知双通道）
// v4 修复了注入闪退（加载时零 UI 操作）；v4.1 修复跨进程通信：
//   v3/v4 的 NSNotificationCenter 通知和 NSUserDefaults 队列都受沙盒隔离，主 App 与目标 App
//   根本不通 → apps.open_and_input 此前是断链。v4.1 内置本地 HTTP server（127.0.0.1:4792），
//   主 App 通过 loopback 直接调用，链路真实可用；通知通道保留供同进程调试。
// 安全设计：加载零 UI 操作；UI 操作一律主线程 + nil 保护 + try/catch；不依赖任何具体 App 类名。

#define kCmdName   @"dev.trollmcp.automation-command"
#define kCmdV1Name @"TROLLMCP_AUTOMATE_V1"
#define kResName   @"dev.trollmcp.automation-result"
#define kResV1Name @"TROLLMCP_RESULT_V1"
#define kAgentPort 4792
#define kMaxUITreeNodes 500
#define kAgentVersion @"4.1"

static int g_serverSocket = -1;
static dispatch_source_t g_acceptSource;
static NSMutableSet *g_clientSockets;

static NSString *safeStr(id v) {
    return v && [v isKindOfClass:[NSString class]] ? v : @"";
}

#pragma mark - UI 辅助

static NSArray<UIWindow *> *agentAllWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
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
    if (view.hidden || view.alpha < 0.01) return node;
    (*counter)++;
    node[@"idx"] = @(*counter);
    node[@"class"] = NSStringFromClass(view.class) ?: @"";
    node[@"frame"] = @{@"x": @(view.frame.origin.x), @"y": @(view.frame.origin.y),
                       @"w": @(view.frame.size.width), @"h": @(view.frame.size.height)};
    node[@"visible"] = @YES;
    NSString *acc = view.accessibilityLabel;
    if (acc.length) node[@"acc"] = acc;
    NSString *t = nil;
    if ([view isKindOfClass:[UILabel class]]) t = ((UILabel *)view).text;
    else if ([view isKindOfClass:[UIButton class]]) t = ((UIButton *)view).currentTitle;
    else if ([view isKindOfClass:[UITextField class]]) { t = ((UITextField *)view).text; node[@"is_input"] = @YES; }
    else if ([view isKindOfClass:[UITextView class]]) { t = ((UITextView *)view).text; node[@"is_input"] = @YES; }
    if (t.length) node[@"text"] = t;
    if ([view isKindOfClass:[UIControl class]]) node[@"is_control"] = @YES;
    if ([view isKindOfClass:[UIScrollView class]]) node[@"is_scroll"] = @YES;
    NSMutableArray *children = [NSMutableArray array];
    if (depth < 12) {
        for (UIView *sub in view.subviews) {
            NSMutableDictionary *cn = agentUITree(sub, depth + 1, counter);
            if (cn.count) [children addObject:cn];
        }
    }
    if (children.count) node[@"children"] = children;
    return node;
}

#pragma mark - 动作实现（返回结果 dict）

static NSDictionary *actionStatus(void) {
    NSBundle *b = [NSBundle mainBundle];
    NSDictionary *info = b.infoDictionary;
    NSString *name = safeStr(info[@"CFBundleDisplayName"]);
    if (!name.length) name = safeStr(info[@"CFBundleName"]);
    return @{
        @"agent": @"TrollMCPAgent",
        @"agent_version": kAgentVersion,
        @"app": name,
        @"bundle_id": safeStr(b.bundleIdentifier),
        @"app_version": safeStr(info[@"CFBundleShortVersionString"]),
        @"windows": @(agentAllWindows().count),
        @"port": @(kAgentPort)
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
    if (!text.length) return @{@"error": @"empty text"};
    UIView *fr = [agentKeyWindow() tma_findFirstResponder];
    if (!fr) return @{@"error": @"no first responder", @"hint": @"tap an input field first"};
    if ([fr isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)fr;
        tf.text = [tf.text stringByAppendingString:text];
        [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        return @{@"typed": @YES, @"target": @"UITextField"};
    }
    if ([fr isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)fr;
        tv.text = [tv.text stringByAppendingString:text];
        return @{@"typed": @YES, @"target": @"UITextView"};
    }
    if ([fr conformsToProtocol:@protocol(UITextInput)]) {
        [(id<UITextInput>)fr insertText:text];
        return @{@"typed": @YES, @"target": @"UITextInput"};
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

static NSDictionary *handleAction(NSDictionary *payload) {
    NSString *action = safeStr(payload[@"action"]);
    NSString *cmdId = safeStr(payload[@"id"]);
    NSDictionary *data = nil;
    BOOL ok = YES;
    if ([action isEqualToString:@"status"]) {
        data = actionStatus();
    } else if ([action isEqualToString:@"get_ui_tree"] || [action isEqualToString:@"ui_tree"]) {
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
    return result;
}

#pragma mark - 通知通道

static void postResult(NSDictionary *result) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kResName object:nil userInfo:result];
    [[NSNotificationCenter defaultCenter] postNotificationName:kResV1Name object:nil userInfo:result];
    NSString *cmdId = safeStr(result[@"id"]);
    if (cmdId.length) {
        NSData *jdata = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (jdata) {
            [[NSUserDefaults standardUserDefaults] setObject:[[NSString alloc] initWithData:jdata encoding:NSUTF8StringEncoding]
                                                      forKey:[NSString stringWithFormat:@"trollmcp_result_%@", cmdId]];
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
            postResult(handleAction(payload));
        } @catch (NSException *e) {
            NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:payload];
            r[@"success"] = @NO;
            r[@"error"] = [NSString stringWithFormat:@"exception: %@", e.reason];
            postResult(r);
        }
    });
}

#pragma mark - HTTP 通道

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

static NSDictionary *parseJSONBody(NSData *body) {
    if (!body || body.length == 0) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    return @{};
}

static NSData *handleHTTPRequest(NSString *method, NSString *path, NSData *body) {
    NSDictionary *params = parseJSONBody(body);
    if ([path isEqualToString:@"/status"] || [path isEqualToString:@"/"]) {
        return jsonResponse(actionStatus());
    }
    if ([path isEqualToString:@"/ui_tree"]) {
        return jsonResponse(actionGetUITree());
    }
    if ([path isEqualToString:@"/tap"]) {
        return jsonResponse(actionTap(params));
    }
    if ([path isEqualToString:@"/swipe"]) {
        return jsonResponse(actionSwipe(params));
    }
    if ([path isEqualToString:@"/type"]) {
        return jsonResponse(actionType(params));
    }
    if ([path isEqualToString:@"/scroll"]) {
        return jsonResponse(actionScroll(params));
    }
    if ([path isEqualToString:@"/command"]) {
        return jsonResponse(handleAction(params));
    }
    return httpResponse(404, @"text/plain", [@"not found" dataUsingEncoding:NSUTF8StringEncoding]);
}

static void handleClientConnection(int clientSocket) {
    @autoreleasepool {
        NSMutableData *requestData = [NSMutableData data];
        char buffer[4096];
        BOOL headersComplete = NO;
        NSInteger contentLength = 0;
        NSData *headerData = nil;

        while (1) {
            ssize_t n = recv(clientSocket, buffer, sizeof(buffer), 0);
            if (n <= 0) break;
            [requestData appendBytes:buffer length:n];
            if (!headersComplete) {
                NSRange range = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, requestData.length)];
                if (range.location != NSNotFound) {
                    headersComplete = YES;
                    headerData = [requestData subdataWithRange:NSMakeRange(0, range.location)];
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
            if (requestData.length > 1024 * 1024) break;
        }

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

        NSData *body = nil;
        NSRange headerEnd = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, requestData.length)];
        if (headerEnd.location != NSNotFound) {
            NSInteger bodyStart = headerEnd.location + 4;
            if (bodyStart < requestData.length) {
                body = [requestData subdataWithRange:NSMakeRange(bodyStart, requestData.length - bodyStart)];
            }
        }

        __block NSData *response = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                response = handleHTTPRequest(method, path, body);
            } @catch (NSException *e) {
                response = jsonResponse(@{@"success": @NO, @"error": [NSString stringWithFormat:@"exception: %@", e.reason]});
            }
        });

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
    if (g_serverSocket < 0) return;
    int opt = 1;
    setsockopt(g_serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(kAgentPort);
    if (bind(g_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }
    if (listen(g_serverSocket, 16) < 0) {
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
}

#pragma mark - 构造

__attribute__((constructor))
static void trollmcp_agent_init(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:kCmdName object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { observeCommandNotification(note); }];
    [nc addObserverForName:kCmdV1Name object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { observeCommandNotification(note); }];
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            startHTTPServer();
        });
    });
}
