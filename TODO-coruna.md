# TODO 总览

---

## 🚀 当前版本进度（v3.0.36）
- ✅ 工具标签打完 174 个（排除注入类7+bug6+危险3）
- ✅ 版本号对齐 v3.0.36（Support/Info.plist 递增，CI 不再覆盖 RELEASE_VERSION）
- ✅ 集成 ios_system（dlopen 动态加载，扁平 framework，只留 arm64）
- ✅ 修复 ldid 签名错误（删掉 simulator/maccatalyst/dSYM）
- ❌ **v3.0.32 shell.exec 实测：全部卡死**（远程直连 121.31.137.51:18790 实测 echo/pwd 均超时无返回）
  - 根因1（死锁）：v3.0.32 把 C 风格 pipe 改成 Foundation Pipe 时没关写端句柄，readDataToEndOfFile 永远等不到 EOF → 已修复（v3.0.33）
  - 根因2（命令找不到）：缺 commandDictionary.plist 命令表 + 同伴框架 → v3.0.33 实测 echo/pwd/ls 全 127 command not found → v3.0.34 打包命令表 + 扁平框架（ios_system/files/shell/text/tar/awk，60 命令），库名改 @executable_path 定位 → 实测 echo/ls/cd/管道/cat/tar/退出码全部正常
  - 根因3（卡死命令拖垮整机）：v3.0.34 实测 ls/cd/cat 访问 /private/var/containers/Bundle/Application（App bundle 挂载点）会阻塞 ~2 分钟且持有 ios_system 命令锁，整个远程终端不可用；in-process 执行 + ios_kill 无法回收阻塞 syscall → v3.0.35 改为 posix_spawn 独立 ShellHelper 子进程执行命令，超时 SIGKILL 进程组，主进程永不卡死；helper 回报最终 cwd 保留 cd 会话记忆
  - 根因4（会话 cwd 被 ~ 前缀污染）：v3.0.35 实测所有命令 exit 3——invoke 用 pwd 探测结果(~ 前缀显示值)覆盖会话目录，helper chdir("~/...") 失败 → v3.0.36 去掉 pwd 探测、只用 helper 报告的真实绝对路径，并对非 / 开头 cwd 做归一化；另加 shell-diag.log 诊断日志 + 超时 exit 137
- ✅ **v3.0.36 真机回归全绿（2026-09-20 13:1x）**：echo/pwd/ls exit 0 秒回；cd 会话记忆跨调用保留；管道 echo|cat 正常；cat /etc/hosts 正常；重定向写读正常；tar 打包 exit 0；失败命令返回真实退出码（ls 不存在→1）；危险拦截正常（rm -rf /、dd if= 均被拒）；**死循环 awk(timeout=4)→4.1s 返回 exit 137 timed_out=true，且下一条命令立即正常执行（卡死回收成功，不再拖垮终端）**；shell-diag.log 正常生成（逐条 exec start/spawned/end 记录）
  - ⚠️ 本轮测试最大坑：**测试脚本 python urllib 默认走沙箱代理导致所有 POST 超时**，误判为 App 挂起——必须禁代理（ProxyHandler({}) 或 curl --noproxy "*"）再测
  - ⚠️ 遗留小项：tar -tf 列表输出为空（exit 0）；head/which/false 不在 60 命令表（command not found）；$APPDIR/bin/ldid -h 报 command not found（PATH 已含 bin、文件在，待查 ios_system 外部二进制查找逻辑）；App 测试期偶发被 iOS 重启（device.probe 时间戳推进，无信号崩溃记录）
- 🔧 已知未实测 bug：pidOf 找不到进程、ldid entitlements 解析错、GitHub 授权轮询不更新、phone.call 改 telprompt 未实测
- 📝 待办：**iSH 替换 ios_system ✅（v3.0.41 已交付，ios_system 全删）**；curl/network_ios/Python/SSH/clang ✅（iSH 落地后 apk 直接解决）；剩余：待修 Bug×4、远程截图定时清理、备份功能、稳定性、工具说明优化

---

## 一、Coruna 漏洞利用链集成（大项目）

### 已完成
- [x] 下载 dump 文件（5MB，107 个文件）
- [x] 技术研究：完整漏洞链逆向分析
- [x] 设计集成方案
- [x] 实现 CorunaWebInjector 核心模块
- [x] 实现 CorunaInjectView 用户界面
- [x] 集成到 SettingsView 入口
- [x] 打包 Coruna 资源到 App Bundle

### 待开发 - 补全核心运行时模块 🔴
**问题：** 公开 dump 缺少两个核心模块，完整利用链跑不通。

| 缺失模块 | Hash | 作用 |
|---------|------|------|
| 原语库 | `1ff010bb...` | 内存读写原语 |
| 工具库 | `6b57ca33...` | 漏洞引擎对象 |

**需要做的：**
1. 从已有 28 个模块反推这两个模块的接口签名
2. 重新实现内存读写原语
3. 绕过 PAC/指针认证（arm64e）
4. 从用户态写到内核态
5. 写 Mach-O loader 注入 dylib 并执行

**工作量：** 2-3 周，需要 iOS 内核漏洞知识
**当前状态：** 演示版（能加载模块、显示进度，最后一步报错）

---

## 二、工具优化

### 工具打标签（进行中）
- [x] 打标签规则：成功的打 verified: true，有 bug 的不打，危险不测的不打
- [x] 总工具数 195 个
- [x] 已打标签 ~180 个
- [x] 有 bug 不打标签：注入类7个 + ldid解析2个 + phone.call 1个 = 10个
- [x] 危险不测的不打：memory / container.write_text / bridge.import = 3个
- [ ] 剩下的标签后续慢慢补

### 工具列表精简
- [ ] 工具按类别分组（应用管理/注入/文件/控制/清理...），AI 更容易找
- [ ] 每个工具加"什么时候用"的说明
- [ ] 减少相似工具数量，AI 不用在多个相似工具里纠结
- [ ] 再检查一遍危险工具，有就去掉或加二次确认

### 工具说明优化
- [ ] 工具说明简化 + 改成英文（AI 理解更好，省 token）
- [ ] 拆分大工具（比如 cleanup.ai 拆成 cleanup.safe / cleanup.full）
- [ ] 截图工具直接返回 base64，AI 直接看图，不用读文件

### 系统提示词更新（过时了）
- [ ] 去掉 gateway 相关内容（工具已经删了）
- [ ] 去掉本机环境检测相关内容（设置里已经去掉了）
- [ ] 加入 Coruna 安全盾功能说明
- [ ] 加入清理中心新功能说明
- [ ] 更新工具列表，去掉已经删掉的工具
- [ ] 更新已知 bug 列表（pidOf / ldid 解析等），让 AI 避开有问题的工具
- [ ] 更新版本号，对齐 v3.0.x

---

## 三、清理功能

### workspace.cleanup 补充
- [x] 把 `privateWorkspace/control_shots/`（控制截图）加入清理目标
- [x] 把 `Workspace/screenshots/` 也加入清理
- 现在只清 logs / reports / downloads / network_capture

### 智能自动清理
- [ ] AI 自动判断哪些文件可以清
- [ ] 定时自动清理（比如每天一次）
- [ ] 截图只保留最近 N 张（比如 5 张）
- [ ] 远程控制 AI 识图后，过 X 分钟自动删截图
- [ ] 按类型/大小/年龄自动清理

---

## 四、内存/注入

### 直接跨进程读写内存
- [ ] 现在 task_for_pid 能成功，但 task_info(TASK_DYLD_INFO) 恒 kr=4
- [ ] 研究 TrollDecrypt 在同样环境下为什么能成功
- [ ] 修复跨进程读镜像表问题
- [ ] 实现直接读写目标进程内存，不用注入 dylib
- [ ] 如果能做好，就可以去掉 MemoryTweak（h5gg）dylib

### 内置 SSH 客户端
- [ ] 编译 OpenSSH for iOS（ssh + scp）
- [ ] 打包到 App 的 bin 目录
- [ ] 测试 ssh.exec / ssh.scp 工具
- 预计大小：~2 MB

---

## 五、备份功能

### 已有
- [x] 注入前自动备份二进制（.troll-fools.bak）
- [x] 文件编辑前自动备份（.bak）
- [x] 清容器前自动备份（.trollagent.bak）
- [x] 一键恢复（injection.restore / device.restore）

### 待补充
- [ ] 整个 App 数据打包备份（游戏存档、聊天记录）
- [ ] 钥匙串/登录态备份
- [ ] 设备伪装配置备份
- [ ] 一键新机前整体备份

---

## 六、稳定性 & 体验

- [ ] 崩溃自动恢复：注入闪退自动检测 → 自动回滚 → 提示用户
- [ ] 远程控制稳定性：断连自动重连；网络不好自动重试；操作超时自动取消
- [ ] 思考模式 UI：工具调用气泡显示 AI 思考过程（还没完全做好）
- [ ] 性能优化：启动速度更快；工具调用响应更快；内存占用更少

---

## 待修 Bug（4 个）

1. **pidOf 找不到进程（高优先级）** - 影响 device.fake / injection.mem 等所有需要找进程的工具
2. **ldid entitlements 解析失败（中优先级）** - 影响 app.entitlements / device.keychain_wipe
3. **GitHub 设备授权轮询不更新（中优先级）** - 用户网页端点授权后，App 端一直卡"等待授权..."
4. **phone.call 没反应（低优先级）** - 返回 opened: true 但实际没弹拨号器

---

## 七、内置终端功能（新想法）💡

**想法来源：** 用户反馈说本来就这么高权限，不如加个终端让 AI 直接执行命令。

### 功能描述：
- 加一个通用 shell 终端工具，AI 可以直接执行任意命令
- 内置常用命令：unzip, tar, curl, grep, ldid, optool, insert_dylib, Theos, clang
- 支持本地打包编译 tweak/dylib，不用 GitHub Actions 等
- 支持调用系统里的越狱插件命令（NewTerm3 风格）

### 待做（iSH 落地后大部分已解决）：
- [x] 设计终端工具的安全策略（白名单/黑名单/二次确认）——已有危险命令拦截
- [x] 内置轻量小工具（unzip/tar/curl/grep/sed/awk）——Alpine 全套内置
- [x] 加输出截断——2000 字符截断已有
- [x] 加超时机制——timeout+SIGTERM/SIGKILL 回收已有
- [x] 危险命令二次确认——拦截已有
- [ ] 首次用终端时，弹窗问用户是否下载完整工具链（Theos + clang + llvm）
- [ ] 首次用终端时，弹窗问用户是否下载完整工具链（Theos + clang + llvm）
- [ ] 完整工具链按需下载，不内置，不占 App 体积
- [ ] 下载到工作区目录，用完可以删
- [x] 测试沙箱限制——fakefs 隔离，guest 内全可用

### 核心用途（不是用来编译的）：
**解包逆向分析才是终端的正确用法！**
- ✅ 解包 IPA/deb/tar.gz：unzip, dpkg-deb, tar
- ✅ 逆向分析：otool -l（看加密）、otool -L（看依赖）、strings（搜字符串）、lipo -info（看架构）
- ✅ 文件操作：find, grep, du, df, ls 等
- ✅ 轻量操作，瞬间出结果，完全不卡不发热
- ❌ 编译大项目还是用 GitHub Actions，手机上别硬刚

### 风险：
- AI 执行危险命令搞坏系统
- 输出太多把上下文撑爆
- 命令卡死导致 App 无响应


---

## 八、Python IDE（用户需求）🐍 —— ✅ 已由 iSH 解决（2026-09-20）

**用户需求：** 有人想要 Python IDE，在手机上写 Python 代码跑。
**结论：** iSH 引擎落地后 `apk add python3 py3-pip` 直接内建 Python 3.12，shell.exec 一条命令跑任意脚本（已验证：urllib 外网通）；**独立的 python.exec 工具与 IDE UI 砍掉**（用户拍板，shell.exec 已覆盖，不做冗余工具）。

### 功能描述：
- 内置 Python3 解释器（轻量版，~10MB）
- 代码编辑器（语法高亮 + 自动缩进）
- 一键运行，直接看输出
- AI 能直接写 Python 脚本跑（和 shell.exec 类似）
- 支持常用库（os / re / json / requests 等）

### 待做：
- [ ] 内置 Python3 解释器二进制（编译 iOS arm64 版）
- [ ] 加 Python 代码编辑器 UI（语法高亮 + 自动缩进）
- [ ] 加 python.exec 工具，AI 直接跑 Python 代码
- [ ] 支持常用第三方库（requests / numpy 等，按需下载）
- [ ] 调试功能（断点 / 变量查看）
- [ ] 保存/加载 Python 脚本

### 风险：
- Python 解释器体积大（~10MB+）
- 第三方库更占空间
- iOS 沙箱限制，有些库跑不了


---

## 九、终端引擎升级：iSH 替换 ios_system 🔄 —— ✅ 全部完成（v3.0.41 已交付）

**决策（2026-09-20）**：评估 OpenMinis 的 iSH-ARM64 集成方案后确认——iSH 可用后 ios_system 无不可替代价值，**验证通过直接全删，不留双引擎**（git 历史保留可找回）。

### 为什么换
| 痛点（现状 ios_system） | iSH 解决方式 |
|---|---|
| 60 命令限制，缺这缺那 | 完整 Alpine Linux，`apk add` 装任何包 |
| 外部 Mach-O 不能 exec（ldid 127） | Linux 二进制随便跑（guest 内） |
| curl 缺 libssh2/openssl 未集成 | Alpine 自带 |
| 危险命令靠正则拦截 | fakefs 沙箱天然隔离（rm -rf / 不伤真机） |

### 参考实现（OpenMinis，已生产验证 10000+ 用户）
- 引擎：`https://github.com/OpenMinis/ish-arm64`（feature-arm64 分支，aarch64 同架构模拟，不生成机器码、无需 JIT entitlement，iOS 14+）
- 集成文档：`OpenMinis/OpenMinis` 仓库 `deps/ISH_INTEGRATION.md`（526 行，静态库 + rootfs + ISHKernel + TTY）
- 执行器：`ISHShellExecutor.m`（1196 行：/bin/sh -c、行回调、退出码、killProcessGroup、finalizeTimedOutPid 防超时泄漏——与我们的死锁教训同款）
- 构建脚本：`deps/build_ish.sh`（libish/libish_emu/libfakefs 静态库）+ `deps/prepare_alpine_rootfs.sh`（Alpine aarch64 rootfs → fakefs 格式），本机无 Xcode 也能走我们自己的 GitHub Actions(macos-latest)
- 本地参考源码：`/home/user/Doubao/chats/38439081911741442/OpenMinis-src/`、`/home/user/Doubao/chats/38439081911741442/ish-arm64-src/`（持久目录，勿删）

### 执行步骤
1. **CI 验证性构建**：把 build_ish.sh + prepare_alpine_rootfs.sh 接进 workflow，确认静态库能编出来 + 体积（估算 tipa 从 ~10MB → ~35-45MB）
2. **iOS 工程集成**：libish.a×3 + 头文件 + rootfs.zip；移植 ISHKernel（boot：mount_root fakefs + become_first_process + 设备节点 + procfs + exit_hook）与 ShellExecutor（复用 OpenMinis 模式）
3. **shell.exec 切 iSH**：/bin/sh -c + 行回调 + 退出码；移植现有超时/危险拦截/cwd 会话/shell-diag.log 封装（架构不变，底层换 guest sh）
4. **真机回归**：v3.0.36 全套（echo/ls/cd 记忆/管道/tar/死循环超时回收）+ iSH 特有项（rootfs 首次解压、内核 boot、后台挂起、并发调用、大程序 python/node）
5. **全绿后删 ios_system**：Resources 里 ios_system/files/shell/text/tar/awk framework + commandDictionary.plist + ShellTool 的 IOSSystem.load 全删

### 风险与回退
- 最大不确定性：fork 构建脚本隐藏依赖 → 先做第 1 步试验
- iSH 内核常驻内存/后台挂起行为 → 真机验证
- 行为差异（busybox vs coreutils、模拟器 syscall 边角）→ 回归清单覆盖
- **唯一留 fallback 的情形**：iSH 构建/真机验证失败——那时再考虑双引擎过渡


## v3.0.42 完成（2026-09-20）
- [x] pidOf 改 libproc（dlopen /usr/lib/libproc.dylib，proc_listpids+proc_pidpath），ps 兜底——真机验证 pid=18453 命中
- [x] ldid entitlements 二进制 plist 解析（SpawnResult.rawStdout Data 通道 + runAsRootData + 两处解析点改造）——真机验证备忘录完整 entitlements
- [x] GitHub 设备授权轮询：网络错误/解析失败不再终止轮询（仅 access_denied/expired_token 等终止性错误停）
- [x] phone.call 号码清空 bug（components(separatedBy:) 把数字全删 → filter 保留）——真机验证 +8610086

## 注入全链路打通（v3.0.43~v3.0.57，2026-09-20 完成）
**最终成功方案（真机验证 iOS16.3 arm64e 豆包 pid 18453）**：
1. **opainject 重编 arm64**（Theos ARCHS=arm64，SDK16.5 软链 + stdint patch + CoreSymbolication 清除）——TrollStore arm64 进程 spawn 不再 EBADARCH
2. **tweaks dylib lipo -thin arm64**（去 arm64e slice——arm64e slice 的 adhoc 签名 iOS16 dyld 必报 invalid）
3. **签名 = ldid -S 伪签 + ct_bypass -r -i -t <目标App真实TeamID>**（CoreTrust 多签名者漏洞 CVE-2023-41991，TrollFools 同款）
   - **关键认知**：iOS16 dyld 拒绝一切普通 adhoc 签名 dylib（xerub/Procursus/TrollFools 版 ldid 全试过，errno=1）；只有 CoreTrust bypass 双签名者 blob 能骗过 amfid
   - **Team ID 必须 = 目标 App（豆包）的**（dyld 校验 dylib 与进程 Team ID 一致；ct_bypass 内置模板是 GTA Car Tracker 证书，Team ID 需现场提取）
   - **teamid 工具**（tools/teamid.c，CI clang 编译）：解析目标 App 二进制 CodeSignature → CodeDirectory（SuperBlob slot type=0 CSSLOT，**不是 blob magic**）→ teamOffset 字段
4. **验证结果**：device.fake 豆包 → `status: faked`；injection.mem → `status: injected`；dlopen succeeded；豆包进程存活未崩
- [x] device.fake / injection.mem 打 verified 标签（v3.0.58）
- [ ] iOS 15 真机回归（用户要求 15.0 必支持；链路依赖 iOS14.0 部署基线，理论覆盖但未实测）
- [ ] probe.inspect 全链路回归（注入通了，探测查询需再测）
- [ ] GitHub 授权（需用户浏览器实测）

## 仍开放
- [ ] 崩溃自动恢复：注入闪退自动检测 → 自动回滚 → 提示用户

## 2026-09-20 v3.0.61 更新
- [x] 改名 TrollAgent（显示名/包名 com.trollagent.app/URL scheme trollagent/keychain 组同步）
- [x] 注入类工具全量真机检测（二维码 App com.sawadaru.qr 为标准目标）：
  - ✅ device.fake（faked + dlopen succeeded）
  - ✅ injection.enable（静态注入 injected）→ ✅ injection.disable（reverted）→ ✅ injection.enable_persisted（restore ConfigHook）
  - ✅ injection.status（141 App 扫描） / injection.mem / injection.inspect / injection.list / control.inject（已打）
  - ✅ probe.inspect（正确响应 ProbeAgent 未就绪）/ hook.apply（applied）
  - 全部打 verified: true 标签
- [x] opainject 仓库二进制换 arm64（git 里原 arm64e 是 CI 失败 fallback 隐患 → EBADARCH 85 根因，v3.0.60 修复）
- [结论] 内存注入对无防护 App 通用（二维码成功）；大厂 App 有防护：
  - 豆包更新为 Grace.app 后注入失败（__LINKEDIT not found / 读内存失败）
  - 微信/闲鱼卡死（腾讯/阿里安全 SDK 反注入）
  - 系统 App（备忘录）无 Team ID 无法 ct_bypass
- [x] h5gg/MemoryTweak 可删：功能已被内存注入+ControlAgent dylib 覆盖（用户确认）
- [结论] 持久性：内存注入重启消失；静态注入（injection.enable）持久，非仅 h5gg
- [x] 设备端定时任务 test_cron（每日提醒/每天测试通知）已删除（automation.stop）
- [x] 发烫根因：闲鱼测试残留 opainject 卡死进程，重启清除
- [待办] DeepSeek 在 v3.0.60 后未重测（EBADARCH 已修，应用 arm64 opainject 重测）
- [待办] 设备端 AI 调用需用新包名 com.trollagent.app 重新授权/配对
