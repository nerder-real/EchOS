import SwiftUI

/// 三等分的分流模式选择器。
///
/// 没用系统的 segmented Picker：它在 macOS 上只按文字内容算宽度，
/// `maxWidth: .infinity` 对它不起作用，右边永远空一截。
/// 自己画一个，每段 `maxWidth: .infinity`，宽度必然均分且铺满整行。
struct ModeSegment: View {
    @Binding var selection: RouteMode
    var disabled: Bool = false

    private let modes = RouteMode.allCases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(modes.enumerated()), id: \.element.id) { idx, mode in
                segment(mode)
                if idx < modes.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1)
                }
            }
        }
        .frame(height: 30)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(disabled ? 0.5 : 1)
    }

    @ViewBuilder
    private func segment(_ mode: RouteMode) -> some View {
        let active = selection == mode
        Text(mode.title)
            .font(.system(size: 13.5, weight: active ? .semibold : .regular))
            // 选中态底色是强调色，文字固定用白色；未选中跟随系统前景色，
            // 这样浅色/深色模式下都有足够对比。
            .foregroundColor(active ? Color(NSColor.selectedMenuItemTextColor) : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(active ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !disabled else { return }
                selection = mode
            }
    }
}
