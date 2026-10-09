//
//  Live2DPreviewScreen.swift — TrollAgent 主 App Live2D 预览页（诊断用）
//
//  在主 App 正常 GPU 环境下渲染 Hiyori，用于定位 Cubism+Hiyori 渲染链路是否可行。
//
import SwiftUI
import Live2DPreview

/// UIViewRepresentable：L2DHostView(CAMetalLayer) + Live2DPreview 渲染
struct Live2DHostRepresentable: UIViewRepresentable {
    @Binding var preview: Live2DPreview?
    @Binding var status: String

    func makeUIView(context: Context) -> L2DHostView {
        let v = L2DHostView()
        let p = Live2DPreview()
        preview = p
        // 初始化（dlopen / Cubism init / 模型加载）可能耗时，放后台线程避免卡 UI，主线程更新状态
        DispatchQueue.global(qos: .userInitiated).async {
            let started = p.prepare() && p.start(in: v)
            let msg = started
                ? "渲染激活：Hiyori 已加载"
                : "失败：\(p.lastError ?? "未知")"
            DispatchQueue.main.async {
                self.status = msg
            }
        }
        return v
    }
    func updateUIView(_ uiView: L2DHostView, context: Context) {}
}

struct Live2DPreviewScreen: View {
    @State private var preview: Live2DPreview?
    @State private var status = "加载中…"
    @State private var motionGroup = "Idle"
    @State private var motionNo = 0

    var body: some View {
        VStack(spacing: 12) {
            Live2DHostRepresentable(preview: $preview, status: $status)
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .background(Color.black.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

            Text(status)
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            HStack(spacing: 10) {
                Picker("动作组", selection: $motionGroup) {
                    Text("Idle").tag("Idle")
                    Text("TapBody").tag("TapBody")
                    Text("TapHead").tag("TapHead")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 160)

                Button("播放") {
                    preview?.playMotion(motionGroup, no: Int32(motionNo), priority: Int32(1))
                }
                .disabled(preview == nil)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            Text("说明：此预览在主 App（正常 GPU 环境）下渲染 Hiyori，用于定位 Cubism 链路是否可行。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)

            Spacer()
        }
        .padding(.top)
        .navigationTitle("Live2D 预览")
    }
}
