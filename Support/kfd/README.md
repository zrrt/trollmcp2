# kfd 免越狱信任注入（system VPN 真连）

## 要解决的问题

TrollAgent 用 TrollStore 假签名装好、主 App 能跑，但 **packet-tunnel 扩展被 NECP 校验拦下**（CS_VALID 过不了假签名），表现为 `NEVPNErrorConfigurationInvalid`，system VPN 连不上、设置里也开不了。

审计"fuck巨魔工具箱"（同为 TrollStore 装的 .tipa，能真连抓包 VPN）后确认其机制：

- **不是** entitlements 写法（无 team / allow-vpn 只是它的签名表象）
- **是** 它内置 **kfd 内核利用**（`FuckKfdHelper`，`puaf_landa`/MEOW 漏洞）：
  起 VPN 前把 packet-tunnel 扩展的 **cdhash 写进内核 trust cache** → 系统把假签名当合法信任 → NECP 放行 → 真连
- kfd 是**免越狱**的临时内核利用（用完退出、不留痕），支持 **iOS 15.5–16.6.1**（16.7 起被修）——你的 iOS 16.3 正在黄金区间
- iOS 17.x 需**真越狱**（Dopamine 3.0 / palera1n），靠 `jailbreakd` hook csops+necp 常驻放行，非越狱无解

## 统一架构（一套代码跨版本）

```
TrollAgent 主 App（共用层：聊天/MCP/抓包/解析）
        │
        ▼  起 VPN 前
TrustEnabler.resolvePath()
   ├─ .kfdInject  iOS 16.x 非越狱 → posix_spawn kfd_helper 注入 trust cache
   ├─ .jailbreak  iOS 17.x 越狱   → jailbreakd 已常驻，直接起
   └─ .fallback   都不满足        → 本地代理(127.0.0.1:18180)抓 HTTP
        │
        ▼
VpnManager.startVpnViaRegisteredManager()  ← 统一出口
```

## 注入机制（v3.6.18 起：胶水版 + FuckKfdHelper 引擎）

v3.6.18 之前，`kfd_helper.c` 自实现 kfd 注入，卡在 `kalloc`（内核内存分配）与"调用 `pmap_image4_trust_caches`"两个原语上（libkfd 只给 kread/kwrite，无 kalloc/kcall）。

v3.6.18 起改为**复用已验证的注入引擎**（路线 A）：

```
TrustEnabler spawn kfd_helper <VpnTunnel.appex 路径>
   │  kfd_helper（纯 C 胶水，本仓库 tools/kfd_helper.c）
   │    1. 解析 Mach-O → 提取 VpnTunnel 的 20B cdhash（40 位 hex）
   │    2. posix_spawn 同目录 Resources/bin/fuck_helper <40hex>
   ▼
fuck_helper（= Fuck 工具箱的 FuckKfdHelper，已完整逆向其机制）
     kopen(puaf_landa) 临时拿内核读写
     → patchfind pmap_image4_trust_caches（运行时扫内核 __text 特征，无静态偏移表）
     → IOSurface kalloc 分配一块内核可写内存（tc_kaddr）
     → kwrite 把 trust_cache（含 VpnTunnel 的 cdhash）写进 tc_kaddr
     → DMA 物理写注册（IOBufferMemoryDescriptor+IODMACommand+ml_dbgwrap_halt_cpu 暂停 CPU 绕 PPL）
     → kread 校验 tc 是否生效
     → kclose 退出（免越狱、不留痕）
   │
   ▼ 返回 0 → TrustEnabler 放行 → VpnManager 起 packet-tunnel
```

**为什么用 Fuck 的引擎而非自研**：FuckKfdHelper 已在 iOS 16.3 巨魔上被验证能真连抓包，其完整机制已被逆向确认（IOSurface kalloc + DMA 物理写绕过 PPL），自研移植（ObjC/C 混合 + PPL 绕过 + halt CPU）工作量大且无法在无 Xcode 的 Linux 环境本地编译验证，风险高。Fuck 二进制在仓库 `Resources/bin/fuck_helper`（arm64，TrollStore 假签名环境可执行），自用无碍。

## 文件清单

| 文件 | 作用 |
|---|---|
| `tools/kfd_helper.c` | **纯 C 胶水**（v3.6.18 重写）：提取 VpnTunnel 的 cdhash → posix_spawn 同目录 fuck_helper，返回其退出码。不依赖 libkfd |
| `tools/build_kfd_helper.sh` | macOS 编译脚本（纯 C + CommonCrypto，无需 clone libkfd） |
| `Resources/bin/fuck_helper` | FuckKfdHelper 注入引擎（arm64，已验证 16.3） |
| `Sources/TrollMCP2/TrustEnabler.swift` | Swift 探测(越狱/iOS版本/kfd区间) + 路径调度 + posix_spawn |
| `Sources/TrollMCP2/VpnManager.swift` | `startVpn` 起手调用 `TrustEnabler.injectIfNeeded` |
| `.github/workflows/build-trollmcp2.yml` | 加 "Build kfd_helper" step（失败不阻塞） |

## 编译

CI 的 macOS runner 会自动跑 `tools/build_kfd_helper.sh` 把 `kfd_helper`（胶水版）放进 `Resources/bin/`（打进 IPA）。
`fuck_helper` 是**预编译二进制**直接躺在 `Resources/bin/`，无需编译。本地：`bash tools/build_kfd_helper.sh`。

## 逆向记录（FuckKfdHelper 机制，已完成）

对 `Fuck.ipa` 内的 `FuckKfdHelper` 做了完整反汇编（30794 条）+ 符号表解析，机制全部落地：

- **kalloc** = `_dg_kalloc`（0x10001f97c）：`IOSurfaceCreate` 分配用户可控内核对象 → kread 沿对象链定位内核地址（tc_kaddr）
- **"调用 pmap"** = `_dma_perform`（0x10001055c）：不是普通 kcall，而是 **PPL 绕过的 DMA 物理写**——`IOBufferMemoryDescriptor+IODMACommand` 建立 DMA 映射 + `ml_dbgwrap_halt_cpu` 暂停 CPU → `_dma_writevirt64(pmap_addr, tc)` → `_physwrite64_mapped` → 恢复 CPU
- **patchfind** = `_find_pmap_image4_trust_caches`（0x100010ab0）：运行时扫内核 `__text` 匹配序言特征（无静态偏移表）
- 备选：还内置 `_dimentio`/`_tfp0`（拿 tfp0 后 kread/kwrite）、`_meow`、`_isarm64e`

## 验证方法（改完后真机）

1. `bash tools/build_kfd_helper.sh` 编译通过，`file Resources/bin/kfd_helper` 显示 arm64；`file Resources/bin/fuck_helper` 显示 arm64
2. 装 TrollAgent → 起 VPN → 看日志 `/var/mobile/Documents/kfd_helper.log`：
   - 应有 `extracted cdhash=...`、`invoking .../fuck_helper ...`、`fuck_helper exit=0`
   - FuckKfdHelper 自身日志（NSLog/printf）也会进同一文件
3. **硬标准**：设置→VPN 出现"TrollAgent 抓包 VPN"、能开、状态栏出现**钥匙图标**
   （App 内显示"已连接"不算，那可能只是假成功）
4. 若注入失败（日志 kopen failed / fuck_helper exit 非 0），确认设备 iOS 在 15.5–16.6.1、且非越狱

## 安全边界

kfd 是公开开源的内核利用库，本方案仅用于**用户自有设备**上让 TrollAgent
自身的抓包 VPN 正常工作，属自有设备调试/逆向开发，不涉及他人系统。
