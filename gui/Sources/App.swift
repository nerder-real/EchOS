import SwiftUI
import AppKit

@main
struct ECHApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("EchOS") {
            ContentView()
                .environmentObject(app)
                .onAppear {
                    delegate.state = app
                    app.applyDockIconPolicy()
                    app.flushPendingLogs()
                    // 授权首验排在最前面：没激活过就不该起任何隧道相关的
                    // 初始化。首验落地前不自动恢复代理、不检查更新——
                    // 对齐 Win main(): bootstrap 先于一切代理动作。
                    Task { @MainActor in
                        await app.bootstrapLicense()
                        app.restoreProxyIfNeeded()
                        app.checkForUpdatesAtStartup()
                    }
                }
        }
        .defaultSize(width: 735, height: AppDelegate.minContentHeight)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var state: AppState? {
        didSet {
            guard let state, !statusBarInstalled else { return }
            statusBarInstalled = true
            statusBar.install(state: state)
        }
    }
    private let statusBar = StatusBarController()
    private var statusBarInstalled = false

    // 在窗口出现前读取配置，设好激活策略，避免 dock 图标闪一下或关不掉
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 单实例守卫：第二个实例把已运行实例的主窗口唤醒后自己立即退出，
        // 否则重复启动（DMG 挂载目录与 /Applications 各开一份等）会叠出
        // 多个菜单栏图标、多个内核进程抢端口与系统代理。
        guard InstanceGuard.claimOrWake() else { exit(0) }
        let cfg = AppConfig.load()
        NSApp.setActivationPolicy(cfg.showDockIcon ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 刚被自动更新重启过（标记文件里是新版本号）→ 不弹主窗口，
        // 只弹一个独立"更新完成"对话框，然后保持菜单栏常驻。
        if let justUpdated = Self.consumeUpdatedMarker() {
            // 窗口要等 SwiftUI 异步创建，延迟到出现后再隐藏 + 弹窗，
            // 否则 didFinishLaunching 时窗口还不存在，隐藏了个寂寞。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let win = NSApp.windows.first(where: { $0.contentView != nil }) {
                    // 这条路径平时不走主窗口配置块，minSize/delegate 在这里补齐
                    win.minSize = NSSize(width: Self.minContentWidth, height: Self.minContentHeight)
                    win.delegate = self
                    win.orderOut(nil)
                }
                self.showUpdateCompleteDialog(version: justUpdated)
            }
            return
        }

        // 被单实例守卫唤醒（第二个实例启动时发通知后自退）：拉起主窗口，
        // 与菜单栏「显示应用」同款动作
        InstanceGuard.observeWake { [weak self] in
            if self?.state?.config.showDockIcon == true {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            if let win = NSApp.windows.first(where: { $0.contentView != nil }) {
                win.makeKeyAndOrderFront(nil)
            }
        }
        // 系统从睡眠唤醒：定时器在休眠期间根本不跑，唤醒后立即复核授权，
        // 把「睡了几天回来发现已被吊销」的感知从下一次 tick 提前到秒级。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                _ = LicenseService.shared.verify(force: true, source: "系统唤醒")
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI 在纯 swiftc 构建（没有 Xcode 工程）下有时会把窗口收成很小一块，
        // 这里在主窗口出现后按内容需要的尺寸强制铺开并居中。
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
            // 只定宽度和最小尺寸；高度交给 ContentView 的 syncWindowHeight
            // 按当前内容算，免得两处各设一套值互相覆盖。
            // 这里用 minContentHeight（基准 819）兜底铺开，与 defaultSize/minSize
            // 保持一致，不再单写一个魔法数字 —— 那只会让三处尺寸互相打架。
            win.setContentSize(NSSize(width: Self.minContentWidth, height: Self.minContentHeight))
            // minSize 只挡"窗口被拖得太小"：拉到内容所需高度
            // 就停，底部操作行和日志不会被窗口底边盖住
            win.minSize = NSSize(width: Self.minContentWidth, height: Self.minContentHeight)
            win.delegate = self
            win.center()
            win.makeKeyAndOrderFront(nil)
            // 内容区顶部已经有居中的 EchOS 标题，标题栏再显示一次就重复了
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
        }
    }

    /// 更新完成标记文件路径：更新脚本替换完 /Applications 后写入，
    /// 新实例启动时读到就只弹"更新完成"、不打开主窗口。
    static var updatedMarkerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchOS/.updated-version", isDirectory: false)
    }

    /// 读取并删除更新标记。标记里的版本号等于当前版本才算数（防止旧标记残留误弹）。
    private static func consumeUpdatedMarker() -> String? {
        let url = updatedMarkerURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return v == current ? v : nil
    }

    private func showUpdateCompleteDialog(version: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "更新完成"
        alert.informativeText = "已升级到 v\(version)"
        alert.addButton(withTitle: "好")
        _ = AppState.runModalTopCentered(alert)
    }

    /// ContentView 算出的内容所需高度。窗口手动缩放时不能比它矮，
    /// 否则底部操作行和日志会被窗口底边盖住。
    /// 819 = 原基准 758 + 标题栏留白（上 50 + 下 35，净增 61pt）；
    /// 探针随后按实际内容修正，初值对齐终值避免启动页→主页面之间的高度跳变。
    static var minContentHeight: CGFloat = 819

    /// 窗口最小宽度。SwiftUI 的 frame(minWidth:) 只约束内容布局、拦不住
    /// 程序性缩放，AppKit 侧的 minSize 又只在启动时设一次（自动更新重启
    /// 路径会跳过）——以 windowWillResize 的钳制为准，两处都不会漏。
    static let minContentWidth: CGFloat = 735

    /// 用户最后一次手动拖拽结束后的窗口高度（0 = 从未拖过）。
    /// 只有 windowDidEndLiveResize（真正的用户拖拽）才写它，
    /// 程序 setFrame 不会触发。syncWindowHeight 靠它区分「用户拉高」
    /// 和「内容自己变矮但窗口没跟上」，避免把后者误当成前者而拒绝缩回。
    static var lastUserResizeHeight: CGFloat = 0

    // 拖拽窗口时的硬约束：宽度不低于 minContentWidth，高度不低于内容所需
    // 高度（minSize 之外的兜底——minSize 只在启动时设一次，靠不住）
    @objc func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var s = frameSize
        if s.width < Self.minContentWidth { s.width = Self.minContentWidth }
        let floor = max(Self.minContentHeight, sender.minSize.height)
        if s.height < floor - 0.5 { s.height = floor }
        return s
    }

    /// 用户拖拽结束后记下最终高度，供 syncWindowHeight 判断手动拉伸。
    @objc func windowDidEndLiveResize(_ notification: Notification) {
        if let win = notification.object as? NSWindow {
            Self.lastUserResizeHeight = win.frame.height
        }
    }

    // 移动/缩放窗口时，底边不许越过可见区域底部（否则日志会被 Dock 遮住）
    @objc func windowDidMove(_ notification: Notification) { clampBottom(notification.object as? NSWindow) }
    @objc func windowDidResize(_ notification: Notification) { clampBottom(notification.object as? NSWindow) }

    private func clampBottom(_ win: NSWindow?) {
        guard let win, let screen = win.screen else { return }
        let minY = screen.visibleFrame.minY
        guard win.frame.minY < minY - 0.5 else { return }
        var f = win.frame
        f.origin.y = minY
        win.setFrame(f, display: true)
    }

    // 关窗口不退出：代理继续在后台跑，靠菜单栏图标控制
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 点红色关闭按钮：只隐藏窗口，不销毁。
    // 若真的 close，SwiftUI 的 WindowGroup 会在 App 被激活时（比如点菜单栏
    // 「检查更新」）自动把主窗口恢复出来，弹独立更新对话框时就会多带出主页面。
    //
    // 例外：界面被锁（激活页）时关窗 = 完整退出。留在菜单栏等于留一条
    // 绕开激活窗口的路——关掉窗口再从菜单栏「显示应用」，回来的是同一个
    // 激活窗口，可这中间他完全可以去点别的入口。且不能裸退出：用户可能是
    // 开着隧道时后台复查判定被吊销的，此刻系统代理还接管着，直接退出会给
    // 这台机器留下一个打不开网页的代理设置——走 shutdown 那套完整收尾
    // （停内核 → 还原系统代理 → 排空日志）。
    // 口径用 uiLocked（与根视图、菜单栏同一把锁）：会话中途的「连不上授权
    // 服务器」不算锁，照常隐藏窗口；但**启动即断网且从未可用**要锁——那台
    // 机器没有可保的会话，关窗照锁定口径退出。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if LicenseService.shared.bootstrapped && LicenseService.shared.uiLocked {
            state?.shutdown()
            NSApp.terminate(nil)
            return false
        }
        sender.orderOut(nil)
        return false
    }

    // 主窗口每次成为 key（启动首屏 / 菜单栏唤起 / 回前台）都补一发校验，
    // 击穿 TTL——托盘常驻的应用可能几天不获得焦点，回到前台必须再问一次。
    func windowDidBecomeKey(_ notification: Notification) {
        _ = LicenseService.shared.verify(force: true, source: "窗口显示")
    }

    // App 整体回到前台（点菜单栏、点 Dock、对话框关闭等）：与窗口 show
    // 双保险，任一事件来了都复核一次授权。
    func applicationDidBecomeActive(_ notification: Notification) {
        _ = LicenseService.shared.verify(force: true, source: "回前台")
    }

    // 退出前一定要把系统代理还原回去，否则用户会"断网"
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { state?.shutdown() }
    }
}
