import Foundation
import AVFoundation
import Combine

/// v4.4.19：Edge TTS 朗读服务（流水线预取版）。
/// - 走 Cloudflare Worker 中转 `tts.trollagent.cc.cd`（国内裸连可用）
/// - 夹子音：zh-CN-XiaoyiNeural + pitch +30Hz（用户选定）
/// - mp3 直接内存播放（AVAudioPlayer(data:)，不写文件 → 播完即丢）
/// - **流水线预取**：边播放当前句、边在后台合成下一句，句间无缝（实测串行每句干等 2-3s 会卡，预取消除空洞）
/// - 手动朗读(speakForced)打断当前自动朗读，只播指定文本
final class TTSService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = TTSService()

    @Published var speakerEnabled: Bool {
        didSet { UserDefaults.standard.set(speakerEnabled, forKey: "trollmcp2.tts_enabled") }
    }
    @Published var isSpeaking = false {
        didSet { if !isSpeaking { speakingId = nil } }
    }
    /// 当前手动朗读的消息 id（气泡喇叭高亮用；流式自动朗读不设）
    @Published var speakingId: String?

    private let baseURL = "https://tts.trollagent.cc.cd/tts"
    private let voice = "zh-CN-XiaoyiNeural"
    // v4.5.7：语速提升 +10%（rate）；磁性——夹子音基调下调音高(pitch +30Hz→+15Hz)让声音更醇厚
    private let pitch = "+15Hz"
    private let rate = "+10%"

    /// 待合成文本队列（有序，按句切分）
    private var pendingTexts: [String] = []
    /// 已合成好的 mp3 数据（有序，就绪即播）
    private var readyChunks: [Data] = []
    private var player: AVAudioPlayer?
    private var isSynthBusy = false

    private override init() {
        speakerEnabled = UserDefaults.standard.bool(forKey: "trollmcp2.tts_enabled")
        super.init()
    }

    // MARK: - 对外

    /// 自动朗读（受全局喇叭开关控制）：流式分句送进来，排队流水线播放
    func speak(_ text: String) {
        guard speakerEnabled else { return }
        enqueueSentences(cleanForSpeech(text))
    }

    /// 手动朗读（无视开关，打断当前自动朗读，只播这段）——整段已完整，一次合成后连续播完（实测100字3s/500字约6s，比逐句更快）
    func speakForced(id: String?, _ text: String) {
        stopInternal()
        let t = cleanForSpeech(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        speakingId = id
        isSynthBusy = true
        synthesize(t) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSynthBusy = false
                guard let data, data.count > 100 else { return }
                self.readyChunks.append(data)
                self.pump()
            }
        }
    }

    func stop() { stopInternal() }

    // MARK: - 队列

    private func enqueueSentences(_ text: String) {
        for s in splitSentences(text) where !s.isEmpty { pendingTexts.append(s) }
        pump()
    }

    private func stopInternal() {
        pendingTexts.removeAll()
        readyChunks.removeAll()
        player?.stop()
        player = nil
        isSynthBusy = false
        isSpeaking = false
    }

    /// 主泵：确保①有就绪 mp3 就播放；②合成器空闲且有待合成文本就预取下一个（边播边合成，流水线）
    private func pump() {
        // ① 播放就绪的下一句（player 为 nil 表示上一句播完或尚未开播）
        if player == nil, !readyChunks.isEmpty {
            let data = readyChunks.removeFirst()
            startPlay(data)
        } else if player == nil {
            isSpeaking = false   // 没有就绪也没在播 → 整段播完（结束朗读）
        }
        // ② 合成器空闲则预取下一个（这句合成期间，当前句正在播放 → 句间无缝）
        if !isSynthBusy, !pendingTexts.isEmpty {
            let text = pendingTexts.removeFirst()
            isSynthBusy = true
            synthesize(text) { [weak self] data in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSynthBusy = false
                    if let data, data.count > 100 { self.readyChunks.append(data) }
                    self.pump()   // 合成完再泵：播就绪的 + 继续预取
                }
            }
        }
    }

    private func startPlay(_ data: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            isSpeaking = true
            p.play()
        } catch {
            player = nil
            pump()   // 播放失败，跳过继续下一个
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        pump()   // 播完 → 播下一句（已预取）+ 继续预取再下一句
    }

    // MARK: - 合成

    private func synthesize(_ text: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: baseURL) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 40
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "voice": voice, "pitch": pitch, "rate": rate])
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard err == nil, let data, data.count > 100 else { completion(nil); return }
            completion(data)
        }.resume()
    }

    /// 按中文/英文句末标点与换行切分
    func splitSentences(_ t: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in t {
            current.append(ch)
            if "。！？!?\n…".contains(ch) {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { result.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// 朗读前清洗：去掉 markdown 标记/链接/括号/星号/竖线等格式符号，只留文字（避免 Edge TTS 把 * - （） # 等读出来）
    private func cleanForSpeech(_ t: String) -> String {
        var s = t
        // 行内代码/反引号
        s = s.replacingOccurrences(of: "`", with: "")
        // 链接 [text](url) → text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // 行首 markdown 标记（标题#/列表-*/引用>）
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*[#>*+-][ \t]*"#, with: "", options: .regularExpression)
        // 表格分隔行 |---| 整行去掉
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#, with: "", options: .regularExpression)
        // 残留星号/下划线/井号
        s = s.replacingOccurrences(of: #"[*_]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "#", with: "")
        // 表格竖线（保留单元格内容）
        s = s.replacingOccurrences(of: "|", with: "")
        // 括号符号本身去掉（保留内部文字），中英括号都处理
        s = s.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        s = s.replacingOccurrences(of: "（", with: "").replacingOccurrences(of: "）", with: "")
        // 数学符号转读法
        s = s.replacingOccurrences(of: "×", with: "乘").replacingOccurrences(of: "÷", with: "除以")
        // 压缩连续空白与空行
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
