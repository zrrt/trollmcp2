import Foundation
import Vision
import UIKit

// MARK: - v3.0.72：ocr.image — iOS Vision 框架识别图片文字

final class OCRImageTool: MCPTool {
    let definition = ToolDefinition(
        name: "ocr.image",
        summary: "Extract text from an image using iOS Vision framework. 识别图片文字 OCR 识图. Use when: (1) read text from a screenshot, (2) extract labels/numbers from an image, (3) OCR without AI vision.",
        parameters: [
            "path": "Absolute path to image file (PNG/JPG) (REQUIRED)",
            "lang": "Language hint: zh (Chinese, default) / en (English) / ja (Japanese) (optional)"
        ],
        verified: true,
        category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.failed("image not found: \(path)")
        }
        guard let image = UIImage(contentsOfFile: path),
              let cgImage = image.cgImage else {
            throw MCPError.failed("cannot load image: \(path)")
        }

        let lang = (params["lang"] as? String) ?? "zh"
        var languages = ["zh-Hans", "en-US"]
        if lang == "en" { languages = ["en-US"] }
        else if lang == "ja" { languages = ["ja-JP"] }

        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = languages
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw MCPError.failed("OCR failed: \(error.localizedDescription)")
        }

        guard let observations = request.results as? [VNRecognizedTextObservation] else {
            return ["text": "", "count": 0]
        }

        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let fullText = lines.joined(separator: "\n")

        return [
            "text": fullText,
            "count": lines.count,
            "path": path,
            "lines": lines
        ]
    }
}
