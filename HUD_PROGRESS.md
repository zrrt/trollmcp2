# HUD 桌面悬浮 106 诊断与 libxpc 主线 · 进度快照

- 日期: 2026-10-07
- 状态: **根因已定案，方向已拍板 A(libxpc)，等待确证 launchctl 真系统位置后实现**

## 已确证（真机 exec_m grep / 读 / spawn）

1. **entitlements 完整保留（重签版）** —— 106 与 entitlements 无关，权限够 A 用：
   - `platform-application`=5、`com.apple.private.security.no-sandbox`=4、`accessibility-window-hosting`=2、`get-task-allow`=5
   - `com.apple.private.persona-mgmt` **有**（对照 TrollSpeed，persona 提权 entitlement 不缺）
   - `com.apple.private.xpc.launchd.job-manager` **有**、`com.apple.private.launchd.job-submission` **有** → **libxpc 直接向 launchd 提交 job 的关键 entitlement 已具备**

2. **launchctl 对 App 不可用**：
   - hud.log：App spawn `/usr/bin/launchctl` → `errno=2 (ENOENT)`
   - exec_m：`/usr/bin /usr/sbin /bin /sbin /usr/libexec` 逐路径 `ls -la /…/launchctl` 全部 `No such file`

3. **posix_spawn persona 99 提权失败 -106**：
   - 失败行：`start FAIL: spawn errno=-106 out=[bin-setuid=0 proc-euid=501 persona_r=0 uid_r=0 gid_r=0]`
   - 关键：`persona attr 设置成功（set_persona_np/gid/uid 均返回 0）`，但 `posix_spawn` 本身返回 -106
   - 判断：**iOS 16 + TrollStore ldid 注入的 `platform-application` 不是「真 platform codesign」** → persona 提权被系统拒绝（已知限制，与 entitlements 是否注入无关）

4. `launchd` 在 `/sbin`（存在）

## 方向（A，用户已拍板）

**用私有 libxpc API 直接向 launchd 加载 daemon，绕过 launchctl CLI。**
关键 entitlement（launchd.job-manager / job-submission / persona-mgmt）已具备，路径可行。

## TrollSpeed 源码精读结论（research/TrollSpeed/）

- `sources/HUDHelper.mm`：主路径 `posix_spawn launchctl load`（越狱 JBROOT `/usr/bin/launchctl`），兜底 `posix_spawn 自身 -hud`（persona 99 提权）
- `supports/entitlements.plist`：有 `persona-mgmt`（我们也有且更多）
- 结论：**缺的不是 entitlements**；launchctl 不可用 + persona 提权受限 = iOS 16 + TrollStore 环境限制

## 下一步

1. 确证 launchctl 真系统位置（需 8790「危险工具授权」或手机 sshd）—— 若在系统某处 → 修 App 访问即可；若真无 → 上 libxpc
2. libxpc 实现：向 launchd 发私有 XPC job 提交消息（逆向 launchctl 协议，或抄 palera1n `in.palera.private.launchd-commands.client` 的实现）

## 当前阻塞点

- 手机 22 sshd 未监听（用户开的是 8790 App 远程终端，非系统 sshd）
- 8790「危险工具授权」未开 → exec_m 只读，无法确证 launchctl / sshd
- 待用户：开「危险工具授权」开关后，exec_m 即可跑 ps/netstat 确证
