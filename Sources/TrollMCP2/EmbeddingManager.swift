import Foundation
import CoreML
import SwiftUI
import Combine

// MARK: - 本地 Embedding 管理器（all-MiniLM-L6-v2 Core ML）

class EmbeddingManager: ObservableObject {
    static let shared = EmbeddingManager()

    // 工具描述的向量缓存
    private var toolVectors: [String: [Double]] = [:]
    private var isLoaded = false
    private var isLoading = false

    // Core ML 模型
    private var embeddingModel: MLModel?

    // 配置
    @AppStorage("embedding_model_enabled") var embeddingEnabled = false
    @AppStorage("embedding_model_downloaded") var modelDownloaded = false

    // Tokenizer
    private var tokenizer: MiniLMTokenizer?

    private init() {}

    // MARK: - 加载模型

    /// 加载本地 Core ML 模型
    private func loadModel() -> Bool {
        guard embeddingModel == nil else { return true }

        // 从 Documents 目录加载（运行时下载的，不打包进 App）
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelDir = documentsURL.appendingPathComponent("EmbeddingModel")

        // 查找编译好的模型
        let compiledModelURL = modelDir.appendingPathComponent("AllMiniLML6V2.mlmodelc")
        let rawModelURL = modelDir.appendingPathComponent("AllMiniLML6V2.mlmodel")

        // 如果没有编译好的，就编译原始模型
        let finalModelURL: URL
        if fileManager.fileExists(atPath: compiledModelURL.path) {
            finalModelURL = compiledModelURL
        } else if fileManager.fileExists(atPath: rawModelURL.path) {
            do {
                // 编译模型
                print("⏳ Embedding: compiling model...")
                finalModelURL = try MLModel.compileModel(at: rawModelURL)
                // 移动到目标位置
                let destURL = modelDir.appendingPathComponent(finalModelURL.lastPathComponent)
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.moveItem(at: finalModelURL, to: destURL)
                print("✅ Embedding: model compiled")
            } catch {
                print("❌ Embedding: failed to compile model: \(error)")
                return false
            }
        } else {
            print("⚠️ Embedding: model not found in Documents")
            return false
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU  // 用 GPU 加速（Neural Engine 不支持 Transformer）
            embeddingModel = try MLModel(contentsOf: finalModelURL, configuration: config)

            // 加载 tokenizer（从 Documents 目录）
            let vocabURL = modelDir.appendingPathComponent("vocab.txt")
            tokenizer = try MiniLMTokenizer(vocabFileName: vocabURL.lastPathComponent,
                                            resourceSubpath: nil,
                                            bundle: Bundle(url: modelDir) ?? .main,
                                            maxSequenceLength: 512)

            print("✅ Embedding: MiniLM model loaded")
            return true
        } catch {
            print("❌ Embedding: failed to load model: \(error)")
            return false
        }
    }

    // MARK: - 预加载所有工具向量

    /// 启动时调用：预计算所有工具描述的向量
    func preloadToolVectors(tools: [(name: String, summary: String)]) {
        guard embeddingEnabled, modelDownloaded else { return }
        guard !isLoaded, !isLoading else { return }
        isLoading = true

        // 加载模型
        guard loadModel() else {
            isLoading = false
            return
        }

        // 异步加载，不阻塞启动
        DispatchQueue.global(qos: .utility).async {
            var vectors: [String: [Double]] = [:]
            for tool in tools {
                let text = tool.name + " " + tool.summary
                if let vec = self.embedSync(text) {
                    vectors[tool.name] = vec
                }
            }
            DispatchQueue.main.async {
                self.toolVectors = vectors
                self.isLoaded = true
                self.isLoading = false
                print("✅ Embedding: loaded \(vectors.count) tool vectors")
            }
        }
    }

    // MARK: - 单条文本 embedding

    /// 同步获取文本向量（内部调用）
    private func embedSync(_ text: String) -> [Double]? {
        guard let model = embeddingModel,
              let tokenizer = tokenizer else { return nil }

        // 1. Tokenize
        let tokenized = tokenizer.encode(text)

        // 2. 准备输入
        do {
            let inputIds = try makeMLMultiArray(tokenized.inputIds)
            let attentionMask = try makeMLMultiArray(tokenized.attentionMask)
            let tokenTypeIds = try makeMLMultiArray(tokenized.tokenTypeIds)

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": inputIds,
                "attention_mask": attentionMask,
                "token_type_ids": tokenTypeIds
            ])

            // 3. 模型推理
            let output = try model.prediction(from: features)

            // 4. 获取 hidden states
            guard let hiddenStates = output.featureValue(for: "last_hidden_state")?.multiArrayValue else {
                // Fallback: 找第一个 3D 数组
                for name in output.featureNames {
                    if let arr = output.featureValue(for: name)?.multiArrayValue, arr.shape.count == 3 {
                        return maskedMeanPool(hs: arr, mask: attentionMask)
                    }
                }
                return nil
            }

            // 5. 掩码平均池化
            return maskedMeanPool(hs: hiddenStates, mask: attentionMask)

        } catch {
            print("❌ Embedding: inference error: \(error)")
            return nil
        }
    }

    // MARK: - 辅助函数

    /// 创建 MLMultiArray
    private func makeMLMultiArray(_ ints: [Int]) throws -> MLMultiArray {
        let arr = try MLMultiArray(
            shape: [1, NSNumber(value: ints.count)],
            dataType: .int32
        )
        let ptr = arr.dataPointer.bindMemory(to: Int32.self, capacity: ints.count)
        for (i, v) in ints.enumerated() {
            ptr[i] = Int32(v)
        }
        return arr
    }

    /// 掩码平均池化：把 [1, seqLen, hidden] 变成 [1, hidden]
    private func maskedMeanPool(hs: MLMultiArray, mask: MLMultiArray) -> [Double] {
        let seqLen = hs.shape[1].intValue
        let hiddenSize = hs.shape[2].intValue

        var sumVec = [Double](repeating: 0, count: hiddenSize)
        var count: Double = 0

        let hsPtr = hs.dataPointer.bindMemory(to: Float32.self, capacity: seqLen * hiddenSize)
        let maskPtr = mask.dataPointer.bindMemory(to: Int32.self, capacity: seqLen)

        for i in 0..<seqLen {
            let m = maskPtr[i]
            if m > 0 {
                count += 1
                for j in 0..<hiddenSize {
                    let idx = i * hiddenSize + j
                    sumVec[j] += Double(hsPtr[idx])
                }
            }
        }

        guard count > 0 else { return [Double](repeating: 0, count: hiddenSize) }

        // 平均
        for j in 0..<hiddenSize {
            sumVec[j] /= count
        }

        // L2 归一化
        var norm: Double = 0
        for j in 0..<hiddenSize {
            norm += sumVec[j] * sumVec[j]
        }
        norm = norm.squareRoot()
        guard norm > 0 else { return sumVec }

        for j in 0..<hiddenSize {
            sumVec[j] /= norm
        }

        return sumVec
    }

    /// 异步获取文本向量
    func embed(_ text: String, completion: @escaping ([Double]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.embedSync(text)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - 相似度计算

    /// 计算查询向量和所有工具向量的相似度，返回 top N
    func searchSimilar(_ queryVector: [Double], topN: Int = 8) -> [(name: String, score: Double)] {
        guard isLoaded else { return [] }
        var results: [(name: String, score: Double)] = []
        for (name, toolVec) in toolVectors {
            let sim = cosineSimilarity(queryVector, toolVec)
            results.append((name, sim))
        }
        results.sort { $0.score > $1.score }
        return Array(results.prefix(topN))
    }

    /// 余弦相似度
    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var dotProduct: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dotProduct / (normA.squareRoot() * normB.squareRoot())
    }

    // MARK: - 相似度计算

    /// 计算查询文本和工具向量的相似度
    func similarity(for query: String, toolName: String) -> Double? {
        guard let toolVec = toolVectors[toolName] else { return nil }
        guard let queryVec = embedSync(query) else { return nil }
        return cosineSimilarity(queryVec, toolVec)
    }

    // MARK: - 状态查询

    var isReady: Bool {
        isLoaded && embeddingEnabled && modelDownloaded
    }

    var vectorCount: Int {
        toolVectors.count
    }
}
