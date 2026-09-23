// CMitm：MITM 抓包内核的 C 桥接层（OpenSSL）
// 职责：根 CA 生成/加载、叶子证书签发、TLS server/client 握手封装。
// 纯 C，无 C++，供 Swift 侧通过 import CMitm 调用。

#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/rand.h>
#include <openssl/bn.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdio.h>
#include "cmitm.h"

#define CA_CN "TrollAgent MITM CA"
#define CA_FILE "ca.pem"
#define CA_KEY_FILE "ca_key.pem"

static X509 *g_ca_cert = NULL;
static EVP_PKEY *g_ca_key = NULL;
static int g_ca_loaded = 0;

static EVP_PKEY *ec_new_key(void) {
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
    if (!ctx) return NULL;
    EVP_PKEY *k = NULL;
    if (EVP_PKEY_keygen_init(ctx) <= 0) { EVP_PKEY_CTX_free(ctx); return NULL; }
    if (EVP_PKEY_CTX_set_ec_paramgen_curve_nid(ctx, NID_X9_62_prime256v1) <= 0) { EVP_PKEY_CTX_free(ctx); return NULL; }
    if (EVP_PKEY_keygen(ctx, &k) <= 0) { EVP_PKEY_CTX_free(ctx); return NULL; }
    EVP_PKEY_CTX_free(ctx);
    return k;
}

static int x509_add_cn(X509_NAME *name, const char *cn) {
    return X509_NAME_add_entry_by_NID(name, NID_commonName, MBSTRING_ASC,
                                      (const unsigned char *)cn, -1, -1, 0);
}

static X509 *make_ca(EVP_PKEY *key) {
    X509 *x = X509_new();
    if (!x) return NULL;
    X509_set_version(x, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x), 0x1000);
    X509_gmtime_adj(X509_getm_notBefore(x), -3600);
    X509_gmtime_adj(X509_getm_notAfter(x), 365L * 24 * 3600);
    X509_NAME *name = X509_get_subject_name(x);
    if (x509_add_cn(name, CA_CN) <= 0) { X509_free(x); return NULL; }
    X509_set_issuer_name(x, name);
    X509_set_pubkey(x, key);
    X509_EXTENSION *bc = X509V3_EXT_conf_nid(NULL, NULL, NID_basic_constraints, "critical,CA:TRUE");
    if (bc) { X509_add_ext(x, bc, -1); X509_EXTENSION_free(bc); }
    X509_EXTENSION *ku = X509V3_EXT_conf_nid(NULL, NULL, NID_key_usage, "critical,keyCertSign,cRLSign");
    if (ku) { X509_add_ext(x, ku, -1); X509_EXTENSION_free(ku); }
    if (X509_sign(x, key, EVP_sha256()) <= 0) { X509_free(x); return NULL; }
    return x;
}

static int save_ca(const char *dir) {
    char cert_path[1024], key_path[1024], der_path[1024];
    snprintf(cert_path, sizeof(cert_path), "%s/%s", dir, CA_FILE);
    snprintf(key_path, sizeof(key_path), "%s/%s", dir, CA_KEY_FILE);
    snprintf(der_path, sizeof(der_path), "%s/ca.der", dir);
    FILE *fc = fopen(cert_path, "wb");
    if (!fc) return -1;
    PEM_write_X509(fc, g_ca_cert);
    fclose(fc);
    FILE *fk = fopen(key_path, "wb");
    if (!fk) return -1;
    PEM_write_PrivateKey(fk, g_ca_key, NULL, NULL, 0, NULL, NULL);
    fclose(fk);
    // 同时导出 DER（iOS SecCertificateCreateWithData / mobileconfig PayloadContent 只认 DER）
    unsigned char *der = NULL;
    int dlen = i2d_X509(g_ca_cert, &der);
    if (dlen > 0 && der) {
        FILE *fd = fopen(der_path, "wb");
        if (fd) { fwrite(der, 1, (size_t)dlen, fd); fclose(fd); }
        OPENSSL_free(der);
    }
    return 0;
}

static int load_ca(const char *dir) {
    char cert_path[1024], key_path[1024];
    snprintf(cert_path, sizeof(cert_path), "%s/%s", dir, CA_FILE);
    snprintf(key_path, sizeof(key_path), "%s/%s", dir, CA_KEY_FILE);
    FILE *fc = fopen(cert_path, "rb");
    if (!fc) return -1;
    g_ca_cert = PEM_read_X509(fc, NULL, NULL, NULL);
    fclose(fc);
    FILE *fk = fopen(key_path, "rb");
    if (!fk) return -1;
    g_ca_key = PEM_read_PrivateKey(fk, NULL, NULL, NULL);
    fclose(fk);
    return (g_ca_cert && g_ca_key) ? 0 : -1;
}

int mitm_ca_init(const char *cert_dir) {
    if (g_ca_loaded) return 0;
    if (load_ca(cert_dir) == 0) { g_ca_loaded = 1; return 0; }
    g_ca_key = ec_new_key();
    if (!g_ca_key) return -1;
    g_ca_cert = make_ca(g_ca_key);
    if (!g_ca_cert) { EVP_PKEY_free(g_ca_key); g_ca_key = NULL; return -1; }
    if (save_ca(cert_dir) != 0) return -1;
    g_ca_loaded = 1;
    return 0;
}

/* 把已加载/生成的根证书导出为 DER 文件（ca.der）。供 mobileconfig 打包用。 */
int mitm_ca_export_der(const char *cert_dir) {
    if (!g_ca_cert) {
        if (load_ca(cert_dir) != 0) return -1;
        g_ca_loaded = 1;
    }
    char der_path[1024];
    snprintf(der_path, sizeof(der_path), "%s/ca.der", cert_dir);
    unsigned char *der = NULL;
    int dlen = i2d_X509(g_ca_cert, &der);
    if (dlen <= 0 || !der) return -1;
    FILE *fd = fopen(der_path, "wb");
    if (!fd) { OPENSSL_free(der); return -1; }
    size_t w = fwrite(der, 1, (size_t)dlen, fd);
    fclose(fd);
    OPENSSL_free(der);
    return w == (size_t)dlen ? 0 : -1;
}

static int is_ip(const char *host) {
    struct in_addr a;
    struct in6_addr a6;
    return inet_pton(AF_INET, host, &a) == 1 || inet_pton(AF_INET6, host, &a6) == 1;
}

int mitm_sign_host(const char *host,
                   unsigned char **cert_der, size_t *cert_len,
                   unsigned char **key_der, size_t *key_len) {
    if (!g_ca_loaded) return -1;
    EVP_PKEY *leaf_key = ec_new_key();
    if (!leaf_key) return -1;
    X509 *leaf = X509_new();
    if (!leaf) { EVP_PKEY_free(leaf_key); return -1; }
    unsigned char serial_buf[8];
    RAND_bytes(serial_buf, sizeof(serial_buf));
    BIGNUM *bn = BN_bin2bn(serial_buf, sizeof(serial_buf), NULL);
    ASN1_INTEGER *serial = BN_to_ASN1_INTEGER(bn, NULL);
    BN_free(bn);
    if (serial) { X509_set_serialNumber(leaf, serial); ASN1_INTEGER_free(serial); }
    X509_set_version(leaf, 2);
    X509_gmtime_adj(X509_getm_notBefore(leaf), -3600);
    X509_gmtime_adj(X509_getm_notAfter(leaf), 30L * 24 * 3600);
    X509_NAME *name = X509_get_subject_name(leaf);
    if (x509_add_cn(name, host) <= 0) { X509_free(leaf); EVP_PKEY_free(leaf_key); return -1; }
    X509_set_issuer_name(leaf, X509_get_subject_name(g_ca_cert));
    X509_set_pubkey(leaf, leaf_key);
    X509V3_CTX v3ctx;
    X509V3_set_ctx_nodb(&v3ctx);
    X509V3_set_ctx(&v3ctx, g_ca_cert, leaf, NULL, NULL, 0);
    char san[512];
    snprintf(san, sizeof(san), "%s:%s", is_ip(host) ? "IP" : "DNS", host);
    X509_EXTENSION *ext = X509V3_EXT_conf_nid(NULL, &v3ctx, NID_subject_alt_name, san);
    if (ext) {
        X509_add_ext(leaf, ext, -1);
        X509_EXTENSION_free(ext);
    }
    if (X509_sign(leaf, g_ca_key, EVP_sha256()) <= 0) {
        X509_free(leaf);
        EVP_PKEY_free(leaf_key);
        return -1;
    }
    int clen = i2d_X509(leaf, NULL);
    int klen = i2d_PrivateKey(leaf_key, NULL);
    if (clen <= 0 || klen <= 0) { X509_free(leaf); EVP_PKEY_free(leaf_key); return -1; }
    unsigned char *c = (unsigned char *)OPENSSL_malloc((size_t)clen);
    unsigned char *k = (unsigned char *)OPENSSL_malloc((size_t)klen);
    if (!c || !k) {
        if (c) OPENSSL_free(c);
        if (k) OPENSSL_free(k);
        X509_free(leaf);
        EVP_PKEY_free(leaf_key);
        return -1;
    }
    unsigned char *pc = c, *pk = k;
    i2d_X509(leaf, &pc);
    i2d_PrivateKey(leaf_key, &pk);
    *cert_der = c;
    *cert_len = (size_t)clen;
    *key_der = k;
    *key_len = (size_t)klen;
    X509_free(leaf);
    EVP_PKEY_free(leaf_key);
    return 0;
}

/* ---- TLS ---- */
struct mitm_ssl {
    SSL *ssl;
};

static SSL_CTX *ctx_for_leaf(const unsigned char *cert_der, size_t cert_len,
                             const unsigned char *key_der, size_t key_len, int is_server) {
    SSL_CTX *ctx = SSL_CTX_new(is_server ? TLS_server_method() : TLS_client_method());
    if (!ctx) return NULL;
    if (is_server) {
        const unsigned char *p = cert_der;
        X509 *x = d2i_X509(NULL, &p, (long)cert_len);
        if (!x) { SSL_CTX_free(ctx); return NULL; }
        p = key_der;
        EVP_PKEY *k = d2i_PrivateKey(EVP_PKEY_EC, NULL, &p, (long)key_len);
        if (!k) { X509_free(x); SSL_CTX_free(ctx); return NULL; }
        if (SSL_CTX_use_certificate(ctx, x) <= 0 ||
            SSL_CTX_use_PrivateKey(ctx, k) <= 0 ||
            SSL_CTX_check_private_key(ctx) <= 0) {
            EVP_PKEY_free(k);
            X509_free(x);
            SSL_CTX_free(ctx);
            return NULL;
        }
        EVP_PKEY_free(k);
        X509_free(x);
    }
    return ctx;
}

struct mitm_ssl *mitm_tls_accept(int fd,
                                 const unsigned char *cert_der, size_t cert_len,
                                 const unsigned char *key_der, size_t key_len) {
    SSL_CTX *ctx = ctx_for_leaf(cert_der, cert_len, key_der, key_len, 1);
    if (!ctx) return NULL;
    SSL *ssl = SSL_new(ctx);
    SSL_CTX_free(ctx);
    if (!ssl) return NULL;
    SSL_set_fd(ssl, fd);
    if (SSL_accept(ssl) <= 0) { SSL_free(ssl); return NULL; }
    struct mitm_ssl *m = (struct mitm_ssl *)OPENSSL_malloc(sizeof(struct mitm_ssl));
    if (!m) { SSL_free(ssl); return NULL; }
    m->ssl = ssl;
    return m;
}

struct mitm_ssl *mitm_tls_connect(int fd, const char *host) {
    SSL_CTX *ctx = ctx_for_leaf(NULL, 0, NULL, 0, 0);
    if (!ctx) return NULL;
    SSL *ssl = SSL_new(ctx);
    SSL_CTX_free(ctx);
    if (!ssl) return NULL;
    SSL_set_verify(ssl, SSL_VERIFY_NONE, NULL);
    SSL_set_tlsext_host_name(ssl, host);
    SSL_set_fd(ssl, fd);
    if (SSL_connect(ssl) <= 0) { SSL_free(ssl); return NULL; }
    struct mitm_ssl *m = (struct mitm_ssl *)OPENSSL_malloc(sizeof(struct mitm_ssl));
    if (!m) { SSL_free(ssl); return NULL; }
    m->ssl = ssl;
    return m;
}

int mitm_read(struct mitm_ssl *s, char *buf, int n) {
    return SSL_read(s->ssl, buf, n);
}
int mitm_write(struct mitm_ssl *s, const char *buf, int n) {
    return SSL_write(s->ssl, buf, n);
}
void mitm_shutdown(struct mitm_ssl *s) {
    if (!s) return;
    SSL_shutdown(s->ssl);
}
void mitm_close(struct mitm_ssl *s) {
    if (!s) return;
    SSL_shutdown(s->ssl);
    SSL_free(s->ssl);
    OPENSSL_free(s);
}
void mitm_free(void *p) {
    if (p) OPENSSL_free(p);
}
