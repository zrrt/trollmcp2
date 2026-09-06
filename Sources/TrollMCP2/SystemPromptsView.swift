import SwiftUI

// v2.9.74：系统指令选择页面
// 系统指令是 App 内置的、不可编辑的行为规范
// 用户可在此切换哪套作为默认，优先级高于开发者指令

struct SystemPromptsView: View {
    @State private var selectedId = SystemPrompts.shared.selectedId
    @State private var expandedId: String? = nil

    var body: some View {
        List {
            Section(header: Text("选择系统指令（不可编辑，切换后立即生效）")) {
                ForEach(SystemPrompts.builtin) { prompt in
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: {
                            selectedId = prompt.id
                            SystemPrompts.shared.select(prompt.id)
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(prompt.name)
                                        .font(.headline)
                                        .foregroundColor(selectedId == prompt.id ? .tmCyan : .primary)
                                    Text(prompt.desc)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedId == prompt.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.tmCyan)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())

                        if expandedId == prompt.id {
                            ScrollView {
                                Text(prompt.content)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 300)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                        }

                        Button(action: {
                            withAnimation {
                                expandedId = expandedId == prompt.id ? nil : prompt.id
                            }
                        }) {
                            Text(expandedId == prompt.id ? "收起内容" : "查看内容")
                                .font(.caption)
                                .foregroundColor(.tmCyan)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("说明")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("系统指令 vs 开发者指令")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("• 系统指令：App 内置，不可编辑，优先级最高，控制 AI 的基本行为模式")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• 开发者指令：用户可自建/编辑，作为补充规范")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• 两者同时生效，系统指令先注入，开发者指令后注入")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("系统指令")
        .navigationBarTitleDisplayMode(.inline)
    }
}
