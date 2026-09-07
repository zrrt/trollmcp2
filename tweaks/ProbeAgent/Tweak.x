// ProbeAgent v1.0 - 运行时类探测引擎（借鉴 ProbeEngine 设计，独立实现）
// 注入任意 App 后开启 localhost HTTP 服务（端口 4791），TrollAgent 通过 HTTP 探测目标 App 的
// ObjC 运行时结构：类列表 / 类详情（方法·属性·ivars）/ UserDefaults / 进程信息。
// 设计原则：纯 objc/runtime + Foundation，零 substrate 依赖，仅监听 localhost。
//
// API（TrollAgent 通过 127.0.0.1:4791 调用）：
//   GET /status               → 探测代理状态 + App/iOS/进程信息
//   GET /probe/classes?prefix=&limit=&offset=
//                             → 类列表（name/superclass/instanceMethodCount/classMethodCount）
//   GET /probe/class?name=X   → 类详情（实例方法/类方法/属性/ivars/superclass）
//   GET /probe/userdefaults   → NSUserDefaults 全量（过滤敏感长值）
// 设计：HTTP 在后台线程，JSON 用 NSJSONSerialization。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#define kProbePort 4791
#define kMaxClassList 1200

static int g_serverSocket = -1;
static dispatch_source_t g_acceptSource = nil;
static NSMutableSet *g_clientSockets = nil;

#pragma mark - HTTP 响应工具

static NSData *probeHTTPResponse(NSInteger status, NSString *contentType, NSData *body) {
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

static NSData *probeJSON(NSDictionary *dict) {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
    if (!data || err) {
        return [@"{\"error\":\"json serialization failed\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    return data;
}

static NSData *probeText(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - 探测实现

static NSString *probeAppInfo(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    return [NSString stringWithFormat:@"%@ %@",
            info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"?",
            info[@"CFBundleShortVersionString"] ?: @"?"];
}

static NSDictionary *probeStatusDict(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    return @{
        @"app": probeAppInfo(),
        @"bundleId": info[@"CFBundleIdentifier"] ?: @"?",
        @"version": info[@"CFBundleShortVersionString"] ?: @"?",
        @"build": info[@"CFBundleVersion"] ?: @"?",
        @"pid": @([NSProcessInfo processInfo].processIdentifier),
        @"ios": pi.operatingSystemVersionString ?: @"?",
        @"probePort": @(kProbePort),
        @"status": @"ok",
    };
}

// 类列表：prefix 过滤 + limit/offset 分页
static NSDictionary *probeClasses(NSString *prefix, NSInteger limit, NSInteger offset) {
    int total = objc_getClassList(NULL, 0);
    if (total > kMaxClassList) total = kMaxClassList;
    Class *buffer = (Class *)malloc(sizeof(Class) * total);
    objc_getClassList(buffer, total);

    NSMutableArray *classes = [NSMutableArray array];
    for (int i = 0; i < total; i++) {
        Class cls = buffer[i];
        const char *name = class_getName(cls);
        if (!name) continue;
        NSString *nsName = [NSString stringWithUTF8String:name];
        if (prefix.length > 0 && ![nsName hasPrefix:prefix]) continue;
        // 跳过系统私密前缀，减少噪音
        if ([nsName hasPrefix:@"_"] || [nsName hasPrefix:@"NSKVONotifying_"]) continue;

        unsigned int instCount = 0, clsCount = 0;
        Method *insts = class_copyMethodList(cls, &instCount);
        Method *clss = class_copyMethodList(object_getClass(cls), &clsCount);
        free(insts); free(clss);

        Class sup = class_getSuperclass(cls);
        NSString *superName = sup ? [NSString stringWithUTF8String:class_getName(sup)] : @"NSObject";

        [classes addObject:@{
            @"name": nsName,
            @"superclass": superName,
            @"instanceMethods": @(instCount),
            @"classMethods": @(clsCount),
        }];
        if (classes.count >= limit) break;
    }
    free(buffer);

    // offset 分页（先收集全部匹配再做截断，prefix 场景结果量小）
    if (offset > 0 && offset < classes.count) {
        [classes removeObjectsInRange:NSMakeRange(0, offset)];
    }
    if (classes.count > limit) {
        [classes removeObjectsInRange:NSMakeRange(limit, classes.count - limit)];
    }

    return @{
        @"total": @(classes.count),
        @"classes": classes,
    };
}

// 类详情：方法/属性/ivars/superclass
static NSDictionary *probeClassDetail(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) {
        // 尝试 objc_getClass
        cls = objc_getClass(name.UTF8String);
    }
    if (!cls) return @{ @"error": [NSString stringWithFormat:@"class not found: %@", name] };

    NSMutableArray *instMethods = [NSMutableArray array];
    unsigned int instCount = 0;
    Method *insts = class_copyMethodList(cls, &instCount);
    for (unsigned int i = 0; i < instCount; i++) {
        Method m = insts[i];
        SEL sel = method_getName(m);
        const char *types = method_getTypeEncoding(m);
        [instMethods addObject:@{
            @"selector": sel ? [NSString stringWithUTF8String:sel_getName(sel)] : @"?",
            @"types": types ? [NSString stringWithUTF8String:types] : @"?",
        }];
    }
    free(insts);

    NSMutableArray *classMethods = [NSMutableArray array];
    unsigned int clsCount = 0;
    Method *clss = class_copyMethodList(object_getClass(cls), &clsCount);
    for (unsigned int i = 0; i < clsCount; i++) {
        Method m = clss[i];
        SEL sel = method_getName(m);
        [classMethods addObject:sel ? [NSString stringWithUTF8String:sel_getName(sel)] : @"?"];
    }
    free(clss);

    NSMutableArray *properties = [NSMutableArray array];
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        objc_property_t p = props[i];
        const char *pName = property_getName(p);
        const char *attrs = property_getAttributes(p);
        [properties addObject:@{
            @"name": pName ? [NSString stringWithUTF8String:pName] : @"?",
            @"attributes": attrs ? [NSString stringWithUTF8String:attrs] : @"?",
        }];
    }
    free(props);

    NSMutableArray *ivars = [NSMutableArray array];
    unsigned int ivarCount = 0;
    Ivar *ivarsList = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        Ivar iv = ivarsList[i];
        const char *ivName = ivar_getName(iv);
        const char *ivType = ivar_getTypeEncoding(iv);
        [ivars addObject:@{
            @"name": ivName ? [NSString stringWithUTF8String:ivName] : @"?",
            @"type": ivType ? [NSString stringWithUTF8String:ivType] : @"?",
        }];
    }
    free(ivarsList);

    Class sup = class_getSuperclass(cls);
    return @{
        @"name": name,
        @"superclass": sup ? [NSString stringWithUTF8String:class_getName(sup)] : @"(root)",
        @"instanceMethods": instMethods,
        @"classMethods": classMethods,
        @"properties": properties,
        @"ivars": ivars,
    };
}

// UserDefaults 全量（值过大或非字符串/数字的截断描述）
static NSDictionary *probeUserDefaults(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *dict = [ud dictionaryRepresentation];
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    NSArray *keys = [dict.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in keys) {
        id value = dict[key];
        if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
            NSString *s = [value description];
            if (s.length > 500) s = [s substringToIndex:500];
            safe[key] = s;
        } else if ([value isKindOfClass:[NSData class]]) {
            safe[key] = [NSString stringWithFormat:@"<data %lu bytes>", (unsigned long)[value length]];
        } else if ([value isKindOfClass:[NSArray class]]) {
            safe[key] = [NSString stringWithFormat:@"<array %lu items>", (unsigned long)[(NSArray *)value count]];
        } else if ([value isKindOfClass:[NSDictionary class]]) {
            safe[key] = [NSString stringWithFormat:@"<dict %lu keys>", (unsigned long)[(NSDictionary *)value count]];
        } else {
            safe[key] = [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
        }
    }
    return @{ @"count": @(safe.count), @"userDefaults": safe };
}

#pragma mark - HTTP 请求处理

static NSData *probeHandleRequest(NSString *method, NSString *pathQuery) {
    NSArray *parts = [pathQuery componentsSeparatedByString:@"?"];
    NSString *path = parts.count > 0 ? parts[0] : pathQuery;
    NSDictionary *query = @{};
    if (parts.count > 1) {
        NSMutableDictionary *q = [NSMutableDictionary dictionary];
        for (NSString *pair in [parts[1] componentsSeparatedByString:@"&"]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count == 2) {
                q[[kv[0] stringByRemovingPercentEncoding]] = [kv[1] stringByRemovingPercentEncoding];
            }
        }
        query = q;
    }

    if ([path isEqualToString:@"/status"]) {
        return probeJSON(probeStatusDict());
    }
    if ([path isEqualToString:@"/probe/classes"]) {
        NSString *prefix = query[@"prefix"] ?: @"";
        NSInteger limit = query[@"limit"] ? [query[@"limit"] integerValue] : 50;
        NSInteger offset = query[@"offset"] ? [query[@"offset"] integerValue] : 0;
        if (limit <= 0) limit = 50;
        if (limit > 200) limit = 200;
        return probeJSON(probeClasses(prefix, limit, offset));
    }
    if ([path isEqualToString:@"/probe/class"]) {
        NSString *name = query[@"name"] ?: @"";
        return probeJSON(probeClassDetail(name));
    }
    if ([path isEqualToString:@"/probe/userdefaults"]) {
        return probeJSON(probeUserDefaults());
    }
    return probeHTTPResponse(404, @"text/plain; charset=utf-8",
                             probeText([NSString stringWithFormat:@"not found: %@", path]));
}

#pragma mark - HTTP 服务器

static void probeHandleClient(int clientSocket) {
    char buffer[8192];
    ssize_t n = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
    if (n <= 0) { close(clientSocket); return; }
    buffer[n] = '\0';
    NSString *raw = [NSString stringWithUTF8String:buffer];
    NSArray *lines = [raw componentsSeparatedByString:@"\r\n"];
    NSString *requestLine = lines.count > 0 ? lines[0] : @"";
    NSArray *rl = [requestLine componentsSeparatedByString:@" "];
    NSString *method = rl.count > 0 ? rl[0] : @"GET";
    NSString *pathQuery = rl.count > 1 ? rl[1] : @"/";

    NSData *response = probeHandleRequest(method, pathQuery);
    const char *bytes = response.bytes;
    NSUInteger total = response.length;
    NSUInteger sent = 0;
    while (sent < total) {
        ssize_t w = send(clientSocket, bytes + sent, total - sent, 0);
        if (w <= 0) break;
        sent += w;
    }
    close(clientSocket);
}

static void probeStartServer(void) {
    if (g_serverSocket >= 0) return;

    g_serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (g_serverSocket < 0) return;

    int opt = 1;
    setsockopt(g_serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kProbePort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(g_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }
    if (listen(g_serverSocket, 8) < 0) {
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }

    g_acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, g_serverSocket, 0,
                                            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    if (g_acceptSource) {
        dispatch_source_set_cancel_handler(g_acceptSource, ^{
            close(g_serverSocket);
            g_serverSocket = -1;
        });
        dispatch_source_set_event_handler(g_acceptSource, ^{
            struct sockaddr_in clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            int client = accept(g_serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
            if (client >= 0) {
                probeHandleClient(client);
            }
        });
        dispatch_resume(g_acceptSource);
    }
    NSLog(@"[ProbeAgent] HTTP server started on 127.0.0.1:%d", kProbePort);
}

__attribute__((constructor))
static void probeInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            probeStartServer();
        });
    });
}
