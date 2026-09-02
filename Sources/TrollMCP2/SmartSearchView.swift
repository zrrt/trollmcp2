import SwiftUI

// MARK: - 智能搜索（v2.9.10）
// 说明 web.search 工具用法 + 当前会话搜索开关指引。
// 替代原先的设置占位页。

struct SmartSearchView: View {
    @State private var showTip = true

    var body: some View {
        NavigationView {
            List {
                Section(header: SettingSectionHeader(title: "什么是智能搜索")) {
                    LabeledRow(label: "机制", value: "web.search 工具")
                    Text("聊天时 AI 可通过 web.search 调用 Bing 检索并返回标题/链接/摘要，用于回答需要实时信息的问题。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }

                Section(header: SettingSectionHeader(title: "使用方法")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 输入栏上方的「智能搜索·开」chip 保持开启")
                        Text("2. 提问时注明「请搜索」或直接问时效性问题")
                        Text("3. AI 会自动调用 web.search 并把结果带进回答")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                }

                Section(header: SettingSectionHeader(title: "示例")) {
                    Text("“帮我搜一下 2026 年最新的 iPhone 发布消息”\n→ AI 调用 web.search(\"2026 iPhone 发布会\")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }

                Section(header: SettingSectionHeader(title: "隐私")) {
                    Text("搜索词会发送到 Bing，用于返回检索结果。不会上传对话历史。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.grouped)
            .navigationTitle("内置智能搜索")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}
