import Speech
import AVFoundation
import Combine

/// v4.5.0：小女孩语音输入（STT）——SFSpeechRecognizer 在线识别。
/// - 权限：麦克风 + 语音识别（Info.plist 已声明）
/// - 录音：AVAudioEngine inputNode tap → SFSpeechAudioBufferRecognitionRequest
/// - 静音自动结束：2.5s 无新语音即 finalize，拿到最终文本
/// - 识别文本通过 onFinalText 回调发出（供小女孩发 AI）
final class GirlVoice: NSObject, ObservableObject {
    static let shared = GirlVoice()

    @Published var isListening = false
    @Published var isReady = false       // 权限已就绪
    @Published var partialText = ""      // 实时中间结果

    /// 识别出最终文本的回调（一次性）
    var onFinalText: ((String) -> Void)?
    /// 权限申请失败的提示回调
    var onPermissionDenied: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var silenceTimer: Timer?
    private var lastWordTime: Date = .init()
    private let silenceTimeout: TimeInterval = 2.5

    private override init() {
        super.init()
        recognizer?.delegate = self
    }

    // MARK: - 对外

    /// 开始听（录音 + 识别）。权限未就绪会自动申请。
    func start() {
        guard !isListening else { return }
        ensurePermission { [weak self] ok in
            guard let self, ok else {
                self?.onPermissionDenied?()
                return
            }
            DispatchQueue.main.async { self.beginRecording() }
        }
    }

    /// 手动停止（发当前已识别的文本）
    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        finishRecognition()
    }

    // MARK: - 权限

    private func ensurePermission(_ completion: @escaping (Bool) -> Void) {
        // 语音识别授权
        let sttStatus = SFSpeechRecognizer.authorizationStatus()
        // 麦克风授权
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        let needStt = sttStatus != .authorized
        let needMic = micStatus != .granted

        if !needStt && !needMic {
            isReady = true
            completion(true)
            return
        }

        var remaining = (needStt ? 1 : 0) + (needMic ? 1 : 0)
        var granted = true

        if needStt {
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    if status != .authorized { granted = false }
                    remaining -= 1
                    if remaining == 0 {
                        self.isReady = granted
                        completion(granted)
                    }
                }
            }
        }
        if needMic {
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                DispatchQueue.main.async {
                    if !ok { granted = false }
                    remaining -= 1
                    if remaining == 0 {
                        self.isReady = granted
                        completion(granted)
                    }
                }
            }
        }
    }

    // MARK: - 录音与识别

    private func beginRecording() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            onPermissionDenied?()
            return
        }

        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request else { return }
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) { request.addsPunctuation = false }

        guard let recognizer, recognizer.isAvailable else { return }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                    // 有语音 → 重置静音计时
                    if result.bestTranscription.segments.count > 0 {
                        self.lastWordTime = Date()
                    }
                    if result.isFinal {
                        self.sendFinal(result.bestTranscription.formattedString)
                    }
                }
                if error != nil {
                    self.stopAndFlush()
                }
            }
        }

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            isListening = true
            partialText = ""
            lastWordTime = Date()
            startSilenceTimer()
        } catch {
            stopAndFlush()
        }
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isListening else { return }
            if Date().timeIntervalSince(self.lastWordTime) > self.silenceTimeout {
                // 静音超时 → 结束并发送
                self.finishRecognition()
            }
        }
    }

    private func sendFinal(_ text: String) {
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        partialText = ""
        if !t.isEmpty {
            onFinalText?(t)
        }
    }

    private func finishRecognition() {
        guard isListening else { return }
        if let result = task?.result, !result.bestTranscription.formattedString.isEmpty {
            sendFinal(result.bestTranscription.formattedString)
        } else {
            sendFinal(partialText)
        }
    }

    private func stopAndFlush() {
        finishRecognition()
    }
}

extension GirlVoice: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        // 可用性变化——不可用时停止
        if !available {
            DispatchQueue.main.async { self.stopAndFlush() }
        }
    }
}
