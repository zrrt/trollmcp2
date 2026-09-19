# TODO 总览

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

### 待做：
- [ ] 设计终端工具的安全策略（白名单/黑名单/二次确认）
- [ ] 内置轻量小工具（unzip/tar/curl/grep/sed/awk，加起来 <5MB）
- [ ] 加输出截断（防止输出太多撑爆上下文）
- [ ] 加超时机制（防止命令卡死）
- [ ] 首次用终端时，弹窗问用户是否下载完整工具链（Theos + clang + llvm）
- [ ] 完整工具链按需下载，不内置，不占 App 体积
- [ ] 下载到工作区目录，用完可以删
- [ ] 加危险命令二次确认（rm/mv/chmod 改系统）
- [ ] 测试沙箱限制，看哪些系统命令能用

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

## 八、Python IDE（用户需求）🐍

**用户需求：** 有人想要 Python IDE，在手机上写 Python 代码跑。

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

