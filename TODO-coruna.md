# TODO: Coruna 漏洞利用链集成

## 目标
把 Coruna 漏洞利用链集成到 TrollAgent，实现网页端一键注入 dylib 到任意 App。

## 漏洞利用链（已公开）
1. **Stage 1 - WebKit 漏洞**：CVE-2024-23222 类型混淆，JIT spraying
2. **Stage 2 - PAC 绕过**：arm64e PAC 签名/认证
3. **Shellcode loader**：mini dyld，加载 Mach-O
4. **内核漏洞利用**：IOSurface 漏洞，内核任意读写
5. **PPL 绕过**：GPU 命令写入物理内存
6. **AMFI patch**：启用 Developer Mode + Security Research Mode

## 参考资源
- coruna.app/demo - 网页端 demo
- matteyeux.com - 技术分析文章
- GitHub: matteyeux/Coruna dump - 28 个 JavaScript 模块 + shellcode + 内核 exploit

## 工作量
- [ ] 下载 dump 文件
- [ ] 反混淆 JavaScript 代码（1250+ 加密字符串，64 个 XOR 密钥）
- [ ] 重新构建完整利用链
- [ ] 写自己的 payload（注入任意 dylib）
- [ ] 在 iOS 16.3 上测试稳定性

## 预计时间
2-3 周

## 当前状态
- v3.0.3: 已做 Coruna 安全盾（检测恶意网站）
- 待做: 集成完整利用链
