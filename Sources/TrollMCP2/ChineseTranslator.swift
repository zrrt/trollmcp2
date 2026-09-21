import Foundation
import NaturalLanguage

// MARK: - 中文→英文翻译器
// 把中文查询翻译成英文，用来做 embedding 搜索工具

final class ChineseTranslator {
    static let shared = ChineseTranslator()

    private var translator: NLTranslator?
    private var isReady = false

    private init() {
        setupTranslator()
    }

    private func setupTranslator() {
        // 中文（简体）→ 英文
        guard let translator = NLTranslator(from: .simplifiedChinese, to: .english) else {
            print("⚠️ ChineseTranslator: failed to create translator")
            return
        }

        // 检查翻译模型是否可用
        translator.requestAssets { [weak self] error in
            if let error = error {
                print("⚠️ ChineseTranslator: failed to download assets: \(error)")
                return
            }
            DispatchQueue.main.async {
                self?.isReady = true
                self?.translator = translator
                print("✅ ChineseTranslator: ready")
            }
        }
    }

    /// 把中文翻译成英文（同步，简单版）
    func translate(_ text: String) -> String {
        guard isReady, let translator = translator else {
            // 翻译模型还没准备好，直接返回原文
            return text
        }

        do {
            let result = try translator.translate(text)
            print("📝 Translate: \(text.prefix(50)) → \(result.prefix(50))")
            return result
        } catch {
            print("⚠️ Translate failed: \(error)")
            return text
        }
    }

    /// 翻译模型是否就绪
    var ready: Bool {
        return isReady
    }
}
