import SwiftUI

// MARK: - 本地向量语义模型管理

struct EmbeddingModelView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @AppStorage("embedding_model_enabled") private var embeddingEnabled = false
    @AppStorage("embedding_model_downloaded") private var modelDownloaded = false
    @State private var vectorCount = 0

    private var embeddingManager = EmbeddingManager.shared

    var body: some View {
        CompatNav {
            List {
                // 介绍
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "brain.head.profile")
                                .font(.largeTitle)
                                .foregroundColor(.tmCyan)
                            VStack(alignment: .leading) {
                                Text("向量语义搜索")
                                    .font(.headline)
                                Text("Vector Semantic Search")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text("""
                        这个模型用来帮 AI 更好地搜索工具。

                        没有它的时候，AI 只能靠关键词匹配，比如你说「抓包」才能找到「网络抓包工具」。

                        有了它之后，AI 能听懂意思，比如你说「帮我分析一下 API 请求」，它也能找到「网络抓包工具」。

                        这样 AI 就不会瞎搜 tool_search 陷入循环了！
                        """)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                // 模型信息
                Section("模型信息") {
                    InfoRow(title: "模型名称", value: "all-MiniLM-L6-v2")
                    InfoRow(title: "模型大小", value: "约 80 MB")
                    InfoRow(title: "向量维度", value: "384 维")
                    InfoRow(title: "推理速度", value: "约 5ms（iPhone 15 Pro）")
                    InfoRow(title: "离线可用", value: "✅ 下载后不需要网络")
                    InfoRow(title: "已加载工具向量", value: "\(vectorCount) 个")
                }

                // 下载/删除
                Section {
                    if modelDownloaded {
                        // 已下载
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading) {
                                Text("模型已下载")
                                    .font(.body)
                                Text("可以使用本地向量语义搜索")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("删除") {
                                deleteModel()
                            }
                            .foregroundColor(.red)
                        }

                        Toggle("启用向量语义搜索", isOn: $embeddingEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: .tmCyan))
                    } else {
                        // 未下载
                        VStack(alignment: .leading, spacing: 12) {
                            Text("模型未下载")
                                .font(.headline)
                            Text("下载后 AI 能更好地理解你的意图，搜索工具更准确。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            if isDownloading {
                                VStack(alignment: .leading) {
                                    ProgressView(value: downloadProgress) {
                                        Text("下载中... \(Int(downloadProgress * 100))%")
                                            .font(.caption)
                                    }
                                }
                            } else {
                                Button(action: downloadModel) {
                                    HStack {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text("下载模型（80MB）")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.tmCyan)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                // 常见问题
                Section("常见问题") {
                    FAQItem(question: "下载模型会卡吗？",
                            answer: "不会！模型很小（80MB），下载后推理速度很快（5ms），不会影响手机性能。")
                    FAQItem(question: "模型是用来聊天的吗？",
                            answer: "不是！这个模型只是用来把文字变成向量，帮助 AI 更好地搜索工具，不负责聊天。")
                    FAQItem(question: "需要联网吗？",
                            answer: "下载完之后就不需要联网了，可以离线使用。")
                    FAQItem(question: "和云端 embedding 哪个好？",
                            answer: "本地模型速度快、离线可用；云端模型中文效果更好。你可以根据自己的需求选择。")
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("向量语义搜索模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func downloadModel() {
        isDownloading = true
        downloadProgress = 0

        // 真正的下载逻辑
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelDir = documentsURL.appendingPathComponent("EmbeddingModel")

        // 创建目录
        try? fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let modelURL = modelDir.appendingPathComponent("AllMiniLML6V2.mlmodel")
        let vocabURL = modelDir.appendingPathComponent("vocab.txt")

        // 下载模型文件
        let modelDownloadURL = URL(string: "https://raw.githubusercontent.com/Abhishek6353/AllMiniLML6V2-coreml/main/AllMiniLML6V2-coreml/Models/embeddings/AllMiniLML6V2.mlmodel")!
        let vocabDownloadURL = URL(string: "https://raw.githubusercontent.com/Abhishek6353/AllMiniLML6V2-coreml/main/AllMiniLML6V2-coreml/Models/llm/vocab.txt")!

        // 用 URLSession 下载
        let session = URLSession.shared

        // 先下载 vocab.txt（小文件，1MB）
        let vocabTask = session.downloadTask(with: vocabDownloadURL) { tempURL, response, error in
            guard let tempURL = tempURL, error == nil else {
                DispatchQueue.main.async {
                    isDownloading = false
                    print("❌ Download vocab failed: \(error!)")
                }
                return
            }

            do {
                // 移动到目标位置
                if fileManager.fileExists(atPath: vocabURL.path) {
                    try fileManager.removeItem(at: vocabURL)
                }
                try fileManager.moveItem(at: tempURL, to: vocabURL)

                DispatchQueue.main.async {
                    downloadProgress = 0.1
                }

                // 再下载模型文件（大文件，85MB）
                let modelTask = session.downloadTask(with: modelDownloadURL) { tempURL, response, error in
                    guard let tempURL = tempURL, error == nil else {
                        DispatchQueue.main.async {
                            isDownloading = false
                            print("❌ Download model failed: \(error!)")
                        }
                        return
                    }

                    do {
                        // 移动到目标位置
                        if fileManager.fileExists(atPath: modelURL.path) {
                            try fileManager.removeItem(at: modelURL)
                        }
                        try fileManager.moveItem(at: tempURL, to: modelURL)

                        DispatchQueue.main.async {
                            downloadProgress = 1.0
                            isDownloading = false
                            modelDownloaded = true
                            embeddingEnabled = true
                            vectorCount = 200  // 临时显示
                            print("✅ Embedding model downloaded!")
                        }
                    } catch {
                        DispatchQueue.main.async {
                            isDownloading = false
                            print("❌ Move model failed: \(error)")
                        }
                    }
                }

                // 跟踪下载进度
                // TODO: 用 delegate 跟踪进度
                modelTask.resume()

            } catch {
                DispatchQueue.main.async {
                    isDownloading = false
                    print("❌ Move vocab failed: \(error)")
                }
            }
        }

        vocabTask.resume()
    }

    private func deleteModel() {
        modelDownloaded = false
        embeddingEnabled = false
        vectorCount = 0
    }
}

// MARK: - 辅助视图

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

struct FAQItem: View {
    let question: String
    let answer: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(answer)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
        } label: {
            Text(question)
                .font(.body)
        }
    }
}
