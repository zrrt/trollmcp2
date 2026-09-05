// MemoryTweak - H5gg 式内存修改 dylib
// 注入到目标 App 后启动本地 HTTP 服务器 (127.0.0.1:8765)
// AI 通过 HTTP 调用：搜索内存、写入数值、冻结地址
// 接口：
//   POST /search    {"value":100,"type":"int"}       → 全内存搜索
//   POST /refine    {"value":200,"type":"int"}       → 在上次结果中过滤
//   POST /write     {"address":"0x...","value":999,"type":"int"}  → 写入
//   POST /freeze    {"address":"0x...","value":999,"type":"int"}  → 冻结
//   POST /unfreeze  {"address":"0x..."}              → 取消冻结
//   GET  /frozen                                    → 已冻结列表
//   GET  /results                                   → 上次搜索结果
//   GET  /status                                    → 服务器状态
// type 支持: int(32位), int64, float, double, byte, short

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

#define MT_PORT 8765
#define MT_MAX_RESULTS 5000
#define MT_FREEZE_INTERVAL 0.05  // 50ms

// ========== 全局状态 ==========
static NSMutableArray<NSDictionary*> *mt_results = nil;  // 上次搜索结果
static NSMutableDictionary<NSString*, NSDictionary*> *mt_frozen = nil;  // 冻结列表 address->{value,type}
static pthread_mutex_t mt_mutex = PTHREAD_MUTEX_INITIALIZER;
static int mt_server_fd = -1;

// ========== 工具函数 ==========

// 简单 JSON 字符串提取（避免依赖 JSON 库）
static NSString* mt_json_string(NSString *json, NSString *key) {
    NSString *pattern = [NSString stringWithFormat:@"\"%@\"\\s*:\\s*\"([^\"]*)\"", key];
    NSRange r = [json rangeOfString:pattern options:NSRegularExpressionSearch];
    if (r.location == NSNotFound) return nil;
    NSString *sub = [json substringWithRange:r];
    NSRange q1 = [sub rangeOfString:@"\"" options:0 range:NSMakeRange(1, sub.length-1)];
    if (q1.location == NSNotFound) return nil;
    NSString *rest = [sub substringFromIndex:q1.location+1];
    NSRange q2 = [rest rangeOfString:@"\""];
    if (q2.location == NSNotFound) return nil;
    return [rest substringToIndex:q2.location];
}

static NSNumber* mt_json_number(NSString *json, NSString *key) {
    NSString *pattern = [NSString stringWithFormat:@"\"%@\"\\s*:\\s*(-?\\d+\\.?\\d*)", key];
    NSRange r = [json rangeOfString:pattern options:NSRegularExpressionSearch];
    if (r.location == NSNotFound) return nil;
    NSString *sub = [json substringWithRange:r];
    NSRange colon = [sub rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    NSString *numStr = [[sub substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return @([numStr doubleValue]);
}

static unsigned long long mt_parse_address(NSString *s) {
    if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
        return strtoull([s UTF8String], NULL, 16);
    }
    return strtoull([s UTF8String], NULL, 10);
}

// ========== 内存搜索 ==========

typedef enum { MT_INT, MT_INT64, MT_FLOAT, MT_DOUBLE, MT_BYTE, MT_SHORT } mt_type_t;

static mt_type_t mt_parse_type(NSString *t) {
    if ([t isEqualToString:@"int64"] || [t isEqualToString:@"long"]) return MT_INT64;
    if ([t isEqualToString:@"float"]) return MT_FLOAT;
    if ([t isEqualToString:@"double"]) return MT_DOUBLE;
    if ([t isEqualToString:@"byte"] || [t isEqualToString:@"int8"]) return MT_BYTE;
    if ([t isEqualToString:@"short"] || [t isEqualToString:@"int16"]) return MT_SHORT;
    return MT_INT;
}

static int mt_type_size(mt_type_t t) {
    switch (t) {
        case MT_INT64: return 8;
        case MT_DOUBLE: return 8;
        case MT_FLOAT: return 4;
        case MT_INT: return 4;
        case MT_SHORT: return 2;
        case MT_BYTE: return 1;
    }
    return 4;
}

static BOOL mt_value_match(const void *buf, mt_type_t type, double target) {
    switch (type) {
        case MT_INT: return (*(int32_t*)buf == (int32_t)target);
        case MT_INT64: return (*(int64_t*)buf == (int64_t)target);
        case MT_FLOAT: return (*(float*)buf == (float)target);
        case MT_DOUBLE: return (*(double*)buf == target);
        case MT_SHORT: return (*(int16_t*)buf == (int16_t)target);
        case MT_BYTE: return (*(uint8_t*)buf == (uint8_t)target);
    }
    return NO;
}

// 全内存搜索
static NSArray<NSDictionary*>* mt_search_memory(double target, mt_type_t type) {
    NSMutableArray *results = [NSMutableArray array];
    vm_address_t addr = 0;
    vm_size_t size = 0;
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    natural_t depth = 0;
    int sz = mt_type_size(type);

    while (1) {
        count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_info_t)&info, &count);
        if (kr != KERN_SUCCESS) break;

        // 只搜索可读可写的私有区域（跳过系统共享库、__TEXT 等）
        if (info.protection & VM_PROT_READ && info.protection & VM_PROT_WRITE &&
            !(info.protection & VM_PROT_COPY) && size < 0x10000000) {  // 跳过大于256MB的区域
            void *buf = malloc(size);
            mach_msg_type_number_t dataCnt = 0;
            kr = vm_read_overwrite(mach_task_self(), addr, (vm_size_t)size, (vm_offset_t)buf, &dataCnt);
            if (kr == KERN_SUCCESS && dataCnt > 0) {
                for (vm_offset_t i = 0; i + sz <= dataCnt; i += sz) {
                    if (mt_value_match((char*)buf + i, type, target)) {
                        [results addObject:@{
                            @"address": [NSString stringWithFormat:@"0x%lx", (unsigned long)(addr + i)],
                            @"value": @(target)
                        }];
                        if (results.count >= MT_MAX_RESULTS) break;
                    }
                }
                free(buf);
            }
        }
        addr += size;
        if (results.count >= MT_MAX_RESULTS) break;
    }
    return results;
}

// 在已有结果中过滤
static NSArray<NSDictionary*>* mt_refine_results(NSArray *prev, double target, mt_type_t type) {
    NSMutableArray *filtered = [NSMutableArray array];
    int sz = mt_type_size(type);
    for (NSDictionary *r in prev) {
        unsigned long long addr = mt_parse_address(r[@"address"]);
        void *buf = malloc(sz);
        if (buf && vm_read_overwrite(mach_task_self(), addr, sz, (vm_offset_t)buf, NULL) == KERN_SUCCESS) {
            if (mt_value_match(buf, type, target)) {
                [filtered addObject:@{@"address": r[@"address"], @"value": @(target)}];
            }
        }
        free(buf);
        if (filtered.count >= MT_MAX_RESULTS) break;
    }
    return filtered;
}

// ========== 内存写入 ==========

static BOOL mt_write_memory(unsigned long long addr, double value, mt_type_t type) {
    int sz = mt_type_size(type);
    void *buf = malloc(sz);
    if (!buf) return NO;
    switch (type) {
        case MT_INT: *(int32_t*)buf = (int32_t)value; break;
        case MT_INT64: *(int64_t*)buf = (int64_t)value; break;
        case MT_FLOAT: *(float*)buf = (float)value; break;
        case MT_DOUBLE: *(double*)buf = value; break;
        case MT_SHORT: *(int16_t*)buf = (int16_t)value; break;
        case MT_BYTE: *(uint8_t*)buf = (uint8_t)value; break;
    }
    kern_return_t kr = vm_write(mach_task_self(), addr, (vm_offset_t)buf, sz);
    free(buf);
    return kr == KERN_SUCCESS;
}

// ========== 冻结线程 ==========

static void* mt_freeze_thread(void *arg) {
    while (1) {
        pthread_mutex_lock(&mt_mutex);
        NSArray *keys = [mt_frozen allKeys];
        for (NSString *key in keys) {
            NSDictionary *f = mt_frozen[key];
            unsigned long long addr = mt_parse_address(key);
            double val = [f[@"value"] doubleValue];
            mt_type_t type = mt_parse_type(f[@"type"]);
            mt_write_memory(addr, val, type);
        }
        pthread_mutex_unlock(&mt_mutex);
        usleep(50000);
    }
    return NULL;
}

// ========== HTTP 响应 ==========

static void mt_send_response(int fd, int status, NSString *body) {
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        status, (unsigned long)body.length];
    send(fd, [header UTF8String], header.length, 0);
    send(fd, [body UTF8String], body.length, 0);
    close(fd);
}

static NSString* mt_json_escape(NSString *s) {
    return [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

// ========== 请求处理 ==========

static void mt_handle_request(int fd, NSString *method, NSString *path, NSString *body) {
    pthread_mutex_lock(&mt_mutex);

    if ([path isEqualToString:@"/status"]) {
        NSDictionary *resp = @{
            @"status": @"running",
            @"pid": @(getpid()),
            @"results_count": @(mt_results.count),
            @"frozen_count": @(mt_frozen.count),
            @"port": @(MT_PORT)
        };
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        mt_send_response(fd, 200, [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        pthread_mutex_unlock(&mt_mutex);
        return;
    }

    if ([path isEqualToString:@"/results"]) {
        NSDictionary *resp = @{@"count": @(mt_results.count), @"results": mt_results};
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        mt_send_response(fd, 200, [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        pthread_mutex_unlock(&mt_mutex);
        return;
    }

    if ([path isEqualToString:@"/frozen"]) {
        NSMutableArray *arr = [NSMutableArray array];
        for (NSString *addr in mt_frozen) {
            NSDictionary *f = mt_frozen[addr];
            [arr addObject:@{@"address": addr, @"value": f[@"value"], @"type": f[@"type"]}];
        }
        NSDictionary *resp = @{@"count": @(arr.count), @"frozen": arr};
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        mt_send_response(fd, 200, [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        pthread_mutex_unlock(&mt_mutex);
        return;
    }

    if ([path isEqualToString:@"/search"] && [method isEqualToString:@"POST"]) {
        NSNumber *val = mt_json_number(body, @"value");
        NSString *typeStr = mt_json_string(body, @"type") ?: @"int";
        if (!val) {
            mt_send_response(fd, 400, @"{\"error\":\"missing value\"}");
            pthread_mutex_unlock(&mt_mutex);
            return;
        }
        mt_type_t type = mt_parse_type(typeStr);
        NSArray *results = mt_search_memory([val doubleValue], type);
        mt_results = [results mutableCopy];
        NSDictionary *resp = @{@"count": @(results.count), @"results": results, @"truncated": @(results.count >= MT_MAX_RESULTS)};
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        mt_send_response(fd, 200, [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        pthread_mutex_unlock(&mt_mutex);
        return;
    }

    if ([path isEqualToString:@"/refine"] && [method isEqualToString:@"POST"]) {
        NSNumber *val = mt_json_number(body, @"value");
        NSString *typeStr = mt_json_string(body, @"type") ?: @"int";
        if (!val || mt_results.count == 0) {
            mt_send_response(fd, 400, @"{\"error\":\"missing value or no previous results\"}");
            pthread_mutex_unlock(&mt_mutex);
            return;
        }
        mt_type_t type = mt_parse_type(typeStr);
        NSArray *filtered = mt_refine_results(mt_results, [val doubleValue], type);
        mt_results = [filtered mutableCopy];
        NSDictionary *resp = @{@"count": @(filtered.count), @"results": filtered};
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        mt_send_response(fd, 200, [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        pthread_mutex_unlock(&mt_mutex);
        return;
    }

    if ([path isEqualToString:@"/write"] && [method isEqualToString:@"POST"]) {
        NSString *addrStr = mt_json_string(body, @"address");
        NSNumber *val = mt_json_number(body, @"value");
        NSString *typeStr = mt_json_string(body, @"type") ?: @"int";
        if (!addrStr || !val) {
            mt_send_response(fd, 400, @"{\"error\":\"missing address or value\"}");
            pthread_mutex_unlock(&mt_mutex);
            return;
        }
        unsigned long long addr = mt_parse_address(addrStr);
        mt_type_t type = mt_parse_type(typeStr);
        BOOL ok = mt_write_memory(addr, [val doubleValue], type);
        NSDictionary *resp = @{@"success": @(ok), @"address": addrStr, @"value": val};
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        mt_send_response(fd, ok ? 200 : 500, [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        pthread_mutex_unlock(&mt_mutex);
        return;
    }

    if ([path isEqualToString:@"/freeze"] && [method isEqualToString:@"POST"]) {
        NSString *addrStr = mt_json_string(body, @"address");
        NSNumber *val = mt_json_number(body, @"value");
        NSString *typeStr = mt_json_string(body, @"type") ?: @"int";
        if (!addrStr || !val) {
            mt_send_response(fd, 400, @"{\"error\":\"missing address or value\"}");
            pthread_mutex_unlock(&mt_mutex);
            return;
        }
        mt_frozen[addrStr] = @{@"value": val, @"type": typeStr};
        NSDictionary *resp = @{@"success": @YES, @"address": addrStr, @"frozen_count": @(mt_frozen.count)};
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        mt_send_response(fd, 200, [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        pthread_mutex_unlock(&mt_mutex);
        return;
    }

    if ([path isEqualToString:@"/unfreeze"] && [method isEqualToString:@"POST"]) {
        NSString *addrStr = mt_json_string(body, @"address");
        if (!addrStr) {
            mt_send_response(fd, 400, @"{\"error\":\"missing address\"}");
            pthread_mutex_unlock(&mt_mutex);
            return;
        }
        [mt_frozen removeObjectForKey:addrStr];
        NSDictionary *resp = @{@"success": @YES, @"address": addrStr, @"frozen_count": @(mt_frozen.count)};
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
        mt_send_response(fd, 200, [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        pthread_mutex_unlock(&mt_mutex);
        return;
    }

    mt_send_response(fd, 404, @"{\"error\":\"not found\"}");
    pthread_mutex_unlock(&mt_mutex);
}

// ========== HTTP 服务器线程 ==========

static void* mt_server_thread(void *arg) {
    mt_server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (mt_server_fd < 0) {
        NSLog(@"[MemoryTweak] socket failed");
        return NULL;
    }
    int opt = 1;
    setsockopt(mt_server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons(MT_PORT);

    if (bind(mt_server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        NSLog(@"[MemoryTweak] bind failed: %s", strerror(errno));
        close(mt_server_fd);
        mt_server_fd = -1;
        return NULL;
    }
    listen(mt_server_fd, 5);
    NSLog(@"[MemoryTweak] HTTP server listening on 127.0.0.1:%d", MT_PORT);

    while (1) {
        int client_fd = accept(mt_server_fd, NULL, NULL);
        if (client_fd < 0) continue;

        char buf[65536];
        ssize_t n = recv(client_fd, buf, sizeof(buf)-1, 0);
        if (n <= 0) { close(client_fd); continue; }
        buf[n] = 0;

        NSString *request = [NSString stringWithUTF8String:buf];
        NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) { close(client_fd); continue; }

        NSString *firstLine = lines[0];
        NSArray *parts = [firstLine componentsSeparatedByString:@" "];
        if (parts.count < 2) { close(client_fd); continue; }

        NSString *method = parts[0];
        NSString *path = parts[1];

        // 提取 body
        NSString *body = @"";
        NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
        if (bodyRange.location != NSNotFound) {
            body = [request substringFromIndex:bodyRange.location + 4];
        }

        @try {
            mt_handle_request(client_fd, method, path, body);
        } @catch (NSException *e) {
            mt_send_response(client_fd, 500, [NSString stringWithFormat:@"{\"error\":\"%@\"}", mt_json_escape(e.reason)]);
        }
    }
    return NULL;
}

// ========== 入口 ==========

__attribute__((constructor))
static void mt_initialize() {
    @autoreleasepool {
        mt_results = [NSMutableArray array];
        mt_frozen = [NSMutableDictionary dictionary];

        pthread_t server_tid;
        pthread_create(&server_tid, NULL, mt_server_thread, NULL);
        pthread_detach(server_tid);

        pthread_t freeze_tid;
        pthread_create(&freeze_tid, NULL, mt_freeze_thread, NULL);
        pthread_detach(freeze_tid);

        NSLog(@"[MemoryTweak] loaded, pid=%d, server starting on port %d", getpid(), MT_PORT);
    }
}
