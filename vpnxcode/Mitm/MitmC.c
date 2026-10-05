// MitmC.c —— OpenSSL TLS MITM 引擎（Step 1.1：SNI 域名签发证书）
// 问题背景：hev 的 SOCKS5 CONNECT 传的是 IP(已把域名 DNS 解析成 IP) → 若用 IP 签证书，CN=IP
//   与 App 期望的域名对不上 → App 拒证书 → 连接反复失败("刷久了加载不出")。
// 修复：App 的 TLS ClientHello 必带 SNI(域名)；在服务端握手时用 SNI 回调动态签发 CN=域名 的
//   证书 + 用该域名连真实服务器 —— App 校验通过。
// 链路：hev 客户端 --TCP cfd--> [TLS 服务端角色(SNI 域名证书)] --明文--> [TLS 客户端角色] --TCP--> 真实服务器
#include "MitmC.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/rand.h>

static X509 *g_ca_cert = NULL;
static EVP_PKEY *g_ca_key = NULL;

int mitm_init(const char *ca_pem, const char *ca_key_pem) {
    SSL_library_init();
    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();

    BIO *b = BIO_new_file(ca_pem, "r");
    if (!b) return -1;
    g_ca_cert = PEM_read_bio_X509(b, NULL, NULL, NULL);
    BIO_free(b);
    if (!g_ca_cert) return -2;

    b = BIO_new_file(ca_key_pem, "r");
    if (!b) return -3;
    g_ca_key = PEM_read_bio_PrivateKey(b, NULL, NULL, NULL);
    BIO_free(b);
    if (!g_ca_key) return -4;

    return 0;
}

// 为 host 生成域名密钥+证书（用 CA 签发），返回证书；*out_key 传回私钥(调用方负责 EVP_PKEY_free)
static X509 *gen_cert(const char *host, EVP_PKEY **out_key) {
    EVP_PKEY *key = EVP_PKEY_new();
    if (!key) return NULL;
    RSA *rsa = RSA_new();
    BIGNUM *e = BN_new();
    BN_set_word(e, RSA_F4);
    if (!RSA_generate_key_ex(rsa, 2048, e, NULL) || EVP_PKEY_assign_RSA(key, rsa) != 1) {
        RSA_free(rsa); BN_free(e); EVP_PKEY_free(key); return NULL;
    }
    BN_free(e);

    X509 *x = X509_new();
    if (!x) { EVP_PKEY_free(key); return NULL; }
    X509_set_version(x, 2);

    unsigned char serial[16];
    if (RAND_bytes(serial, sizeof serial) != 1) {
        X509_free(x); EVP_PKEY_free(key); return NULL;
    }
    BIGNUM *bn = BN_bin2bn(serial, sizeof serial, NULL);
    ASN1_INTEGER *ai = ASN1_INTEGER_new();
    BN_to_ASN1_INTEGER(bn, ai);
    X509_set_serialNumber(x, ai);
    ASN1_INTEGER_free(ai); BN_free(bn);

    X509_gmtime_adj(X509_get_notBefore(x), -300);             // 5 分钟前生效
    X509_gmtime_adj(X509_get_notAfter(x), 60L * 60 * 24 * 365); // 1 年有效
    X509_set_pubkey(x, key);

    X509_NAME *name = X509_get_subject_name(x);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                               (const unsigned char *)host, -1, -1, 0);
    X509_set_issuer_name(x, X509_get_subject_name(g_ca_cert));
    X509_sign(x, g_ca_key, EVP_sha256());

    if (out_key) *out_key = key;
    else EVP_PKEY_free(key);
    return x;
}

// ClientHello 回调：App 的 ClientHello 到后、握手继续前，用 SNI 域名动态签发证书并应用到该 SSL
// 返回值用字面量(1=OK, 0=ERROR)——SSL_CLIENT_HELLO_OK/ERROR 宏在部分 OpenSSL 头缺失，避免依赖
static int mitm_client_hello_cb(SSL *s, int *al, void *arg) {
    const char *host = SSL_get_servername(s, TLSEXT_NAMETYPE_host_name);
    if (!host || !host[0]) return 1;  // 无 SNI 用默认证书
    EVP_PKEY *key = NULL;
    X509 *x = gen_cert(host, &key);
    if (!x || !key) return 0;
    SSL_use_certificate(s, x);
    SSL_use_PrivateKey(s, key);
    X509_free(x);
    EVP_PKEY_free(key);
    return 1;
}

// 非阻塞双向明文转发：c(服务端/客户端侧) <-> s(真实服务器侧)
static void mitm_pump(SSL *c, SSL *s) {
    char buf[16384];
    int c_open = 1, s_open = 1;
    while (c_open || s_open) {
        if (c_open) {
            int n = SSL_read(c, buf, sizeof buf);
            if (n > 0) {
                int off = 0;
                while (off < n) {
                    int w = SSL_write(s, buf + off, n - off);
                    if (w <= 0) { c_open = 0; break; }
                    off += w;
                }
            } else {
                int e = SSL_get_error(c, n);
                if (n == 0 || e == SSL_ERROR_ZERO_RETURN) c_open = 0;
                else if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) c_open = 0;
            }
        }
        if (s_open) {
            int n = SSL_read(s, buf, sizeof buf);
            if (n > 0) {
                int off = 0;
                while (off < n) {
                    int w = SSL_write(c, buf + off, n - off);
                    if (w <= 0) { s_open = 0; break; }
                    off += w;
                }
            } else {
                int e = SSL_get_error(s, n);
                if (n == 0 || e == SSL_ERROR_ZERO_RETURN) s_open = 0;
                else if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) s_open = 0;
            }
        }
        usleep(500);
    }
}

int mitm_handle(int cfd, const char *host, int port) {
    if (!g_ca_cert || !g_ca_key) return -100;

    // 1) 服务端角色 ctx：SNI 回调动态签证书（对 hev 客户端）
    SSL_CTX *sctx = SSL_CTX_new(TLS_server_method());
    if (!sctx) return -3;
    SSL_CTX_set_client_hello_cb(sctx, mitm_client_hello_cb, NULL);
    SSL *ssr = SSL_new(sctx);
    SSL_set_fd(ssr, cfd);

    // 2) accept：触发 SNI 回调签发 CN=域名 的证书；同时拿到真实域名
    if (SSL_accept(ssr) != 1) {
        SSL_free(ssr); SSL_CTX_free(sctx); return -4;
    }
    const char *sni = SSL_get_servername(ssr, TLSEXT_NAMETYPE_host_name);
    const char *real = (sni && sni[0]) ? sni : host;

    // 3) 连真实服务器（用 SNI 域名）
    char pstr[16];
    snprintf(pstr, sizeof pstr, "%d", port);
    struct addrinfo h, *res = NULL;
    memset(&h, 0, sizeof h);
    h.ai_family = AF_UNSPEC;
    h.ai_socktype = SOCK_STREAM;
    int sfd = -1;
    if (getaddrinfo(real, pstr, &h, &res) == 0 && res) {
        for (struct addrinfo *rp = res; rp; rp = rp->ai_next) {
            sfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
            if (sfd < 0) continue;
            if (connect(sfd, rp->ai_addr, rp->ai_addrlen) == 0) break;
            close(sfd);
            sfd = -1;
        }
        freeaddrinfo(res);
    }
    if (sfd < 0) {
        SSL_free(ssr); SSL_CTX_free(sctx); return -1;
    }

    // 4) 客户端角色 TLS（连真实服务器，忽略其证书校验）
    SSL_CTX *cctx = SSL_CTX_new(TLS_client_method());
    if (!cctx) {
        close(sfd); SSL_free(ssr); SSL_CTX_free(sctx); return -2;
    }
    SSL *scl = SSL_new(cctx);
    SSL_set_fd(scl, sfd);
    SSL_set_verify(scl, SSL_VERIFY_NONE, NULL);
    SSL_set_tlsext_host_name(scl, real);
    if (SSL_connect(scl) != 1) {
        SSL_free(scl); SSL_CTX_free(cctx);
        SSL_free(ssr); SSL_CTX_free(sctx); close(sfd); return -5;
    }

    // 5) 双向明文转发
    mitm_pump(ssr, scl);

    SSL_free(scl); SSL_CTX_free(cctx);
    SSL_free(ssr); SSL_CTX_free(sctx);
    close(sfd);
    return 0;
}
