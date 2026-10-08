import AppKit

/// 菜单栏用的云朵图标，直接用代码画。
///
/// 原本是把 SVG 用 qlmanage 转成 PNG 再打包，结果那条工具链会给图片糊上
/// 不透明的白底 —— 染色后整个方块都被填满，菜单栏里就是一坨色块而不是云。
/// 与其跟渲染工具较劲，不如用 NSBezierPath 画出来：尺寸、线宽、透明度全都确定。
enum CloudIcon {

    /// 生成云朵图标。filled=true 是实心（运行中），false 是空心（已停止）。
    /// 形状本身就能区分状态，不必只靠颜色 —— 灰度模式或色觉差异下依然可辨。
    static func make(filled: Bool, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        defer { img.unlockFocus() }

        NSColor.black.setFill()

        let outer = cloudPath(in: NSRect(x: 0, y: 0, width: size, height: size),
                              inset: size * 0.05)
        outer.windingRule = .nonZero
        outer.fill()

        if !filled {
            // 空心：把中间掏掉，只留一圈轮廓。
            // 用 .clear 合成直接擦除，比描边可靠 —— 云是几个圆拼出来的，
            // 描边会把内部那些拼接圆弧也画出来，看着像一团乱线。
            NSGraphicsContext.current?.compositingOperation = .clear
            let inner = cloudPath(in: NSRect(x: 0, y: 0, width: size, height: size),
                                  inset: size * 0.05 + max(2, size * 0.15))
            inner.windingRule = .nonZero
            inner.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        img.isTemplate = false
        return img
    }

    /// 云朵轮廓：三个圆凸起 + 一个圆角底座，nonZero 填充会自动并成一体。
    /// inset 越大形状越小，空心版就是靠两个不同 inset 的形状相减做出来的。
    private static func cloudPath(in rect: NSRect, inset: CGFloat) -> NSBezierPath {
        let w = rect.width - inset * 2
        let h = rect.height - inset * 2
        let x = rect.minX + inset
        let y = rect.minY + inset

        // 各部件相对整体的比例，换任何尺寸都保持同样的观感
        let baseH = h * 0.36
        let baseY = y + h * 0.15
        let path = NSBezierPath()

        path.appendRoundedRect(
            NSRect(x: x + w * 0.04, y: baseY, width: w * 0.92, height: baseH),
            xRadius: baseH / 2, yRadius: baseH / 2)

        // 左、中、右三个圆：中间最高，左右稍低，做出云的起伏
        path.appendOval(in: NSRect(x: x + w * 0.00, y: baseY + h * 0.07,
                                   width: w * 0.45, height: w * 0.45))
        path.appendOval(in: NSRect(x: x + w * 0.25, y: baseY + h * 0.18,
                                   width: w * 0.54, height: w * 0.54))
        path.appendOval(in: NSRect(x: x + w * 0.55, y: baseY + h * 0.05,
                                   width: w * 0.45, height: w * 0.45))
        return path
    }
}
