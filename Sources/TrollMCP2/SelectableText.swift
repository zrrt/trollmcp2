import SwiftUI
import UIKit

/// v4.4.21：可划词选择的只读富文本视图——用 UITextView 原生长按选字/拖手柄划词/复制菜单。
/// iOS 15 的 SwiftUI `textSelection(.enabled)` 长按只能直接全选、没有划词手柄，无法选词/选句；
/// UITextView 是 UIKit 原生文本选择，任意 iOS 版本都稳定支持长按放大镜定位 + 拖手柄划词 + 复制/朗读。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    var textColor: UIColor = .label
    var fontSize: CGFloat = 17

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textColor = textColor
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        // 允许文字区仍可长按选择，但不让滚动
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.textColor = textColor
        tv.font = .systemFont(ofSize: fontSize)
        tv.attributedText = attributed
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? (UIScreen.main.bounds.width - 40)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: size.height)
    }
}
