// CHev：hev-socks5-tunnel 内核桥接层（iOS 真机 slice 手动链接，避开 SwiftPM binaryTarget 平台选择问题）
// - 头文件声明 hev_socks5_tunnel_main/from_str/quit/stats（符号来自 build-ipa.sh 下载解压的
//   hev-stage/lib/libhev-socks5-tunnel.a，ios-arm64 slice）
// - 定义 iOS SDK 缺失的 ctl_info/sockaddr_ctl/CTLIOCGINFO（utun fd 探测用，原 Tun2SocksKitC shim）
#ifndef CHev_h
#define CHev_h

#include <stddef.h>
#include <stdint.h>

typedef uint8_t  u_int8_t;
typedef uint16_t u_int16_t;
typedef uint32_t u_int32_t;
typedef uint64_t u_int64_t;
typedef unsigned char u_char;

#ifndef CTLIOCGINFO
#define CTLIOCGINFO 0xc0644e03UL
#endif

struct ctl_info {
    u_int32_t   ctl_id;
    char        ctl_name[96];
};
struct sockaddr_ctl {
    u_char      sc_len;
    u_char      sc_family;
    u_int16_t   ss_sysaddr;
    u_int32_t   sc_id;
    u_int32_t   sc_unit;
    u_int32_t   sc_reserved[5];
};

#ifdef __cplusplus
extern "C" {
#endif

int hev_socks5_tunnel_main (const char *config_path, int tun_fd);
int hev_socks5_tunnel_main_from_file (const char *config_path, int tun_fd);
int hev_socks5_tunnel_main_from_str (const unsigned char *config_str,
                                     unsigned int config_len, int tun_fd);
void hev_socks5_tunnel_quit (void);
void hev_socks5_tunnel_stats (size_t *tx_packets, size_t *tx_bytes,
                              size_t *rx_packets, size_t *rx_bytes);

#ifdef __cplusplus
}
#endif

#endif /* CHev_h */
