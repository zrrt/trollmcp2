// Step B: 桥接头——把 CHev.h（hev 内核桥接 + utun 需要的 ctl_info/sockaddr_ctl/CTLIOCGINFO shim）
// 暴露给 Swift（TunnelProvider 直接调 hev_socks5_tunnel_* 与 utun fd 探测）。
#ifndef VpnTunnel_Bridging_h
#define VpnTunnel_Bridging_h

#include "CHev.h"

#endif /* VpnTunnel_Bridging_h */
