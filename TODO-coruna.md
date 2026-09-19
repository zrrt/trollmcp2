# TODO: Coruna 漏洞利用链集成

## 目标
把 Coruna 漏洞利用链集成到 TrollAgent，实现网页端一键注入 dylib 到任意 App。

## 漏洞利用链（已公开）
1. **Stage 1 - WebKit 漏洞**：CVE-2024-23222 类型混淆，JIT spraying
2. **Stage 2 - PAC 绕过**：arm64e PAC 签名/认证
3. **Shellcode loader**：mini dyld，加载 Mach-O
4. **内核漏洞利用**：IOSurface 漏洞 (CVE-2023-41974)，内核任意读写
5. **PPL 绕过**：GPU 命令写入物理内存
6. **AMFI patch**：启用 Developer Mode + Security Research Mode

## 参考资源
- coruna.app/demo - 网页端 demo
- matteyeux.com - 技术分析文章
- GitHub: Rat5ak/CORUNA_IOS-MACOS_FULL_DUMP - 28 个 JavaScript 模块 + shellcode + 内核 exploit

## 完成情况 ✅

### 已完成
- [x] 下载 dump 文件（5MB，107 个文件）
- [x] 技术研究：完整漏洞链逆向分析
- [x] 设计集成方案（详见 CORUNA_INTEGRATION.md）
- [x] 实现 CorunaWebInjector 核心模块（状态机 + WebView 管理）
- [x] 实现 CorunaInjectView 用户界面（进度可视化 + 目标选择）
- [x] 集成到 SettingsView 入口
- [x] 打包 Coruna 资源到 App Bundle

### 待测试
- [ ] 在 iOS 16.3 iPhone 13 Pro Max 上编译构建
- [ ] 测试 WebKit RCE 路径触发
- [ ] 测试 PAC 绕过 + 沙盒逃逸
- [ ] 测试内核 exploit 稳定性
- [ ] 验证 dylib 注入功能

## 交付物
- `Sources/TrollMCP2/CorunaWebInjector.swift` - 核心管理器 (14KB)
- `Sources/TrollMCP2/CorunaInjectView.swift` - 用户界面 (16KB)
- `Resources/coruna/coruna-dump/` - 完整 exploit 资源 (5MB)
- `CORUNA_INTEGRATION.md` - 技术集成文档

## 版本
v3.0.5 - Coruna Web 注入功能集成
