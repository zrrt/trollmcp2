// TLSHook v0.1 — TLS 明文探针（抓自研网络栈 App 的加密流量）
// 原理：fishhook 重绑 BoringSSL 的 SSL_read / SSL_write，把解密后的明文
// 按连接(SSL* 指针)落盘到 /var/mobile/Documents/Workspace/network_capture/tls/
// 用途：NetworkTweak 只 hook NSURLSession，抓不到自研栈（小红书/抖音等）。
//       本探针在 TLS 层拿明文，先验证"能不能拿到数据"，再迭代做 HTTP 解析。

#import <Foundation/Foundation.h>
#import <time.h>
#import "fishhook.h"

static NSString *kTlsDir = @"/var/mobile/Documents/Workspace/network_capture/tls";
static dispatch_queue_t g_tlsQueue = NULL;
static NSMutableDictionary *g_connFiles = nil;   // @(sslPtr) -> NSFileHandle
static NSMutableDictionary *g_connSizes = nil;   // @(sslPtr) -> NSNumber(bytes)
static const NSInteger kMaxPerConn = 4 * 1024 * 1024;  // 每连接最多记 4MB 明文
static const NSInteger kMaxConns = 24;                 // 最多跟踪 24 个并发连接

// 原实现
static int (*orig_ssl_read)(void *ssl, void *buf, int num);
static int (*orig_ssl_write)(void *ssl, const void *buf, int num);

static void appendData(NSMutableString *s, const void *buf, int len) {
    const unsigned char *p = (const unsigned char *)buf;
    int hexN = len > 256 ? 256 : len;
    for (int i = 0; i < hexN; i++) {
        [s appendFormat:@"%02x ", p[i]];
        if (i % 16 == 15) [s appendString:@"\n"];
    }
    if (len > 256) [s appendFormat:@"\n...(%d more bytes)\n", len - 256];

    [s appendString:@"TEXT: "];
    int txtN = len > 2048 ? 2048 : len;
    for (int i = 0; i < txtN; i++) {
        unsigned char c = p[i];
        if (c >= 32 && c < 127) {
            [s appendFormat:@"%c", c];
        } else if (c == '\n') {
            [s appendString:@"\\n"];
        } else if (c == '\r') {
            [s appendString:@"\\r"];
        } else {
            [s appendString:@"."];
        }
    }
    [s appendString:@"\n"];
}

static void logTLS(void *ssl, BOOL isRead, const void *buf, int len) {
    if (len <= 0 || buf == NULL || ssl == NULL) return;
    uintptr_t key = (uintptr_t)ssl;
    dispatch_async(g_tlsQueue, ^{
        NSNumber *k = @(key);
        NSNumber *sz = g_connSizes[k] ?: @0;
        if (sz.integerValue >= kMaxPerConn) return;

        NSFileHandle *fh = g_connFiles[k];
        if (!fh) {
            if (g_connFiles.count >= kMaxConns) return;  // 连接数满了：不再开新文件（保守防爆盘）
            NSString *path = [kTlsDir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%llx.log", (unsigned long long)key]];
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) return;
            g_connFiles[k] = fh;
            NSString *hdr = [NSString stringWithFormat:@"# conn %llx opened %.3f\n",
                             (unsigned long long)key, CFAbsoluteTimeGetCurrent()];
            [fh writeData:[hdr dataUsingEncoding:NSUTF8StringEncoding]];
        }

        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"[%.3f] %@ len=%d\n", CFAbsoluteTimeGetCurrent(),
         isRead ? @"READ" : @"WRITE", len];
        appendData(s, buf, len);
        [s appendString:@"---\n"];
        [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
        g_connSizes[k] = @(sz.integerValue + len);
    });
}

static int my_ssl_read(void *ssl, void *buf, int num) {
    int r = orig_ssl_read(ssl, buf, num);
    if (r > 0) logTLS(ssl, YES, buf, r);
    return r;
}

static int my_ssl_write(void *ssl, const void *buf, int num) {
    if (buf && num > 0) logTLS(ssl, NO, buf, num);
    return orig_ssl_write(ssl, buf, num);
}

// ==== 验证日志（写 /tmp/tls_hook.log + 本 App Documents）====
static void tls_log(const char *msg) {
    FILE *f = fopen("/tmp/tls_hook.log", "a");
    if (f) { fprintf(f, "[%lld] %s\n", (long long)time(NULL), msg); fclose(f); }
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        if (home) {
            NSString *p = [home stringByAppendingPathComponent:@"Documents/tls_hook.log"];
            NSString *line = [NSString stringWithFormat:@"[%lld] %s\n", (long long)time(NULL), msg];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        }
    }
}

// ==== 反 SSL Pinning（抄 SSL Kill Switch 2 的 iOS 13+ BoringSSL hook）====
// 关键：抖音/小红书等有证书 Pinning，即使 CA 被系统信任也会拒 MITM 证书(握手 SSL_accept rc=-4)。
//   抄 ssl-kill-switch2：hook BoringSSL 的 SSL_set_custom_verify，强制用不校验的回调(SSL_VERIFY_NONE)，
//   + SSL_get_psk_identity 返回假值 —— App 接受任意 MITM 证书 → 我们 VpnTunnel 的 TLS 劫持能解。
#define SSL_VERIFY_NONE 0
static int no_verify_cb(void *ssl, uint8_t *out_alert) {
    return 0;  // ssl_verify_ok：证书 100% 有效
}
static void (*orig_ssl_set_custom_verify)(void *ssl, int mode,
                                          int (*cb)(void *ssl, uint8_t *out_alert));
static void my_ssl_set_custom_verify(void *ssl, int mode,
                                     int (*cb)(void *ssl, uint8_t *out_alert)) {
    tls_log("hook SSL_set_custom_verify CALLED");
    if (orig_ssl_set_custom_verify) orig_ssl_set_custom_verify(ssl, SSL_VERIFY_NONE, no_verify_cb);
}
static char *(*orig_ssl_get_psk_identity)(void *ssl);
static char *my_ssl_get_psk_identity(void *ssl) {
    tls_log("hook SSL_get_psk_identity CALLED");
    return "notarealPSKidentity";
}

__attribute__((constructor))
static void tlsHookInit() {
    g_tlsQueue = dispatch_queue_create("trollagent.tls", NULL);
    g_connFiles = [NSMutableDictionary dictionary];
    g_connSizes = [NSMutableDictionary dictionary];

    [[NSFileManager defaultManager] createDirectoryAtPath:kTlsDir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    tls_log("TLSHook constructor EXECUTED");
    struct rebinding binds[4];
    binds[0].name = "SSL_read";
    binds[0].replacement = (void *)my_ssl_read;
    binds[0].replaced = (void **)&orig_ssl_read;
    binds[1].name = "SSL_write";
    binds[1].replacement = (void *)my_ssl_write;
    binds[1].replaced = (void **)&orig_ssl_write;
    binds[2].name = "SSL_set_custom_verify";
    binds[2].replacement = (void *)my_ssl_set_custom_verify;
    binds[2].replaced = (void **)&orig_ssl_set_custom_verify;
    binds[3].name = "SSL_get_psk_identity";
    binds[3].replacement = (void *)my_ssl_get_psk_identity;
    binds[3].replaced = (void **)&orig_ssl_get_psk_identity;

    int rc = rebind_symbols(binds, 4);
    char rb[64];
    snprintf(rb, sizeof rb, "rebind_symbols rc=%d", rc);
    tls_log(rb);
}
