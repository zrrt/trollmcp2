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

## 文件清单

| 文件 | 作用 |
|---|---|
| `tools/kfd_helper.c` | 独立 arm64 可执行：kopen(puaf_landa) → 提取/接收 cdhash → 注入内核 trust cache → kclose |
| `tools/build_kfd_helper.sh` | macOS 编译脚本（clone felix-pb/kfd + 覆盖偏移表 + clang 编 arm64） |
| `tools/kfd/dynamic_info.h` | 现成 kfd 偏移表（iOS 16.3 A12–A16 + iOS 16.6），build 时覆盖 libkfd 同名文件 |
| `Sources/TrollMCP2/TrustEnabler.swift` | Swift 探测(越狱/iOS版本/kfd区间) + 路径调度 + posix_spawn |
| `Sources/TrollMCP2/VpnManager.swift` | `startVpn` 起手调用 `TrustEnabler.injectIfNeeded` |
| `.github/workflows/build-trollmcp2.yml` | 加 "Build kfd_helper" step（失败不阻塞） |

## 编译

CI 的 macOS runner 会自动跑 `tools/build_kfd_helper.sh` 把 `kfd_helper` 放进 `Resources/bin/`（打进 IPA）。
本地：`bash tools/build_kfd_helper.sh`。

## ✅ 已完成：kopen 偏移表整合（现成数据）

> **仓库名修正**：libkfd 官方仓库是 **`felix-pb/kfd`**（不是 `Felix-pb/libkfd`，后者不存在）。
> libkfd 是 **header-only 库**——公开 API 只有 `kopen(pages, puaf, kread, kwrite)/kread/kwrite/kclose`，
> **没有 kalloc、没有 kcall（调用内核函数）**。要注入 trust cache 必须自己实现
> `kalloc` 分配 + 调用 `pmap_image4_trust_caches`（参考反编译 FuckKfdHelper）。
>
> **已整合**：`tools/kfd/dynamic_info.h` 是**现成开源偏移表**（kopen 建立内核读写原语用），
> 由 Lrdsnow/kfd_offsets（iOS 16.3 A12–A16）合并 felix-pb/kfd 原版（iOS 16.6）得到，
> build 脚本会在编译时用它**覆盖** libkfd 的 `info/dynamic_info.h`（原版只有 16.6，匹配不到 16.3 设备）。
> kfd_helper.c 已按 libkfd 真实 API 修正：`kopen(2048, puaf_landa, kread_kqueue_workloop_ctl, kwrite_dup)`、
> `kfd->perf.kernel_slide`。
>
> **CI 当前无 kfd step**：恢复自动构建时，`build_kfd_helper.sh` 已修正可用（clone felix-pb/kfd + 覆盖 + header-only 编译），
> 或在本机 `bash tools/build_kfd_helper.sh` 编好后放进 `Resources/bin/`（build-ipa.sh 会自动打包）。

## ⚠️ 未完成项（必须先在你 Mac 上对齐，否则编不出可跑二进制）

1. **`pmap_image4_trust_caches` 偏移** —— `tools/kfd_helper.c` 里 `PMAP_IMAGE4_TRUST_CACHES_OFFSET` 当前为 `0x0` TODO，
   Apple **私有符号**，公开开源稀缺（动态信息表/Serotonin/kfdmineek 均不含）；唯一现成来源是 **FuckKfdHelper** 内置
   （按 kern.version 匹配，缓存在 `kfund_offsets.plist`），需在你的 Mac 上完整反编译 FuckKfdHelper 提取具体偏移值
2. **kalloc / 调用原语** —— 构造 trust cache 后的 `kalloc` 分配与"调用内核函数 pmap_image4_trust_caches"
   的原语，libkfd 未提供，需自己实现（参考反编译 FuckKfdHelper 的 kalloc+kcall 部分）
3. **trust_cache 结构布局** —— 已按 XNU syspolicy 约定写 `struct trust_cache`，但需对目标内核核对
   （版本字段、entry 大小、uuid）

以上是**工程化骨架**：整体流程/集成/探测已按证据对齐，但内核层细节必须在真机上对齐 libkfd 版本后才能验证，我无法在 Linux 沙箱编译 iOS arm64 或做真机测试。

## 验证方法（改完后真机）

1. `bash tools/build_kfd_helper.sh` 编译通过，`file Resources/bin/kfd_helper` 显示 arm64
2. 装 TrollAgent → 起 VPN → 看日志有无 `[kfd-helper] trust cache injected`
3. **硬标准**：设置→VPN 出现"TrollAgent 抓包 VPN"、能开、状态栏出现**钥匙图标**
   （App 内显示"已连接"不算，那可能只是假成功）
4. 若 kfd 注入失败（日志 kopen failed），确认设备 iOS 在 15.5–16.6.1、且非越狱

## 安全边界

kfd 是公开开源的内核利用库（Felix-pb/libkfd），本方案仅用于**用户自有设备**上让 TrollAgent
自身的抓包 VPN 正常工作，属自有设备调试/逆向开发，不涉及他人系统。
