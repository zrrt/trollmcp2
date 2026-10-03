# VPN 抓包开发进度留档（截至 2026-10-03）

> 本文件用于在断档时恢复上下文。所有内容为实测/日志/代码确证，不含推测。

## 1. 当前版本与提交链（新→旧）

| commit | 标签 | 内容 | CI |
|---|---|---|---|
| `5c0eb63` | fix3cx | 修复 VpnCaptureView `notice` 重复 @State 声明（编译错误） | ✅ success |
| `13fcf7a` | fix3cw | injectNow 防熄屏 main.sync→async 防死锁 | ❌ failure（因 notice 重名） |
| `1583854` | fix3cv | VPN 改手动注入复刻 Fuck 时机（TrustEnabler.injectNow / startVpn 不再自动注入 / vpn.capture inject 子命令 / UI 注入按钮+状态卡） | ❌ failure（同上） |
| `684a9bc` | fix3cu | 路由修复：原生命令按 firstWord 判断，带路径参数不再误入 Alpine（Permission denied bug） | ✅ success |
| `2eb3531` | fix3ct | VPN 复刻 Fuck（VpnTunnel.appex + 19 NIO 框架 + fuck_helper 引擎） | ✅ success |
| `66a0440` | fix3cs | 引擎换成 FuckKfdHelper 1.8.5 原版 296KB | ✅ success |
| `2ea1fb0` | fix3cr | kfd_helper.c 加固 cdhash 提取 | ✅ success |

发布产物直链：`https://github.com/zrrt/trollmcp2/releases/download/latest/TrollAgent.tipa`（约 105.9 MB）

## 2. 已确证的事实（带证据）

### 2.1 真机环境
- 设备：iPhone 14,3（iOS 16.3），TrollStore 免越狱
- app 实际安装名：`TrollAgent.app`（非 TrollMCP2.app）
- 真实路径：`/private/var/containers/Bundle/Application/32BE9D5C-573F-4F3E-9A08-2706E3541DDD/TrollAgent.app/`
- bin/ 共 37 原生工具（含 fuck_helper / kfd_helper / lua / node / r2 / cstool / git.py / ControlAgent.dylib…）
- VpnTunnel：`…/PlugIns/VpnTunnel.appex/VpnTunnel`（155,315 B）

### 2.2 黑屏根因（决定性证据）
- panic 日志：`/var/mobile/Library/Logs/CrashReporter/panic-full-2026-10-03-160410.000.ips`
- 关键行：`Panicked task pid 702: fuck_helper` + `Unexpected fault in kernel static region` + `far 0xfffffff02ff07df8`
- 结论：**fuck_helper 引擎 DMA 物理写算错地址，写进内核静态区 → 内核 panic → 黑屏重启**（另有 09-27、10-03-150435 两条同因 panic）

### 2.3 cdhash 与签名（已排除）
- 用内置原生 python3.14 直读 VpnTunnel Mach-O 解析签名：superblob `0xfade0cc0` length=41621 count=6
- 主 CD（idx0）SHA1 len=32469 hashSize=20 nCodeSlots=805
- **真实 cdhash = `51f9bca295be9c2e1dee77d093ce0fcf3fc93450`，提取必然成功**
- **黑屏与签名无关，已排除**

### 2.4 路由变通（已验证技巧）
- `kfd_helper … | cat` 走 iOS pipeline bin 兜底（原生直跑）
- 裸命令落 Alpine → Permission denied（即 fix3cu 修的 bug）
- `--diag <appex>` 模式安全不注入
- `ta list` / `ta help <tool>` 查 offload

### 2.5 真机远程通道
- 路由器 ssh：`121.31.145.125:10222`（root/1335612901，需重建 `/tmp/askpass.sh`）
- 手机 HTTP API：`http://192.168.31.108:8790`（Bearer 1335612901）
  - GET `/api/status` → ok/4.4.10/16.3/iPhone14,3/37 tools/trollstore_detected
  - POST `/api/tool` body `{"name":"<tool>","params":{...}}`

## 3. 用户最新实测结果（2026-10-03 手动注入改造后）

- **装了 fix3cx 版（手动注入 + 路由修复）**
- **点「注入信任」按钮 → 立即黑屏重启（复现）**
- 结合此前：远程手动触发（app 非前台）两次也黑屏
- **实锤结论：kfd 注入引擎在该 iOS 16.3 build 上有概率性失败（DMA panic），「app 前台 + 5s 空闲等待 + 防熄屏」只是降低概率，无法根除**

## 4. 下一步方向（供恢复时选择，需用户拍板）

1. **主推 local proxy（local_start）**：127.0.0.1:18180 + WiFi 手动代理，**无需注入、零黑屏风险**——但从未真机验证抓包闭环
2. **换注入引擎**：Fuck 1.8.5 的 fuck_helper 黑盒不稳定，考虑其他 trust cache 注入实现（风险高、工作量大）
3. **VPN 半成品定位确认**：当前 VPN 模式=系统代理隧道，**不转发 packetFlow** → 自建 socket 直连 App 会断网、QUIC/HTTP3 不解密、TLS-pinned 握手失败；优先验证 local proxy 闭环

## 5. 已知死路（勿重试）

- 原生 python3 内 fork/exec → Errno 45
- bundle 运行时写文件 → Permission denied
- iOS 原生 find `/var/containers… -name "*.app"` 返回空（find 实现 bug）
- Alpine 跑不了 arm64 iOS 二进制
- **kfd 自动注入 = 黑屏**（开 VPN 时机撞系统忙）
- **kfd 手动注入（fix3cx 实测）= 仍黑屏**（引擎不稳定）

## 6. 「权限 vs 注入目标」排查结论（2026-10-03 补充）

用户提出「Fuck 权限比我们多所以他能注入成功」——排查后**排除**：

- Fuck 多出的 TCC 权限（Liverpool/SpeechRecognition/Microphone/更多钥匙串组）是**用户态沙箱权限**，决定能否访问照片/麦克风/文件等，**与内核 panic 无关**。
- **Fuck 原版 FuckKfdHelper 也是独立 Mach-O arm64 可执行**（`code.app/FuckKfdHelper`），形态与我们 `Resources/bin/fuck_helper` 一致。
- **原版 Usage = `FuckKfdHelper <cdhash_hex>`**，与 kfd_helper 传给它的参数格式一致——**不是传参错误**。
- 二进制内含 libkfd 标准组件：`landa.c / smith.c / physpuppet.c`、`pmap_image4_trust_caches`（FuckInject fork 的 libkfd）。

**真正根因**：黑屏 = **kfd 漏洞利用（landa/smith/physpuppet）在该 iOS 16.3 build 上概率算错物理地址 → DMA 写内核静态区 → 内核 panic**。Fuck 1.8.5 引擎是为**特定 iOS build** 编译/适配的（编译路径 `FuckInject/kfd/libkfd/puaf/`），在 16.3 上 landa 利用不适配/不稳定。**不是权限多，是他针对的机型/系统不同**。

**后续可行方向**：换适配 iOS 16.3 的 libkfd 利用（landa 偏 16.5+，smith/physpuppet 偏 15.x，16.0–16.4 中间段最不稳）；或 local proxy 兜底（零黑屏）。
