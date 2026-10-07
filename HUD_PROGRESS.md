# HUD 桌面悬浮 106 → 方案 B(TheBall) · 进度快照

- 日期: 2026-10-07
- 状态: **方向已改拍板 B(TheBall 方案)，放弃 A(libxpc)。下一步逆向 TheBall 悬浮窗窗口 API 后实现**

## 已确证(真机 exec_m)

1. entitlements 完整：platform-application=5 / no-sandbox=4 / accessibility-window-hosting=2 / get-task-allow=5 / persona-mgmt / launchd.job-manager / launchd.job-submission —— **权限够，106 与 entitlements 无关**
2. launchctl 对 App 不可用：spawn ENOENT + /usr/bin /usr/sbin /bin /sbin /usr/libexec 全部 No such file；launchd 在 /sbin(存在)
3. posix_spawn persona 99 -106：persona attr 设置成功(返回0) 但 spawn -106 = **iOS 16 + ldid 注入 platform-application 非真 platform codesign → 提权被拒**(已知限制)
4. 手机无 OpenSSH(/usr/sbin/sshd 不存在)；用户开的只是 8790 App 远程终端，真系统 shell 不可达

## 方向变更：放弃 A(libxpc)，改走 B(TheBall 方案)

**根因定论**：之前 106 = 试图"拉起独立 HUD 进程"(要 launchd/root，这台 iOS 16 都不给)。**正确做法 = 主 App 内悬浮窗 + 后台保活，不拉独立进程、不碰 launchd/root/libxpc。**

## TheBall 逆向结论(research/TheBall，hhse/TheBall 闭源 ipa)

- 主 App 内 `FloatingContentViewController` + `floatingWindow`(高 windowLevel) 显示悬浮窗
- 盖到桌面 = **accessibility 窗口托管**(AssistiveTouch 式)：`com.apple.springboard.accessibility-window-hosting` + `com.apple.accessibility.physicalinteraction.client` + `com.apple.assistivetouch.daemon` + AXEventRepresentation
- 后台保活 = `UIBackgroundModes: processing` + `beginBackgroundTask`(后台不死、锁屏可用)
- **launchd: 0 / job-manager: 0** —— 完全不碰 launchd/root
- **我们也有 accessibility-window-hosting entitlement → 这条路可行**

## 下一步

1. 逆向 TheBall 悬浮窗窗口创建 API(accessibility 托管 + windowLevel 具体怎么调)
2. 抄实现进 TrollAgent：主 App 内创建 accessibility 托管悬浮窗 + 加 UIBackgroundModes processing 保活
3. 推版真机测

## 参考资源

- TheBall 源码/ipa: `research/TheBall/`(1.6–2.7.ipa 已解包 2.7，主可执行"后台不死是"已逆向出机制)
- TrollSpeed 参考(launchctl/persona 路线，已确认此机不可行): `research/TrollSpeed/`
- 仓库: zrrt/trollmcp2 main
