#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// NetworkTweak v1.0 — HTTP/HTTPS 抓包 dylib
// 注入目标 App 后，所有 NSURLSession 请求记录到 /var/mobile/Documents/Workspace/network_capture/
// 支持请求/响应记录、状态码、耗时、Header、Body 大小

@interface NSURLSession (NetworkTweak)
@end

static NSString *kCaptureDir = @"/var/mobile/Documents/Workspace/network_capture";
static NSMutableArray *g_requests = nil;
static NSInteger g_maxRecords = 500;

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
        // 每 10 条写一次盘
        if (g_requests.count % 10 == 0) {
            NSString *path = [kCaptureDir stringByAppendingPathComponent:@"capture_latest.json"];
            NSData *data = [NSJSONSerialization dataWithJSONObject:g_requests options:NSJSONWritingPrettyPrinted error:nil];
            [data writeToFile:path atomically:YES];
        }
    }
}

// hook NSURLSession dataTaskWithRequest:completionHandler:
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    ensureCaptureDir();

    NSDate *startTime = [NSDate date];
    NSString *requestId = [[NSUUID UUID] UUIDString];

    // 记录请求
    NSMutableDictionary *reqRecord = [NSMutableDictionary dictionary];
    reqRecord[@"id"] = requestId;
    reqRecord[@"timestamp"] = timestamp();
    reqRecord[@"method"] = request.HTTPMethod ?: @"GET";
    reqRecord[@"url"] = request.URL.absoluteString ?: @"";
    reqRecord[@"request_headers"] = request.allHTTPHeaderFields ?: @{};
    reqRecord[@"request_body_size"] = @(request.HTTPBody.length);
    if (request.URL.host) reqRecord[@"host"] = request.URL.host;
    if (request.URL.scheme) reqRecord[@"scheme"] = request.URL.scheme;

    // 包装 completionHandler
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
            // 尝试解析 JSON
            if (data.length > 0 && data.length < 65536) {
                @try {
                    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (json) {
                        reqRecord[@"response_json_preview"] = json;
                    }
                } @catch (id e) {}
            }
        }

        saveRecord(reqRecord);

        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };

    return %orig(request, wrappedHandler);
}

// hook dataTaskWithRequest: (无 completionHandler 的版本)
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    ensureCaptureDir();
    NSMutableDictionary *reqRecord = [NSMutableDictionary dictionary];
    reqRecord[@"id"] = [[NSUUID UUID] UUIDString];
    reqRecord[@"timestamp"] = timestamp();
    reqRecord[@"method"] = request.HTTPMethod ?: @"GET";
    reqRecord[@"url"] = request.URL.absoluteString ?: @"";
    reqRecord[@"host"] = request.URL.host ?: @"";
    reqRecord[@"note"] = @"no_completion_handler";
    saveRecord(reqRecord);
    return %orig(request);
}

%end

// hook NSURLConnection（旧 API）
%hook NSURLConnection

+ (NSURLConnection *)connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    ensureCaptureDir();
    NSMutableDictionary *reqRecord = [NSMutableDictionary dictionary];
    reqRecord[@"id"] = [[NSUUID UUID] UUIDString];
    reqRecord[@"timestamp"] = timestamp();
    reqRecord[@"method"] = request.HTTPMethod ?: @"GET";
    reqRecord[@"url"] = request.URL.absoluteString ?: @"";
    reqRecord[@"api"] = @"NSURLConnection";
    saveRecord(reqRecord);
    return %orig(request, delegate);
}

%end

// 构造函数：启动时写一个标记文件
__attribute__((constructor))
static void initialize() {
    ensureCaptureDir();
    NSString *marker = [kCaptureDir stringByAppendingPathComponent:@"NetworkTweak_loaded.txt"];
    NSString *info = [NSString stringWithFormat:@"NetworkTweak loaded at %@\nPID: %d\n", timestamp(), getpid()];
    [info writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
