import Foundation
import CoreML

// MARK: - 本地 Embedding 管理器（all-MiniLM-L6-v2 Core ML）

class EmbeddingManager {
    static let shared = EmbeddingManager()

    // 工具描述的向量缓存
    private var toolVectors: [String: [Double]] = [:]
    private var isLoaded = false
    private var isLoading = false

    // Core ML 模型
    private var embeddingModel: MLModel?

    // 配置
    @AppStorage("embedding_model_enabled") private var embeddingEnabled = false
    @AppStorage("embedding_model_downloaded") private var modelDownloaded = false

    private init() {}

    // MARK: - 加载模型

    /// 加载本地 Core ML 模型
    private func loadModel() -> Bool {
        guard embeddingModel == nil else { return true }

        // 查找模型文件
        guard let modelURL = Bundle.main.url(forResource: "MiniLM", withExtension: "mlmodelc") else {
            print("⚠️ Embedding: MiniLM.mlmodelc not found in bundle")
            return false
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine  // 用 Neural Engine 加速
            embeddingModel = try MLModel(contentsOf: modelURL, configuration: config)
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
        guard let model = embeddingModel else { return nil }

        // TODO: 实现 tokenizer（把文本分成 token）
        // TODO: 实现模型推理
        // 现在先返回 nil，等以后加上真正的实现
        return nil
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

    // MARK: - 状态查询

    var isReady: Bool {
        isLoaded && embeddingEnabled && modelDownloaded
    }

    var vectorCount: Int {
        toolVectors.count
    }
}
