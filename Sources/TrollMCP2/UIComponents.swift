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
