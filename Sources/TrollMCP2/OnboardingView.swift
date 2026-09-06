import SwiftUI
import UIKit

// v2.9.78：首次启动引导（onboarding）
// 三页：欢迎 → 能力 → 开始使用。看过一次后不再弹出（UserDefaults 标记）。

struct OnboardingView: View {
    @State private var page = 0
    private let total = 3
    var onFinish: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.tmCyan.opacity(0.18), Color(.systemBackground), Color.blue.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部：跳过（仅前两页显示）
                HStack {
                    Spacer()
                    if page < total - 1 {
                        Button(L10n.t("ob_skip")) { onFinish() }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                }

                TabView(selection: $page) {
                    welcomePage.tag(0)
                    capabilityPage.tag(1)
                    startPage.tag(2)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                // 底部控制
                VStack(spacing: 14) {
                    // 分页点
                    HStack(spacing: 8) {
                        ForEach(0..<total, id: \.self) { i in
                            Capsule()
                                .fill(i == page ? Color.tmCyan : Color.secondary.opacity(0.3))
                                .frame(width: i == page ? 22 : 8, height: 8)
                                .animation(.easeInOut(duration: 0.2))   // iOS14：不用 animation(_:value:)
                        }
                    }

                    Button(action: {
                        if page < total - 1 {
                            withAnimation { page += 1 }
                        } else {
                            onFinish()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Text(page < total - 1 ? L10n.t("ob_next") : L10n.t("ob_done"))
                                .font(.body)
                                .fontWeight(.semibold)
                            Image(systemName: page < total - 1 ? "arrow.right" : "checkmark")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(colors: [Color.tmCyan, Color.blue], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(16)
                        .shadow(color: Color.tmCyan.opacity(0.35), radius: 10, x: 0, y: 4)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 页 1：欢迎
    private var welcomePage: some View {
        VStack(spacing: 22) {
            // App 图标 + 光晕
            ZStack {
                Circle()
                    .fill(Color.tmCyan.opacity(0.18))
                    .frame(width: 190, height: 190)
                Circle()
                    .stroke(Color.tmCyan.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 170, height: 170)
                if let appIcon = UIImage(named: "AppIcon60x60@3x") ?? UIImage(named: "AppIcon1024x1024") {
                    Image(uiImage: appIcon)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        )
                        .shadow(color: Color.tmCyan.opacity(0.4), radius: 18, x: 0, y: 8)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 56))
                        .foregroundColor(.white)
                        .frame(width: 128, height: 128)
                        .background(
                            LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .cornerRadius(30)
                }
            }

            Text(L10n.t("ob_welcome_title"))
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(L10n.t("ob_welcome_sub"))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 20)
    }

    // MARK: - 页 2：能力
    private var capabilityPage: some View {
        VStack(spacing: 24) {
            Text(L10n.t("ob_cap_title"))
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top, 10)

            VStack(spacing: 14) {
                capRow("hammer.fill", L10n.t("ob_cap1"), [.orange, .tmBrown])
                capRow("syringe.fill", L10n.t("ob_cap2"), [.green, .tmTeal])
                capRow("cursorarrow.click.2", L10n.t("ob_cap3"), [.tmCyan, .blue])
                capRow("globe", L10n.t("ob_cap4"), [.purple, .tmIndigo])
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func capRow(_ icon: String, _ text: String, _ colors: [Color]) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - 页 3：开始
    private var startPage: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                    .frame(width: 150, height: 150)
                Image(systemName: "sparkles")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundColor(.tmCyan)
            }
            .padding(.top, 30)

            Text(L10n.t("ob_start_title"))
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(L10n.t("ob_start_sub"))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 36)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
