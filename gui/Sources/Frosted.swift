import SwiftUI
import AppKit

/// 局部磨砂材质。
///
/// 关键是 blendingMode 用 `.withinWindow` 而不是 `.behindWindow`：
/// 后者会把桌面壁纸整个透上来，配上透明窗口就成了"隔着玻璃看桌面"，
/// 文字和壁纸糊在一起根本没法读。`.withinWindow` 只在窗口内部混合，
/// 做出来的是一层微妙的材质层次，有质感但不牺牲可读性。
///
/// 明暗主题不用自己判断 —— NSVisualEffectView 的材质本身就跟着系统外观走。
struct FrostedBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .contentBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .withinWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

extension View {
    /// 给一块区域套上磨砂卡片外观。
    /// 底下先垫一层不透明的窗口背景色：不管系统外观怎么切换，
    /// 文字都落在一个可读的底子上，磨砂只负责那层质感。
    func frostedCard(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(
                ZStack {
                    Color(NSColor.windowBackgroundColor)
                    FrostedBackground(material: .contentBackground)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension Color {
    /// Cloudflare 橙。深色模式下调亮一点，否则在暗背景上会糊成一团。
    static let cloudflareOrange = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 1.00, green: 0.65, blue: 0.28, alpha: 1)   // #FFA647
            : NSColor(srgbRed: 0.96, green: 0.51, blue: 0.12, alpha: 1)   // #F6821F
    })
}
