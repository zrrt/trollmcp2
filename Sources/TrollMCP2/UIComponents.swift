import SwiftUI

// MARK: - 通用设置行（原版 TrollMCP 风格）

struct SettingRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let destination: Destination?

    init(title: String, subtitle: String = "", icon: String, color: Color, destination: Destination) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.destination = destination
    }

    init(title: String, subtitle: String = "", icon: String, color: Color) where Destination == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.destination = nil
    }

    var body: some View {
        Group {
            if let dest = destination {
                NavigationLink(destination: dest) { rowContent }
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color)
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if destination == nil {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SettingRowButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color)
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundColor(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SettingSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.top, 8)
    }
}

struct IconBadge: View {
    let icon: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)
                .frame(width: 36, height: 36)
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - iOS 14 安全色（SwiftUI 2.0 颜色在 iOS 14 不可用）

extension Color {
    static let tmIndigo = Color(red: 0.345, green: 0.337, blue: 0.839)
    static let tmTeal = Color(red: 0.0, green: 0.482, blue: 0.482)
    static let tmCyan = Color(red: 0.0, green: 0.741, blue: 0.949)
    static let tmBrown = Color(red: 0.588, green: 0.416, blue: 0.235)
}
