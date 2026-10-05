// MitmC.h —— OpenSSL TLS MITM 引擎（Step 1 MVP：隧道打通 + 明文可见）
// 用自签 CA 为每个目标域名签发证书，对 443 CONNECT 做双向 TLS 劫持：
//   服务端角色(对 hev 客户端) SSL_accept → 明文 → 客户端角色(对真实服务器) SSL_connect
// 暴露给 Swift：Socks5Server 收到 CONNECT host:port，port==443 时调 mitm_handle。
#ifndef MitmC_h
#define MitmC_h

#ifdef __cplusplus
extern "C" {
#endif

// 初始化 MITM 引擎：加载 CA 证书 + 私钥（用于签发域名证书）
// 返回 0 成功；负值失败（-1 打不开 ca_pem，-2 读不到证书，-3 打不开私钥，-4 读不到私钥）
int mitm_init(const char *ca_pem, const char *ca_key_pem);

// 对已建立的连接(cfd=hev 客户端 fd)做 MITM：host=目标域名, port=目标端口
// 阻塞直到双向转发结束。返回 0 正常完成；负值失败。
int mitm_handle(int cfd, const char *host, int port);

#ifdef __cplusplus
}
#endif

#endif /* MitmC_h */
