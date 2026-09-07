#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// NetworkTweak v1.1 — HTTP/HTTPS 抓包 dylib（零依赖版）
// v1.0 用 Logos %hook → 链接 CydiaSubstrate → TrollStore 无 substrate → 注入必闪退。
// v1.1 改为 method swizzling（method_setImplementation），纯 ObjC runtime，零外部依赖，
// 注入任何 App 都不会因缺依赖闪退。功能不变：记录到 /var/mobile/Documents/Workspace/network_capture/。

static NSString *kCaptureDir = @"/var/mobile/Documents/Workspace/network_capture";
static NSMutableArray *g_requests = nil;
static NSInteger g_maxRecords = 500;

// 原实现保存
static IMP g_orig_dataTaskWithCompletion = NULL;
static IMP g_orig_dataTaskWithoutCompletion = NULL;
static IMP g_orig_connectionWithRequest = NULL;

static void ensureCaptureDir() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:kCaptureDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        g_requests = [NSMutableArray array];
    });
}

static NSString *timestamp() {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    return [fmt stringFromDate:[NSDate date]];
}

static void saveRecord(NSDictionary *record) {
    @synchronized (g_requests) {
        [g_requests addObject:record];
        if (g_requests.count > g_maxRecords) {
            [g_requests removeObjectsInRange:NSMakeRange(0, g_requests.count - g_maxRecords)];
        }
        if (g_requests.count % 10 == 0) {
            NSString *path = [kCaptureDir stringByAppendingPathComponent:@"capture_latest.json"];
            NSData *data = [NSJSONSerialization dataWithJSONObject:g_requests options:NSJSONWritingPrettyPrinted error:nil];
            [data writeToFile:path atomically:YES];
        }
    }
}

static NSDictionary *buildRequestRecord(NSURLRequest *request, NSString *api) {
    NSMutableDictionary *reqRecord = [NSMutableDictionary dictionary];
    reqRecord[@"id"] = [[NSUUID UUID] UUIDString];
    reqRecord[@"timestamp"] = timestamp();
    reqRecord[@"method"] = request.HTTPMethod ?: @"GET";
    reqRecord[@"url"] = request.URL.absoluteString ?: @"";
    reqRecord[@"request_headers"] = request.allHTTPHeaderFields ?: @{};
    reqRecord[@"request_body_size"] = @(request.HTTPBody.length);
    if (request.URL.host) reqRecord[@"host"] = request.URL.host;
    if (request.URL.scheme) reqRecord[@"scheme"] = request.URL.scheme;
    if (api) reqRecord[@"api"] = api;
    return reqRecord;
}

// hook: -dataTaskWithRequest:completionHandler:
static NSURLSessionDataTask *hook_dataTaskWithCompletion(id self, SEL _cmd, NSURLRequest *request, id completionHandler) {
    ensureCaptureDir();
    NSDate *startTime = [NSDate date];
    NSMutableDictionary *reqRecord = buildRequestRecord(request, @"NSURLSession");

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startTime] * 1000;
        reqRecord[@"elapsed_ms"] = @((NSInteger)elapsed);
        if (error) {
            reqRecord[@"error"] = error.localizedDescription ?: @"unknown";
            reqRecord[@"status"] = @(-1);
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            reqRecord[@"status"] = @(httpResp.statusCode);
            reqRecord[@"response_headers"] = httpResp.allHeaderFields ?: @{};
            reqRecord[@"response_body_size"] = @(data.length);
            if (data.length > 0 && data.length < 65536) {
                @try {
                    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (json) reqRecord[@"response_json_preview"] = json;
                } @catch (id e) {}
            }
        }
        saveRecord(reqRecord);
        if (completionHandler) {
            void (^origHandler)(NSData *, NSURLResponse *, NSError *) = completionHandler;
            origHandler(data, response, error);
        }
    };

    if (g_orig_dataTaskWithCompletion) {
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))g_orig_dataTaskWithCompletion)(self, _cmd, request, wrappedHandler);
    }
    return [NSURLSession dataTaskWithRequest:request completionHandler:wrappedHandler];
}

// hook: -dataTaskWithRequest:（无 completionHandler）
static NSURLSessionDataTask *hook_dataTaskWithoutCompletion(id self, SEL _cmd, NSURLRequest *request) {
    ensureCaptureDir();
    NSMutableDictionary *reqRecord = buildRequestRecord(request, @"NSURLSession");
    reqRecord[@"note"] = @"no_completion_handler";
    saveRecord(reqRecord);
    if (g_orig_dataTaskWithoutCompletion) {
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))g_orig_dataTaskWithoutCompletion)(self, _cmd, request);
    }
    return nil;
}

// hook: +connectionWithRequest:delegate:（旧 API）
static NSURLConnection *hook_connectionWithRequest(id self, SEL _cmd, NSURLRequest *request, id delegate) {
    ensureCaptureDir();
    NSMutableDictionary *reqRecord = buildRequestRecord(request, @"NSURLConnection");
    saveRecord(reqRecord);
    if (g_orig_connectionWithRequest) {
        return ((NSURLConnection *(*)(id, SEL, NSURLRequest *, id))g_orig_connectionWithRequest)(self, _cmd, request, delegate);
    }
    return nil;
}

static void swizzle(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        // 类方法
        m = class_getClassMethod(cls, sel);
        if (!m) return;
        *origOut = method_getImplementation(m);
        method_setImplementation(m, newImp);
        return;
    }
    *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

__attribute__((constructor))
static void networkTweakInit(void) {
    ensureCaptureDir();
    // 纯 runtime swizzle，不依赖任何第三方库
    Class sessionCls = NSClassFromString(@"NSURLSession");
    if (sessionCls) {
        swizzle(sessionCls, @selector(dataTaskWithRequest:completionHandler:),
                (IMP)hook_dataTaskWithCompletion, &g_orig_dataTaskWithCompletion);
        swizzle(sessionCls, @selector(dataTaskWithRequest:),
                (IMP)hook_dataTaskWithoutCompletion, &g_orig_dataTaskWithoutCompletion);
    }
    Class connCls = NSClassFromString(@"NSURLConnection");
    if (connCls) {
        Method m = class_getClassMethod(connCls, @selector(connectionWithRequest:delegate:));
        if (m) {
            g_orig_connectionWithRequest = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_connectionWithRequest);
        }
    }

    NSString *marker = [kCaptureDir stringByAppendingPathComponent:@"NetworkTweak_loaded.txt"];
    NSString *info = [NSString stringWithFormat:@"NetworkTweak v1.1 loaded at %@\nPID: %d\n", timestamp(), getpid()];
    [info writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
