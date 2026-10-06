import Foundation
import AVFoundation
import Combine

/// v4.4.18：Edge TTS 朗读服务。
/// - 走 Cloudflare Worker 中转 `tts.trollagent.cc.cd`（国内裸连可用，绕开 workers.dev 被墙）
/// - 夹子音：zh-CN-XiaoyiNeural + pitch +30Hz（用户选定）
/// - mp3 直接内存播放（AVAudioPlayer(data:)，不写文件 → 播完即丢，满足"不落地存储"）
/// - 长文本按句切分排队逐句合成播放
/// - 全局喇叭开关（右上角），持久化到 UserDefaults
final class TTSService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = TTSService()

    @Published var speakerEnabled: Bool {
        didSet { UserDefaults.standard.set(speakerEnabled, forKey: "trollmcp2.tts_enabled") }
    }
    /// 是否正在播放（UI 用来切换喇叭图标）
    @Published var isSpeaking = false

    private let baseURL = "https://tts.trollagent.cc.cd/tts"
    private let voice = "zh-CN-XiaoyiNeural"
    private let pitch = "+30Hz"

    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var playingText = false

    private override init() {
        speakerEnabled = UserDefaults.standard.bool(forKey: "trollmcp2.tts_enabled")
        super.init()
    }

    /// 朗读一段文本（内部按句切分排队）。受全局喇叭开关控制。
    func speak(_ text: String) {
        guard speakerEnabled else { return }
        let sentences = splitSentences(text)
        for s in sentences where !s.isEmpty { queue.append(s) }
        drainIfNeeded()
    }

    /// 手动朗读（无视喇叭开关——用户主动点喇叭就是想听）
    func speakForced(_ text: String) {
        for s in splitSentences(text) where !s.isEmpty { queue.append(s) }
        drainIfNeeded()
    }

    /// 停止并清空队列
    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        playingText = false
        isSpeaking = false
    }

    // MARK: - 队列

    private func drainIfNeeded() {
        guard !playingText, player?.isPlaying != true, !queue.isEmpty else { return }
        playNext()
    }

    private func playNext() {
        guard !queue.isEmpty else { isSpeaking = false; playingText = false; return }
        let text = queue.removeFirst()
        playingText = true
        isSpeaking = true
        synthesize(text) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, data.count > 100 else { self.next(); return }
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                    try AVAudioSession.sharedInstance().setActive(true)
                    let p = try AVAudioPlayer(data: data)
                    p.delegate = self
                    self.player = p
                    p.play()
                } catch {
                    self.next()
                }
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        next()
    }

    private func next() {
        playingText = false
        player = nil
        if queue.isEmpty { isSpeaking = false }
        else { playNext() }
    }

    // MARK: - 合成

    private func synthesize(_ text: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: baseURL) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 40
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "voice": voice, "pitch": pitch])
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard err == nil, let data, data.count > 100 else { completion(nil); return }
            completion(data)
        }.resume()
    }

    /// 按中文/英文句末标点与换行切分，保留标点在句中
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
}
