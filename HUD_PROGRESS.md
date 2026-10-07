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

## 2026-10-07 晚更新（方案 B Step 1 成功 + Step 2 定方向）

### Step 1 已验证成功（真机 hud.log + ps）
- HUD 拉起改**不提权 posix_spawn**（spawn 而非 spawnRoot persona 99）→ **errno 106 彻底避开**
- hud.log: `start OK (posix_spawn 不提权, mobile)`
- ps 看到 HUD 进程被拉起（PID, 父进程 1）

### HUD 起来但桌面没显示
- 今天(10-07)无崩溃日志(.ips)；ps 只有主 App 进程 → **HUD -hud 进程起来后退出了**
- 根因：`HUDMainStart()`(HUD/sources/HUDApp.mm) 用 **TrollSpeed 插件模式**：
  `GSInitialize + BKSDisplayServicesStart + UIApplicationInitialize + __completeAndRunAsPlugin + HUDMainApplication 私有事件接管(反汇编 _run)`
  ——**这套依赖 root persona，mobile 不提权下跑不动(退出)**

### Step 2 方向
- **重构 HUDMainStart**：从插件模式 → **普通 UIApplication + 高 windowLevel accessibility 全局窗口**(TheBall 方式, mobile 可行)
- HUD/sources 有 HUDMainApplication.mm(142)/HUDMainWindow.mm(19)/HUDRootViewController.mm 需重构窗口机制
- 工作量大，需多轮改+测

### 待解
- TheBall 悬浮球进程 uid 未确证(装 TheBall 到手机 ps 可测)；但 mobile + accessibility 全局窗口确定性成立(已从 TheBall 逆向确认机制)
