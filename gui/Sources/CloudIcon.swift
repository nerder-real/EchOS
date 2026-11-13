import AppKit

/// 菜单栏图标与标题栏 logo。
///
/// 菜单栏图标**直接使用 Win 目录的那一套**（assets/tray-ora.ico / tray-blue.ico
/// 提取的 PNG，随 App 打包为 Resources/tray-ora.png / tray-blue.png）：
///   橙色徽章 = 未接管系统代理，蓝色徽章 = 已接管成功 —— 与 Win 托盘
///   tray-ora / tray-blue 两态一一对应；已停止不再单独画空心变体，状态由
///   菜单首行文字表达（「ECH 代理未运行」）。
enum CloudIcon {

    /// Cloudflare 橙黄 = 未接管成功，蓝色 = 系统代理已接管成功（菜单首行圆点同款）
    static let offColor = NSColor(srgbRed: 0.965, green: 0.510, blue: 0.122, alpha: 1) // #F6821F
    static let onColor  = NSColor(srgbRed: 0.125, green: 0.478, blue: 1.000, alpha: 1) // #207AFF

    private static var iconCache: [String: NSImage] = [:]

    /// 菜单栏状态图标（Win 托盘同款）。256px 源图缩到菜单栏尺寸，
    /// 按 backing scale 重采样保持锐利。
    static func statusIcon(ready: Bool, size: CGFloat = 18) -> NSImage {
        let name = ready ? "tray-blue" : "tray-ora"
        let key = "\(name)@\(Int(size))"
        if let cached = iconCache[key] { return cached }

        let img: NSImage
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let src = NSImage(contentsOf: url) {
            img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .high
                src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
        } else {
            // 资源缺失（不应发生）：退回系统云符号，菜单栏不至于空着
            img = NSImage(systemSymbolName: "cloud.fill",
                          accessibilityDescription: "EchOS") ?? NSImage()
        }
        img.isTemplate = false
        iconCache[key] = img
        return img
    }

    // MARK: - 主界面标题栏 logo（引用打包资源，不再代码自绘）

    private static var cachedLogo: NSImage?

    /// 打包在 Resources/logo.png 的品牌徽章标（与 Win 端同源的 logo 资源，
    /// 橙底白云）。取不到返回 nil，调用方退回系统符号图标。
    static func bundledLogo() -> NSImage? {
        if let cachedLogo { return cachedLogo }
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cachedLogo = img
        return img
    }
}
