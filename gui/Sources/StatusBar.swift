import AppKit
import SwiftUI
import Combine

/// 通知名称扩展
extension Notification.Name {
    static let dockIconVisibilityChanged = Notification.Name("dockIconVisibilityChanged")
}

/// 菜单栏图标 + 菜单。窗口关掉后软件仍在后台跑，靠这里控制。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var state: AppState?
    private var cancellables = Set<AnyCancellable>()

    func install(state: AppState) {
        self.state = state
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // 运行状态 / 系统代理接管状态一变，菜单栏图标跟着变色，不用等用户点开菜单。
        // 蓝色只表示"代理已真正接管成功"（proxyReady），避免图标先变蓝但系统代理
        // 其实没设置上 —— 用户看到的蓝就该是真的好了。
        state.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
        state.$proxyReady
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
        // 自检结论变了也要刷图标：接管成功但自检未过的窗口保持橙，
        // 自检通过那一刻才转蓝（trayHealthy 的另一半输入）。
        state.$checkState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
        state.$tunProbeFailed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        // 监听程序坞图标可见性变化，同步菜单勾选状态
        NotificationCenter.default.publisher(for: .dockIconVisibilityChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let show = notification.object as? Bool,
                      let state = self.state else { return }
                state.config.showDockIcon = show
            }
            .store(in: &cancellables)

        applyIcon()

        // 菜单栏项在某些环境下会创建失败（比如菜单栏满了），这时得让用户知道，
        // 否则关掉窗口就再也找不到这个软件了。
        if statusItem?.button == nil {
            state.log("[系统] 菜单栏图标创建失败，请通过程序坞打开窗口")
        } else {
            state.log("[系统] 菜单栏图标已就绪")
        }
    }

    /// 配色收敛到 CloudIcon（Win 托盘同款两态：橙=未接管 / 蓝=已接管）
    static var offColor: NSColor { CloudIcon.offColor }
    static var onColor: NSColor { CloudIcon.onColor }

    private func refreshIcon() {
        applyIcon()
    }

    private func applyIcon() {
        guard let button = statusItem?.button, let state else { return }

        // Win 托盘同款图标直接引用打包资源：橙徽章=未接管，蓝徽章=已接管；
        // 18pt：菜单栏标准图标尺寸，22 在高密度菜单栏里略显笨重。
        // TUN 模式下系统代理恒未接管（已让位），但流量确实在走代理 ——
        // 与 Win tray_service 的 (proxyReady || tunActive) 同口径变蓝。
        // 蓝色再叠加"自检结论够格对外承诺"（trayHealthy）：接管成功但自检
        // 未过的窗口保持橙——蓝图标是对外的"一切正常"承诺（Win 拍板语义）。
        let ready = (state.proxyReady || (state.config.tunMode && state.isRunning)) && state.trayHealthy
        button.image = CloudIcon.statusIcon(ready: ready, size: 18)
        // 不设 toolTip：无 Dock 图标（accessory 模式）下，鼠标悬停后
        // tooltip 面板可能不消失，卡成菜单栏下方一个点不掉、点不动的幽灵窗。
        button.toolTip = nil
    }

    static func color(ready: Bool) -> NSColor { ready ? onColor : offColor }

    // 每次点开都重建，保证状态和服务器列表都是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let state else { return }

        // 界面被锁（激活页）：菜单只剩「显示应用」「退出应用」，代理开关、
        // 服务器切换、更新检查全部撤下（对齐 Win tray_service._rebuildMenu）。
        // 缩减口径与根视图共用 uiLocked——会话中途的 unreachable 不缩，否则
        // 一次网络抖动就把托盘掏空（那时隧道还跑着，代理开关点击自有一层
        // 校验兜底，被拦时亮窗说明原因）。
        // 动作分发器里还有第二道闸（见 toggleProxy 等）：原生菜单的重建要过
        // 一次菜单打开事件，授权刚被吊销到菜单刷新之间存在竞态窗口，那一下
        // 点击必须落空。
        if LicenseService.shared.uiLocked {
            add(menu, "显示应用", #selector(showApp))
            add(menu, "退出应用", #selector(quitApp))
            return
        }

        let ready = state.proxyReady
        let running = state.isRunning

        // 状态行：一个圆点 + 一句话，不堆细节。蓝色=已接管成功，与图标一致。
        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let dot = NSAttributedString(
            string: ready ? "● " : "○ ",
            attributes: [.foregroundColor: Self.color(ready: ready),
                         .font: NSFont.systemFont(ofSize: 13)])
        let text = NSAttributedString(
            string: ready ? "系统代理已接管" : (state.isRunning ? "代理运行中，系统代理未接管" : "ECH 代理未运行"),
            attributes: [.foregroundColor: NSColor.labelColor,
                         .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        let line = NSMutableAttributedString()
        line.append(dot)
        line.append(text)
        status.attributedTitle = line
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        add(menu, running ? "关闭 ECH 代理" : "开启 ECH 代理", #selector(toggleProxy))

        // TUN 模式（进阶选项：接管全量路由，需管理员权限；勾选态绑用户意图）
        let tun = NSMenuItem(title: "TUN 模式", action: #selector(toggleTunMode), keyEquivalent: "")
        tun.target = self
        tun.state = state.config.tunMode ? .on : .off
        menu.addItem(tun)

        // 选择服务器
        let serverItem = NSMenuItem(title: "选择服务器", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in state.config.servers {
            let mi = NSMenuItem(title: s.name.isEmpty ? "未命名" : s.name,
                                action: #selector(pickServer(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s.id
            mi.state = (s.id == state.selected?.id) ? .on : .off
            // 运行中切换服务器会重启代理换到新服务器生效（见 AppState.select）
            mi.isEnabled = true
            sub.addItem(mi)
        }
        serverItem.submenu = sub
        menu.addItem(serverItem)

        menu.addItem(.separator())

        add(menu, "检查更新…", #selector(checkUpdate))

        menu.addItem(.separator())

        // 显示应用在前，程序坞图标在后（用户指定的顺序）
        add(menu, "显示应用", #selector(showApp))

        let dock = NSMenuItem(title: "在程序坞显示图标",
                              action: #selector(toggleDockIcon), keyEquivalent: "")
        dock.target = self
        // 实时读取配置状态，确保勾选状态始终与实际同步
        dock.state = state.config.showDockIcon ? .on : .off
        menu.addItem(dock)

        add(menu, "退出应用", #selector(quitApp))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
    }

    @objc private func showApp() {
        // 后台模式保持 .accessory，别把程序坞图标强拉出来
        if state?.config.showDockIcon == true {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        // 只把主窗口拉出来。不能遍历 NSApp.windows 全部 orderFront——
        // 历史残留的隐藏空窗（accessory 模态的幽灵窗）会被一起显示出来。
        if let win = NSApp.windows.first(where: { $0.contentView != nil }) {
            win.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func toggleProxy() {
        Task { @MainActor in
            guard let state else { return }
            // 开关代理前先 force 校验（对齐 Win tray_service：托盘 ECH 代理
            // 点击前 verify）；blocked 时亮出主窗口让用户看到激活窗口
            guard await state.proxyActionAllowed() else {
                showApp()
                return
            }
            await state.toggle()
        }
    }

    @objc private func toggleTunMode() {
        guard let state else { return }
        // 动作级第二道闸：与菜单缩减同一把锁（uiLocked）
        if LicenseService.shared.uiLocked {
            showApp()
            return
        }
        // 开 TUN 要过提权弹窗，先亮出主窗口（对齐 Win tray：弹框别在后台出）
        if !state.config.tunMode { showApp() }
        state.setTunMode(!state.config.tunMode)
    }

    @objc private func toggleDockIcon() {
        guard let state else { return }
        let newValue = !state.config.showDockIcon
        state.setShowDockIcon(newValue)
        // 菜单打开时直接更新勾选状态，不用等下次打开菜单
        if let menu = statusItem?.menu,
           let item = menu.items.first(where: { $0.action == #selector(toggleDockIcon) }) {
            item.state = newValue ? .on : .off
        }
    }

    @objc private func pickServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        // 运行中切换服务器会重启代理换到新服务器生效——同样受授权门禁，
        // 界面被锁时点击落空并亮出激活窗口
        if LicenseService.shared.uiLocked {
            showApp()
            return
        }
        Task { await state?.select(id) }
    }

    /// 菜单栏的「检查更新」：同时检查软件新版本和分流数据
    @objc private func checkUpdate() {
        if LicenseService.shared.uiLocked {
            showApp()
            return
        }
        state?.checkEverything()
    }

    @objc private func quitApp() {
        state?.shutdown()
        NSApp.terminate(nil)
    }
}
