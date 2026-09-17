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

// MARK: - v2.9.236 全局导航容器
// iOS16+ 用 NavigationStack：修复 iOS16 NavigationView 已知 bug——
// ① 切后台回前台导航栈丢失(自动返回上一页) ② NavigationLink(isActive:) 被弹回 ③ toolbar 取消/完成按钮点击无响应
// iOS15 保持 NavigationView + stack 样式(行为不变)
@ViewBuilder
func CompatNav<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    if #available(iOS 16.0, *) {
        NavigationStack { content() }
    } else {
        NavigationView { content() }.navigationViewStyle(.stack)
    }
}

// v2.9.241：iOS 15.6 兼容——URLRequest.httpMethod 的 Swift setter 是 iOS16+ ABI 符号
// (dyld: Symbol not found _$s10Foundation10URLRequestV10httpMethodSSSgvs)，iOS 15.6 的 Foundation 缺失导致启动闪退。
// 改用 NSMutableURLRequest 的 ObjC 属性设置，ObjC 消息跨 iOS 14-17 稳定。
func setHTTPMethod(_ method: String, on request: inout URLRequest) {
    let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
    mutable.httpMethod = method
    request = mutable as! URLRequest
}

// v2.9.250：iOS15 兼容——presentationDetents 仅 iOS16+；部署目标降15后 iOS16 分支正常半屏、iOS15 保持默认 sheet。
// 参数直接传高度 CGFloat，避免调用处裸引用 iOS16 类型(PresentationDetent/.height 字面量推断失败)
extension View {
    @ViewBuilder
    func sheetDetentsHeight(_ height: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.height(height)])
        } else {
            self
        }
    }
}

// v2.9.248：iOS 15.6 兼容——URLRequest.timeoutInterval 的 Swift setter 是 iOS16+ ABI 符号
// (dyld: Symbol not found _$s10Foundation10URLRequestV15timeoutIntervalSdvs)，iOS 15.6 Foundation 缺失导致启动闪退。
// 改用 NSMutableURLRequest 的 ObjC 属性，ObjC 消息跨 iOS 14-17 稳定。
func setTimeoutInterval(_ interval: TimeInterval, on request: inout URLRequest) {
    let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
    mutable.timeoutInterval = interval
    request = mutable as! URLRequest
}
