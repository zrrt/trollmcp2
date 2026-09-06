import SwiftUI

// v2.9.77：统一页面美化组件库
// 所有设置子页面共用：PageHeader（渐变图标+标题+副标题）+ CardBox（圆角卡片）+ 段落标题

struct PageHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    var colors: [Color] = [Color.tmCyan, Color.blue]
    var iconColor: Color = .white

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .shadow(color: colors[0].opacity(0.3), radius: 6, x: 0, y: 3)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
        )
        .padding(.horizontal, 16)
    }
}

struct CardBox<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, 16)
    }
}

struct CardSectionHeader: View {
    let icon: String
    let title: String
    var color: Color = .tmCyan

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

struct PageContainer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                content
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
    }
}
