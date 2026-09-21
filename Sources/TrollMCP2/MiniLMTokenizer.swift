//
//  MiniLMTokenizer.swift
//  TrollMCP2
//
//  Created by Abhishek6353 on 03/12/25.
//  Adapted for TrollMCP2.
//
// BERT WordPiece tokenizer for all-MiniLM-L6-v2.
// Usage:
//   let tok = try MiniLMTokenizer(vocabFileName: "vocab.txt", maxSequenceLength: 512)
//   let out = tok.encode("帮我抓包")

import Foundation

public struct TokenizedOutput {
    public let inputIds: [Int]
    public let attentionMask: [Int]
    public let tokenTypeIds: [Int]
    public let tokens: [String]
}

public final class MiniLMTokenizer {
    private var tokenToId: [String: Int] = [:]
    private var idToToken: [Int: String] = [:]

    // common special tokens (may differ by vocab; we'll attempt to read from vocab and fallback)
    public var unkToken: String
    public var clsToken: String
    public var sepToken: String
    public var padToken: String
    public let maxSequenceLength: Int

    /// - Parameters:
    ///   - vocabFileName: the filename of vocab inside the app bundle (e.g. "vocab.txt")
    ///   - resourceSubpath: optional subpath inside bundle resources where vocab is located
    ///   - maxSequenceLength: final token length (including [CLS] and [SEP])
    public init(
        vocabFileName: String = "vocab.txt",
        resourceSubpath: String? = nil,
        bundle: Bundle = .main,
        maxSequenceLength: Int = 512
    ) throws {
        self.maxSequenceLength = maxSequenceLength

        // Temporary placeholders — Swift requires all stored vars to be initialized before using self
        self.unkToken = "[UNK]"
        self.clsToken = "[CLS]"
        self.sepToken  = "[SEP]"
        self.padToken  = "[PAD]"

        // Load vocab FIRST
        try loadVocab(from: vocabFileName, resourceSubpath: resourceSubpath, bundle: bundle)

        // Now it's safe to compute real special tokens
        func pick(_ candidates: [String], fallback: String) -> String {
            for c in candidates where tokenToId[c] != nil {
                return c
            }
            return fallback
        }

        // Assign REAL special tokens
        self.unkToken = pick(["[UNK]", "<unk>", "unk"], fallback: "[UNK]")
        self.clsToken = pick(["[CLS]", "[BOS]", "<s>"], fallback: "[CLS]")
        self.sepToken = pick(["[SEP]", "[EOS]"], fallback: "[SEP]")
        self.padToken = pick(["[PAD]"], fallback: "[PAD]")
    }

    // MARK: - Vocab loader
    private func loadVocab(from fileName: String, resourceSubpath: String?, bundle: Bundle) throws {
        // Try direct top-level resource first
        var url: URL? = nil

        if let subpath = resourceSubpath {
            url = bundle.url(forResource: (fileName as NSString).deletingPathExtension,
                              withExtension: (fileName as NSString).pathExtension,
                              subdirectory: resourceSubpath)

            if url == nil, let resURL = bundle.resourceURL {
                let candidate = resURL.appendingPathComponent((resourceSubpath ?? "")).appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    url = candidate
                }
            }
        }

        // fallback to top-level resource
        if url == nil {
            if let baseName = (fileName as NSString).deletingPathExtension as String?,
               let ext = (fileName as NSString).pathExtension as String?,
               !ext.isEmpty {
                url = bundle.url(forResource: baseName, withExtension: ext)
            } else {
                url = bundle.url(forResource: fileName, withExtension: nil)
            }
        }

        guard let vocabURL = url else {
            throw NSError(domain: "MiniLMTokenizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "vocab file not found in bundle: \(fileName) (subpath: \(resourceSubpath ?? "nil"))"])
        }

        let content = try String(contentsOf: vocabURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        tokenToId.removeAll(keepingCapacity: true)
        idToToken.removeAll(keepingCapacity: true)
        for (idx, raw) in lines.enumerated() {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            tokenToId[token] = idx
            idToToken[idx] = token
        }
    }

    // MARK: - Public encode
    public func encode(_ text: String) -> TokenizedOutput {
        // 1. normalize + basic tokenize
        let normalized = normalize(text)
        let basicTokens = basicTokenize(normalized)

        // 2. wordpiece tokenize
        var wordpieceTokens: [String] = []
        for token in basicTokens {
            let sub = wordPieceTokens(for: token)
            wordpieceTokens.append(contentsOf: sub)
        }

        // 3. add special tokens [CLS] ... [SEP]
        var tokens: [String] = []
        tokens.append(clsToken)
        tokens.append(contentsOf: wordpieceTokens)
        tokens.append(sepToken)

        // 4. convert tokens to ids
        var inputIds = tokens.map { id(for: $0) }

        // 5. truncate if needed (keep [CLS] and [SEP])
        if inputIds.count > maxSequenceLength {
            let keep = maxSequenceLength
            inputIds = Array(inputIds.prefix(keep))
            tokens = Array(tokens.prefix(keep))
            if tokens.last != sepToken {
                if let sepId = tokenToId[sepToken] {
                    inputIds[keep - 1] = sepId
                    tokens[keep - 1] = sepToken
                }
            }
        }

        // 6. attention mask & token_type_ids & padding
        var attentionMask = Array(repeating: 1, count: inputIds.count)
        var tokenTypeIds = Array(repeating: 0, count: inputIds.count)

        if inputIds.count < maxSequenceLength {
            let padCount = maxSequenceLength - inputIds.count
            if let padId = tokenToId[padToken] {
                inputIds.append(contentsOf: Array(repeating: padId, count: padCount))
            } else {
                inputIds.append(contentsOf: Array(repeating: 0, count: padCount))
            }
            attentionMask.append(contentsOf: Array(repeating: 0, count: padCount))
            tokenTypeIds.append(contentsOf: Array(repeating: 0, count: padCount))
            tokens.append(contentsOf: Array(repeating: padToken, count: padCount))
        }

        return TokenizedOutput(inputIds: inputIds,
                               attentionMask: attentionMask,
                               tokenTypeIds: tokenTypeIds,
                               tokens: tokens)
    }

    // MARK: - Helpers
    private func id(for token: String) -> Int {
        if let id = tokenToId[token] {
            return id
        } else if let unkId = tokenToId["[UNK]"] ?? tokenToId["<unk>"] {
            return unkId
        } else {
            return 0
        }
    }

    // Unicode normalization + lowercasing + strip accents per common HF "uncased" tokenizers
    private func normalize(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        let lower = nfkc.lowercased()
        let folded = lower.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
        let comps = folded.split { $0.isWhitespace }.map(String.init)
        return comps.joined(separator: " ")
    }

    // Basic whitespace + punctuation splitting
    private func basicTokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flushCurrent() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for scalar in text.unicodeScalars {
            let ch = Character(scalar)
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) ||
               ch == "'" || ch == "’" || ch == "#" || ch == "@" {
                current.append(ch)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flushCurrent()
            } else {
                flushCurrent()
                tokens.append(String(ch))
            }
        }
        flushCurrent()
        return tokens.filter { !$0.isEmpty }
    }

    // WordPiece greedy longest-match algorithm (prefix continuation uses "##")
    private func wordPieceTokens(for token: String) -> [String] {
        if tokenToId[token] != nil {
            return [token]
        }

        var chars = Array(token)
        var start = 0
        var subTokens: [String] = []
        var isBad = false

        while start < chars.count {
            var end = chars.count
            var curStr: String? = nil
            while start < end {
                let slice = String(chars[start..<end])
                let candidate = (start > 0) ? "##" + slice : slice
                if tokenToId[candidate] != nil {
                    curStr = candidate
                    break
                }
                end -= 1
            }
            if curStr == nil {
                isBad = true
                break
            }
            subTokens.append(curStr!)
            start = end
        }

        if isBad || subTokens.isEmpty {
            return [unkToken]
        }
        return subTokens
    }
}
