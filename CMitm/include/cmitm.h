#ifndef CMITM_H
#define CMITM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- 证书 ----
 * mitm_ca_init: 在 cert_dir 下查找/生成根 CA（ca.pem / ca_key.pem, EC P-256 自签）。
 * 返回 0 成功。进程内只初始化一次，之后 mitm_sign_host 可用。
 */
int mitm_ca_init(const char *cert_dir);

/* mitm_sign_host: 用根 CA 为 host 签发叶子证书（ECDSA-SHA256, 含 SAN）。
 * 输出 DER 格式叶子证书 + PKCS8 叶子私钥，调用方用 mitm_free 释放。返回 0 成功。 */
int mitm_sign_host(const char *host,
                   unsigned char **cert_der, size_t *cert_len,
                   unsigned char **key_der, size_t *key_len);

void mitm_free(void *p);

/* ---- TLS 封装（在已连接 fd 上做握手） ---- */
struct mitm_ssl;

/* TLS server 握手（对 App 侧，用叶子证书）；成功返回句柄，失败 NULL */
struct mitm_ssl *mitm_tls_accept(int fd,
                                 const unsigned char *cert_der, size_t cert_len,
                                 const unsigned char *key_der, size_t key_len);

/* TLS client 连接（对上游真实服务器，SNI=host，不验证上游证书）；成功返回句柄，失败 NULL */
struct mitm_ssl *mitm_tls_connect(int fd, const char *host);

/* 读/写：返回字节数；<=0 表示错误或关闭（0=EOF） */
int mitm_read(struct mitm_ssl *s, char *buf, int n);
int mitm_write(struct mitm_ssl *s, const char *buf, int n);
/* 尽力半关闭（发送 close_notify，通知对端本方向结束；之后仍可读） */
void mitm_shutdown(struct mitm_ssl *s);
void mitm_close(struct mitm_ssl *s);

#ifdef __cplusplus
}
#endif

#endif /* CMITM_H */
