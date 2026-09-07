import SwiftUI
import UIKit

// v2.9.89：关于作者（作者卡片 / 开源致谢 / 安全 / 注意 / 免责 / 赞助 / 反馈）
struct AboutAuthorView: View {
    @State private var copied = false

    private func bundleImage(_ name: String, _ ext: String) -> UIImage? {
        guard let p = Bundle.main.path(forResource: name, ofType: ext) else { return nil }
        return UIImage(contentsOfFile: p)
    }

    var body: some View {
        PageContainer {
            PageHeader(
                icon: "person.crop.circle.fill",
                title: L10n.t("about_title"),
                subtitle: L10n.t("about_subtitle"),
                colors: [.blue, .tmCyan],
                iconColor: .white
            )

            // 作者卡片
            CardBox {
                VStack(spacing: 12) {
                    if let img = bundleImage("author_avatar", "jpg") {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(
                                LinearGradient(colors: [.blue, .tmCyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 3))
                    }
                    Text("ZeenAE")
                        .font(.title3.weight(.bold))
                        .foregroundColor(.primary)
                    Text(L10n.t("about_bio"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineSpacing(4)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }

            // 开源致谢
            CardSectionHeader(icon: "heart.fill", title: L10n.t("about_thanks"), color: .pink)
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("about_thanks_intro"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(thankRows, id: \.0) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.0)
                                .font(.caption)
                            Text(row.1)
                                .font(.caption)
                                .foregroundColor(.primary)
                            Spacer(minLength: 0)
                            Text(row.2)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            // 安全说明
            CardSectionHeader(icon: "lock.fill", title: L10n.t("about_safety"), color: .green)
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(safetyRows, id: \.self) { row in
                        Text(row)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // 注意事项
            CardSectionHeader(icon: "exclamationmark.triangle.fill", title: L10n.t("about_notes"), color: .orange)
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(noteRows, id: \.self) { row in
                        Text(row)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // 免责声明
            CardSectionHeader(icon: "hand.raised.fill", title: L10n.t("about_disclaimer"), color: .red)
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(disclaimerRows, id: \.self) { row in
                        Text(row)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // 赞助
            CardSectionHeader(icon: "cup.and.saucer.fill", title: L10n.t("about_sponsor"), color: .tmBrown)
            CardBox {
                VStack(spacing: 10) {
                    Text(L10n.t("about_sponsor_body"))
                        .font(.caption)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let img = bundleImage("wechat_qr", "jpg") {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 200)
                            .cornerRadius(10)
                    } else {
                        Text("WeChat QR")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Bug 与功能反馈
            CardSectionHeader(icon: "envelope.fill", title: L10n.t("about_feedback"), color: .blue)
            CardBox {
                VStack(spacing: 10) {
                    Text(L10n.t("about_feedback_body"))
                        .font(.caption)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: copyFeedback) {
                        Label(copied ? L10n.t("about_copied") : L10n.t("about_copy_feedback"),
                              systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                LinearGradient(colors: [.blue, .tmCyan], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(18)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(L10n.t("about_title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 数据

    private var deviceLine: String {
        "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
    }

    private var versionLine: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.9.99"
    }

    private var thankRows: [(String, String, String)] {
        [
            ("📦", "TrollStore", "(opa334)"),
            ("💉", "TrollFools", "(Lessica)"),
            ("⚙️", "Theos", "toolchain"),
            ("🔐", "ldid / insert_dylib / optool / ct_bypass", "injection"),
            ("🤖", "GitHub Actions", "cloud build"),
            ("🙏", L10n.t("about_thanks_all"), "")
        ]
    }

    private var safetyRows: [String] { L10n.t("about_safety_rows").components(separatedBy: "|") }
    private var noteRows: [String] { L10n.t("about_note_rows").components(separatedBy: "|") }
    private var disclaimerRows: [String] { L10n.t("about_disclaimer_rows").components(separatedBy: "|") }

    private func copyFeedback() {
        let text = "TrollAgent v\(versionLine) · \(deviceLine) · 反馈内容："
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
    }
}
