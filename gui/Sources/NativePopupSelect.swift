import SwiftUI
import AppKit

/// 原生 NSPopUpButton 包装，不做任何自绘：
/// - 内容居中：NSPopUpButton.alignment = .center
/// - 箭头颜色：走系统标准灰，两个下拉框风格统一
/// SwiftUI 的 Picker 这两个都控不了，包一层原生控件就能调。
struct NativePopupSelect<T: Hashable>: NSViewRepresentable {
    @Binding var selection: T
    let options: [(title: String, value: T)]
    var controlSize: NSControl.ControlSize = .regular

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.controlSize = controlSize
        b.alignment = .center
        // 箭头颜色保持系统默认（随强调色/深浅模式），不强制改色
        b.target = context.coordinator
        b.action = #selector(Coordinator.changed(_:))
        b.font = .systemFont(ofSize: 12.5)
        // 按钮宽度只由内容决定：NSPopUpButton 的水平 hugging 默认偏低，
        // 放进 SwiftUI 的 HStack 会被拉宽吃满剩余空间 —— 页面拉宽时按钮跟着
        // 变长。设为 required 后它始终保持固有宽度，多余空间留给 Spacer。
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        rebuild(b)
        return b
    }
    func updateNSView(_ b: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        rebuild(b)
    }

    /// 选项标题变了才重建（避免跟用户正在操作的下拉菜单打架），然后同步选中项。
    private func rebuild(_ b: NSPopUpButton) {
        let current = (0..<b.numberOfItems).map { b.item(at: $0)?.title ?? "" }
        let titles = options.map(\.title)
        if current != titles {
            b.removeAllItems()
            for opt in options {
                b.addItem(withTitle: opt.title)
                b.lastItem?.representedObject = opt.value
            }
        }
        if let idx = options.firstIndex(where: { $0.value == selection }),
           b.indexOfSelectedItem != idx {
            b.selectItem(at: idx)
        }
    }

    final class Coordinator: NSObject {
        var parent: NativePopupSelect<T>
        init(_ parent: NativePopupSelect<T>) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            guard let v = sender.selectedItem?.representedObject as? T else { return }
            parent.selection = v
        }
    }
}
