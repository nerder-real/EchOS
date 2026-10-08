import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var renaming = false
    @State private var renameText = ""
    /// 命名/改名的错误提示（重名、空名、超长）
    @State private var nameErrorText = ""
    @State private var showNameError = false
    /// 当前服务器还没保存过就想新建下一个
    @State private var addNewBlocked = false
    @State private var confirmDelete = false
    @State private var rulesExpanded = false
    @State private var ruleSearch = ""
    /// 保存按钮的结果弹窗
    @State private var showSaveResult = false
    @State private var saveResultOK = false
    @State private var saveResultText = ""
    /// 分享服务器的多选弹窗
    @State private var showShare = false
    /// WebDAV 设置弹窗
    @State private var showWebDAV = false
    /// 本地还原前二次确认
    @State private var confirmRestoreLocal = false
    @State private var pendingRestoreURL: URL?
    /// WebDAV 还原前二次确认
    @State private var confirmWebDAVRestore = false
    /// 删除远程 WebDAV 备份前二次确认
    @State private var confirmWebDAVDelete = false
    /// 分享/备份按钮弹出 NSMenu 的 action 目标
    @State private var menuTarget = MenuActionTarget()

    private let labelWidth: CGFloat = 82

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    titleBar
                        .padding(.horizontal, 16)

                    // 配置区按内容自然排布，不用滚动条。窗口最小高度由
                    // syncWindowHeight 跟着内容一起定，拉到下限就停，
                    // 底部操作行和日志永远不会被窗口底边盖住。
                    VStack(alignment: .leading, spacing: 12) {
                        serverGroup
                        coreGroup
                        optionalGroup()
                    }
                    .padding(.horizontal, 16)

                    // 固定间隔，不参与空间分配
                    Color.clear.frame(height: 10)

                    // 底部固定区。日志区弹性高度：窗口被拉高时它跟着变高
                    // （多几行日志），缩回时不低于最少 4 行。底部边距固定。
                    // 日志展开时整块锚定到底部，弹性日志撑满、贴底；
                    // 日志折叠时保持自然高度紧贴配置区，多余空间落到窗口底部，
                    // 不会在「规则」和底部操作行之间挤出中间空白。
                    VStack(alignment: .leading, spacing: 10) {
                        actionRow
                        logSection()
                    }
                    .frame(maxHeight: app.config.logVisible ? .infinity : nil,
                           alignment: .bottom)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                // 高度跟窗口走：窗口高度由 syncWindowHeight 按内容精确设定，
                // 日志区是弹性块，吃掉窗口比内容多的那点余量，永远贴底
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                // 隐藏探针：镜像内容但用 fixedSize 测「理想高度」，
                // 不随窗口拉伸变化（日志区按固定槽位算，不按实际渲染高度）。
                layoutProbe(width: geo.size.width)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 735, minHeight: 620)
        .onPreferenceChange(ContentHeightKey.self) { contentIdealHeight = $0 }
        .onChange(of: contentIdealHeight) { _ in syncWindowHeight() }
        .onAppear {
            // 服务器列表为空（全新安装，或配置文件里没有服务器）：直接建一个
            // 待起名的服务器并弹命名框，不显示「还没有服务器」空态 ——
            // 第一次操作就是给服务器起名字。
            if app.config.servers.isEmpty {
                app.addServer()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { syncWindowHeight() }
        }
        .onChange(of: rulesExpanded) { _ in syncWindowHeight() }
        .onChange(of: app.config.logVisible) { _ in syncWindowHeight() }
        .onChange(of: app.selected?.customRules.count ?? 0) { _ in syncWindowHeight() }
        .onChange(of: app.needsNameInput) { need in
            if need {
                app.needsNameInput = false
                renameText = ""
                nameErrorText = ""
                renaming = true
            }
        }
        .alert(
            (app.selected?.name.isEmpty ?? true) ? "新建服务器名称" : "重命名服务器",
            isPresented: $renaming
        ) {
            TextField("例如：xx服务器", text: renameBinding)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let err = app.rename(to: renameText) {
                    nameErrorText = err
                    showNameError = true
                }
            }
        } message: {
            Text((app.selected?.name.isEmpty ?? true)
                 ? "服务器名称最多支持8个汉字/16个字符"
                 : "输入新名字，回车确认。")
        }
        .alert("无法使用这个名字", isPresented: $showNameError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(nameErrorText)
        }
        .alert("当前服务器状态未确认", isPresented: $addNewBlocked) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请填写完整参数后「保存」。\n如不需要，请「删除」当前服务器。")
        }
        .alert("删除服务器？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { app.deleteSelected() }
        } message: {
            Text(app.config.servers.count <= 1
                 ? "将清空「\(app.selected?.name ?? "")」的配置并重建一个空白服务器，不可撤销。"
                 : "将删除「\(app.selected?.name ?? "")」及其配置，不可撤销。")
        }
        .alert(saveResultOK ? "配置已保存" : "保存失败", isPresented: $showSaveResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveResultText)
        }
        // 启动失败等错误：窗口可能关着，必须弹窗
        .alert(app.alertTitle, isPresented: Binding(
            get: { app.alertMessage != nil },
            set: { if !$0 { app.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { app.alertMessage = nil }
        } message: {
            Text(app.alertMessage ?? "")
        }
        // 端口被占用：问一句是否强制结束占用进程后继续启动
        .alert("端口被占用", isPresented: Binding(
            get: { app.pendingPortConflict != nil },
            set: { if !$0 { app.cancelPortConflict() } }
        )) {
            Button("取消", role: .cancel) { app.cancelPortConflict() }
            Button("强制结束并启动", role: .destructive) { app.resolvePortConflictByKilling() }
        } message: {
            Text((app.pendingPortConflict.map {
                "\($0.label) 端口 \($0.port) 被 \($0.name)(PID \($0.pid)) 占用。\n强制结束该进程后将继续启动代理，该进程会立即退出。"
            }) ?? "")
        }
        .alert("从本地文件还原配置？", isPresented: $confirmRestoreLocal, presenting: pendingRestoreURL) { url in
            Button("取消", role: .cancel) {}
            Button("还原", role: .destructive) { Task { await app.restoreConfigLocal(from: url) } }
        } message: { _ in
            Text("当前全部配置（服务器、分流规则、偏好）都会被这份备份覆盖。\n代理运行中会先停止。")
        }
        .alert("从 WebDAV 还原配置？", isPresented: $confirmWebDAVRestore) {
            Button("取消", role: .cancel) {}
            Button("还原", role: .destructive) { Task { await app.restoreFromWebDAV() } }
        } message: {
            Text("当前全部配置（服务器、分流规则、偏好）都会被 WebDAV 上的备份覆盖。\n代理运行中会先停止。")
        }
        .alert("删除远程WebDAV备份？", isPresented: $confirmWebDAVDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await app.deleteWebDAVBackup() } }
        } message: {
            Text("将删除 WebDAV 服务器上的备份文件，本地配置不受影响。\n备份文件不存在时视为已删除。")
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(show: $showShare)
                .environmentObject(app)
        }
        .sheet(isPresented: $showWebDAV) {
            WebDAVSettingsView(show: $showWebDAV)
                .environmentObject(app)
        }
    }

    private let titleBarHeight: CGFloat = 56

    /// 把窗口高度调到刚好装下当前内容。
    ///
    /// 数字是"按内容拼出来"的：规则收起是一个基准高度；
    /// 展开后规则列表每加一条多一行的位置，超过 3 条列表不再变高、
    /// 只多一条搜索框。日志区是弹性块，窗口比内容多的那点余量
    /// 全给它，所以底部边距固定，不会上漂也不会和页面底边重叠。
    /// 上一次程序把窗口高度设成的值。用来区分「用户手动拉高」和
    /// 「程序因为内容变化而长高」：窗口比 lastSetHeight 还高，就说明
    /// 是用户手动拉的，尊重它，不去缩回。
    @State private var lastSetHeight: CGFloat = 0

    /// 日志区高度的理想下限与探针槽位（保底 4 行）。
    /// 展开时窗口按「内容 + 槽位」配高，规则把内容顶高时日志至少保住这 4 行；
    /// 用户手动拉高窗口时，真实日志区才是弹性块、吃满余量多显示几行。
    /// 10.5pt 等宽字实测行高 13.0pt，LazyVStack 1pt 间距 → 每行占 14pt。
    /// 槽位 = 4×14 = 56（内边距在滚动区外面，不算内容高）：
    /// 滚到底正好显示完整 4 行，第 5 行只从滚动条可见，不会露残影。
    private let logSlotHeight: CGFloat = 56

    /// 极端小屏下日志区允许再压到的硬下限（约 1 行）。
    /// 只在「内容超出屏幕可见区」时启用；正常屏幕（含规则全展开）都能装下时，
    /// 日志始终是 logSlotHeight（4 行）。宁可把日志压到 1 行，也不让窗口
    /// 溢出屏幕或裁掉底边 —— 底边距在任何状态下都保持固定。
    private let logFloorHeight: CGFloat = 16

    /// 屏幕可见区能容纳的窗口最大高度（扣菜单栏+Dock 各留 20pt）。
    /// 由 syncWindowHeight 每次同步时写入，日志区用它判断要不要压缩保底行数。
    @State private var screenMaxH: CGFloat = .infinity

    /// 标题栏占位高度：窗口 frame 比 contentLayoutRect 多出的那截。
    /// 压缩日志用的内容上限 = screenMaxH - titlebarInset，
    /// 不减去它就会把超出量算少，日志压不够、底边照样被窗口裁掉。
    @State private var titlebarInset: CGFloat = 28

    /// 日志区实际保底高度：内容不超屏就是 logSlotHeight（4 行）；
    /// 超屏（小屏 + 规则全展开）时把超出量从日志区扣掉，压到 logFloorHeight 为止，
    /// 保证窗口贴屏幕装下、底边不被裁掉，而不是把日志硬挤出画面。
    private var logMinHeight: CGFloat {
        let contentCap = screenMaxH - titlebarInset
        return max(logFloorHeight, logSlotHeight - max(0, contentIdealHeight - contentCap))
    }

    /// 隐藏探针测出的内容理想高度：展开 = 内容 + 日志槽位，折叠 = 内容。
    /// 窗口高度始终贴着这个值，展开/折叠/规则变化都由它驱动，不再手算各种增量。
    @State private var contentIdealHeight: CGFloat = 688

    /// 内容理想高度的 PreferenceKey，由隐藏探针上报
    struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 688
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private func syncWindowHeight() {
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { $0.contentView != nil }),
                  let screen = win.screen else { return }

            let current = win.frame.size.height
            let collapsed = !app.config.logVisible

            // 窗口 frame 高度 = 内容所需高度 + 标题栏占位。
            // contentLayoutRect 是不含标题栏的可放内容区域，frame 比它多出的
            // 高度就是标题栏（透明隐藏也占 28pt）。不补上这段，内容会把底部
            // 挤出窗口 —— 日志区下半截就会被窗口底边盖住。
            let titlebar = max(0, current - win.contentLayoutRect.height)
            titlebarInset = titlebar

            var h = contentIdealHeight + titlebar

            let maxH = max(0, screen.visibleFrame.height - 40)
            screenMaxH = maxH
            if h > maxH { h = maxH }

            AppDelegate.minContentHeight = h
            win.minSize = NSSize(width: 735, height: h)

            // 手动拉伸保护：只有用户真拖过窗口（windowDidEndLiveResize 记下的
            // 高度）才保持用户拉高的高度；内容自己变矮但窗口没跟上时不算
            // 手动拉伸，要跟着内容缩回来 —— 否则日志会被多出来的空档撑成 5 行。
            if !collapsed {
                let userH = AppDelegate.lastUserResizeHeight
                if userH > 0 && abs(current - userH) <= 2 && h <= current + 1 {
                    // 窗口停在用户拖过的位置：保持原样，只更新最小高度并重新居中。
                    // 内容若是已经超过这个高度（h > current），就不保持、跟着长。
                    centerWindow(screen: screen, height: current)
                    lastSetHeight = h
                    return
                }

                // 高度没变化：只重新居中，不折腾尺寸
                if lastSetHeight > 0 && abs(current - h) <= 4 {
                    centerWindow(screen: screen, height: current)
                    return
                }
            }

            var f = win.frame
            f.size.height = h
            win.setFrame(f, display: true, animate: false)
            centerWindow(screen: screen, height: h)
            lastSetHeight = h
        }
    }

    /// 在可见区（扣除菜单栏 + Dock）内把窗口垂直水平居中。
    private func centerWindow(screen: NSScreen, height: CGFloat) {
        guard let win = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
        let vf = screen.visibleFrame
        var f = win.frame
        f.size.height = height
        f.origin.x = vf.midX - f.size.width / 2
        f.origin.y = vf.midY - height / 2
        win.setFrame(f, display: true, animate: false)
    }

    // MARK: - 分享 / 备份面板

    private func importServersFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.importServers(from: url)
    }

    private func backupToLocalPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "EchOS-备份-\(Self.dateStamp()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.backupConfigLocal(to: url)
    }

    private func restoreFromLocalPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
        confirmRestoreLocal = true
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// 「保存」按钮：有错不落盘，并弹窗说明原因；成功也弹窗确认。
    private func saveSelected() {
        let err = app.saveCurrentServer()
        saveResultOK = (err == nil)
        saveResultText = err ?? "配置已写入本地。"
        showSaveResult = true
    }

    /// 带底色实心按钮。
    ///
    /// macOS 的 borderedProminent 在窗口失去焦点时会整体变灰，
    /// 这里用固定背景色，失焦也不变色。文字用 .primary，跟随系统模式
    /// （亮色黑字、暗色白字），和「新增/重命名」保持一致。
    private func persistentTint<Label: View>(
        _ color: Color,
        isActive: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
                .opacity(isActive ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
    }

    // MARK: - 标题栏

    private var titleBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Image(systemName: "cloud.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [Color.cloudflareOrange, Color.cloudflareOrange.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom))
            Text("EchOS")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Spacer()
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    // MARK: - 服务器管理

    private var serverGroup: some View {
        group("服务器管理", icon: "server.rack", tint: .blue) {
            HStack(spacing: 8) {
                Text("选择服务器:")
                    .font(.system(size: 12))
                    .frame(width: labelWidth, alignment: .leading)

                if app.config.servers.isEmpty {
                    Text("还没有服务器：点「新增」开始创建")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    NativePopupSelect(
                        selection: Binding(
                            get: { app.config.selectedID ?? app.config.servers.first?.id ?? UUID() },
                            set: { id in Task { await app.select(id) } }
                        ),
                        options: app.config.servers.enumerated().map {
                            (title: $0.element.name.isEmpty ? "未命名 \($0.offset + 1)" : $0.element.name, value: $0.element.id)
                        }
                    )
                    // 运行中切换服务器会重启代理换到新服务器生效（见 AppState.select）
                }

                Button("新增") {
                    if !app.hasUncommittedServer {
                        app.addServer()
                    } else {
                        addNewBlocked = true
                    }
                }
                .disabled(app.isRunning)
                Button("重命名") {
                    renameText = app.selected?.name ?? ""
                    nameErrorText = ""
                    renaming = true
                }
                .disabled(app.isRunning)
                persistentTint(app.isServerDirty ? .orange : .green,
                               isActive: !app.isRunning) {
                    saveSelected()
                } label: {
                    Text("保存")
                }
                persistentTint(.red, isActive: !app.isRunning) {
                    confirmDelete = true
                } label: {
                    Text("删除")
                }

                Spacer()

                // 分享：导出选中的服务器 / 从分享文件导入。
                // 用普通 Button + NSMenu，而不是 SwiftUI Menu —— 后者标签渲染会缩放图标、
                // 改间距，和「自检」对不齐。
                Button {
                    menuTarget.onShareExport = { showShare = true }
                    menuTarget.onShareImport = { importServersFromPanel() }
                    let menu = NSMenu()
                    let export = NSMenuItem(title: "选择并导出服务器…", action: #selector(MenuActionTarget.shareExport), keyEquivalent: "")
                    export.target = menuTarget
                    let imp = NSMenuItem(title: "导入服务器…", action: #selector(MenuActionTarget.shareImport), keyEquivalent: "")
                    imp.target = menuTarget
                    menu.addItem(export)
                    menu.addItem(imp)
                    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .labelStyle(TintedIconLabelStyle(color: .blue))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 导出/导入只读写服务器数据，不影响运行中的代理，运行中也可用

                // 备份：整份配置本地 / WebDAV
                Button {
                    menuTarget.onBackupLocal = { backupToLocalPanel() }
                    menuTarget.onRestoreLocal = { restoreFromLocalPanel() }
                    menuTarget.onWebDAVSettings = { showWebDAV = true }
                    menuTarget.onBackupWebDAV = { Task { await app.backupToWebDAV() } }
                    menuTarget.onRestoreWebDAV = { confirmWebDAVRestore = true }
                    menuTarget.onDeleteWebDAV = { confirmWebDAVDelete = true }
                    let menu = NSMenu()
                    let bl = NSMenuItem(title: "备份到本地文件…", action: #selector(MenuActionTarget.backupLocal), keyEquivalent: "")
                    bl.target = menuTarget
                    let rl = NSMenuItem(title: "从本地文件还原…", action: #selector(MenuActionTarget.restoreLocal), keyEquivalent: "")
                    rl.target = menuTarget
                    let ws = NSMenuItem(title: "WebDAV 设置…", action: #selector(MenuActionTarget.webdavSettings), keyEquivalent: "")
                    ws.target = menuTarget
                    let bw = NSMenuItem(title: "备份到远程WebDAV", action: #selector(MenuActionTarget.backupWebDAV), keyEquivalent: "")
                    bw.target = menuTarget
                    let rw = NSMenuItem(title: "从远程WebDAV还原备份", action: #selector(MenuActionTarget.restoreWebDAV), keyEquivalent: "")
                    rw.target = menuTarget
                    let dw = NSMenuItem(title: "删除远程WebDAV备份", action: #selector(MenuActionTarget.deleteWebDAV), keyEquivalent: "")
                    dw.target = menuTarget
                    menu.addItem(bl)
                    menu.addItem(rl)
                    menu.addItem(.separator())
                    menu.addItem(ws)
                    menu.addItem(bw)
                    menu.addItem(rw)
                    menu.addItem(dw)
                    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                } label: {
                    Label(app.webdavBusy ? "备份中…" : "备份", systemImage: "externaldrive")
                        .labelStyle(TintedIconLabelStyle(color: .yellow))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 备份/还原不影响运行中的代理（还原会先停代理并提示），运行中也可用
                .disabled(app.webdavBusy)

                Button {
                    app.runSelfCheck()
                } label: {
                    Label(app.checking ? "检测中" : "自检", systemImage: "checkmark.seal.fill")
                        .labelStyle(TintedIconLabelStyle(color: selfCheckTint))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 任何状态都能点：代理运行时跑完整连通性检测，未启动时预检
                // 服务端/DoH 可达性（人工确认配置能不能用），只有检测进行中置灰
                .disabled(app.checking)
            }
        }
    }

    // MARK: - 核心配置

    private var coreGroup: some View {
        group("核心配置", icon: "gearshape.fill", tint: .indigo) {
            VStack(spacing: 8) {
                maskedHostPortRow("服务器地址:", host: binding(\.server), port: intBinding(\.serverPort),
                                  hostPlaceholder: "xxx.workers.dev")
                maskedRow("TOKEN(可选):", binding(\.token), placeholder: "")
                hostPortRow("监听地址:", host: binding(\.listen), port: intBinding(\.listenPort),
                            hostPlaceholder: "127.0.0.1")
                row("优选域名(IP):", binding(\.ip), placeholder: "cdns.doon.eu.org")
            }
        }
    }

    // MARK: - 高级选项

    private func optionalGroup(rulesForcedExpanded: Bool = false) -> some View {
        group("高级选项", icon: "slider.horizontal.3", tint: .orange) {
            VStack(spacing: 8) {
                presetRow("ECH域名:", binding(\.ech), options: EchPresets.echDomains,
                          placeholder: "cloudflare-ech.com")
                presetRow("DOH服务器:", binding(\.dns), options: EchPresets.dnsServers,
                          placeholder: "dns.alidns.com/dns-query")

                HStack(spacing: 8) {
                    Text("分流模式:")
                        .font(.system(size: 12.5))
                        .frame(width: labelWidth, alignment: .leading)

                    ModeSegment(
                        selection: Binding(
                            get: { app.config.routeMode },
                            set: { v in Task { await app.switchRouteMode(v) } }
                        ),
                        disabled: false
                    )
                }

                Divider().padding(.vertical, 2)
                customRulesSection(forcedExpanded: rulesForcedExpanded)
            }
        }
    }

    // MARK: - 自定义分流规则

    private func customRulesSection(forcedExpanded: Bool = false) -> some View {
        let rules = app.selected?.customRules ?? []
        let shadowed = rules.shadowedIDs
        let filtered = ruleSearch.isEmpty ? rules : rules.filter { r in
            // 搜目标本身、类型名，以及分类的中文标签 ——
            // 用户记得的是"YouTube"，不是 geosite:youtube
            let label = RuleCategory.all.first { $0.value == r.target }?.label ?? ""
            return r.target.localizedCaseInsensitiveContains(ruleSearch)
                || r.kind.title.contains(ruleSearch)
                || label.localizedCaseInsensitiveContains(ruleSearch)
        }

        return DisclosureGroup(isExpanded: forcedExpanded ? Binding.constant(true) : $rulesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                // 规则一多，靠滚动翻找很费劲，给个搜索框（超过 2 条就出）
                if rules.count > 2 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        TextField("搜索规则", text: $ruleSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !ruleSearch.isEmpty {
                            Button {
                                ruleSearch = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // 规则列表自己限高滚动。指望外层容器兜底是不行的：
                // 规则能加任意多条，展开后会把整个配置区顶破，
                // 挤到下面的操作行上（之前就是这么重叠的）。
                if !filtered.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(filtered) { rule in
                                ruleRow(rule, isShadowed: shadowed.contains(rule.id))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    // 高度跟着条数走，最多 2 行；再多就在列表内部滚动，
                    // 不去牵动整页布局。行高固定 30，正好装下 2 行（60+12 间隔+4 内边距），
                    // 第 3 条起点在 74 超过 70，被彻底裁掉，不会露出半截。
                    .frame(height: CGFloat(min(filtered.count, 2)) * 36 - 2)
                    .clipped()
                }

                if !ruleSearch.isEmpty && filtered.isEmpty {
                    Text("没有匹配「\(ruleSearch)」的规则")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                ruleFooter(count: rules.count, shadowedCount: shadowed.count)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("自定义分流规则")
                    .font(.system(size: 12.5))
                if !rules.isEmpty {
                    Text("\(rules.count) 条")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if !shadowed.isEmpty {
                    Label("\(shadowed.count) 条重复", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(.orange)
                }
                if app.rulesDirty {
                    Label("待重启", systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundColor(.orange)
                }

                Spacer()

                Button {
                    app.addRule()
                    rulesExpanded = true
                } label: {
                    Label("添加规则", systemImage: "plus").font(.system(size: 11.5))
                }
                .controlSize(.small)
                // 折叠标题整行是点击区，按钮得自己拦下点击，否则会连带展开/收起
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: CustomRule, isShadowed: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { rule.kind },
                set: { app.updateRule(rule.id, kind: $0) }
            )) {
                ForEach(RuleKind.allCases) { k in Text(k.title).tag(k) }
            }
            .labelsHidden()
            .frame(width: 96)

            if rule.kind == .category {
                Picker("", selection: Binding(
                    get: { rule.target },
                    set: { app.updateRule(rule.id, target: $0) }
                )) {
                    ForEach(RuleCategory.all) { c in Text(c.label).tag(c.value) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            } else {
                TextField(rule.kind.placeholder, text: Binding(
                    get: { rule.target },
                    set: { app.updateRule(rule.id, target: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 24)
            }

            Picker("", selection: Binding(
                get: { rule.action },
                set: { app.updateRule(rule.id, action: $0) }
            )) {
                Text("直连").tag("direct")
                Text("代理").tag("proxy")
                Text("拦截").tag("block")
            }
            .labelsHidden()
            .frame(width: 82)

            if isShadowed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            Button {
                app.removeRule(rule.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
        }
        // 固定行高：规则列表的容器高度按它精确计算，第 4 条完全藏在滚动区里
        .frame(height: 30)
        .opacity(isShadowed ? 0.55 : 1)
    }

    @ViewBuilder
    private func ruleFooter(count: Int, shadowedCount: Int) -> some View {
        HStack(spacing: 8) {
            if count == 0 {
                Text("点右上角「添加规则」，选类型后填域名，或直接挑一个网站分类")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if app.rulesDirty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundColor(.orange)
                Text("规则已保存，重启代理才生效")
                    .font(.system(size: 11)).foregroundColor(.orange)
                Button("立即重启") { Task { await app.applyRules() } }
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10.5)).foregroundColor(.green)
                Text(app.isRunning ? "规则已生效" : "规则已保存，启动代理后生效")
                    .font(.system(size: 10.5)).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 按钮行

    private var actionRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Toggle("开机启动", isOn: Binding(
                    get: { app.launchAtLogin },
                    set: { app.setLaunchAtLogin($0) }
                ))

                Toggle("自动设置系统代理", isOn: Binding(
                    get: { app.config.autoSystemProxy },
                    set: { v in app.setAutoSystemProxy(v) }
                ))

                Spacer()

                persistentTint(.blue, isActive: !app.isRunning && !app.isStarting) {
                    app.start()
                } label: {
                    Label("启动代理", systemImage: "play.fill")
                        .frame(width: 84, height: 30)
                }
                .keyboardShortcut(.return, modifiers: .command)

                persistentTint(.red, isActive: app.isRunning || app.isStarting) {
                    Task { await app.stop() }
                } label: {
                    Label("停止代理", systemImage: "stop.fill")
                        .frame(width: 84, height: 30)
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))

            // 运行状态：圆点同时承担"自检结果"的角色
            HStack(spacing: 7) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 10, height: 10)
                Text(app.statusText)
                    .font(.system(size: 12))
                    .foregroundColor(app.isRunning ? .primary : (app.isStarting ? .secondary : .secondary))
                    .lineLimit(1)
                if app.isRunning || app.isStarting {
                    Text(checkLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - 自检状态呈现

    /// 自检按钮图标的颜色，跟状态灯（statusDotColor）保持一致：
    /// 没测过是中性色，检测中置灰，通过才绿、失败才红。
    /// 之前改成"不在检测就是绿"，结果一启动图标就绿着，自检记录却是空的，
    /// 明摆着没跑过却装成通过的样子，误导。
    private var selfCheckTint: Color {
        if app.checking { return .secondary }
        switch app.checkState {
        case .idle:    return .accentColor
        case .running: return .yellow
        case .ok:      return .green
        case .failed:  return .red
        }
    }

    private var statusDotColor: Color {
        if app.isStarting { return .yellow }
        guard app.isRunning else { return .cloudflareOrange }
        switch app.checkState {
        case .idle:    return .accentColor
        case .running: return .yellow
        case .ok:      return .green
        case .failed:  return .red
        }
    }

    private var checkLabel: String {
        if app.isStarting { return "· 启动中…" }
        switch app.checkState {
        case .idle:    return "· 待检测"
        case .running: return "· 检测中…"
        case .ok:      return "· 自检通过"
        case .failed:  return "· 自检未通过"
        }
    }

    // MARK: - 运行日志

    /// 日志标题行：折叠按钮 + 级别选择 + 日志文件 + 清空。
    /// 折叠日志时这一行常驻，探针也复用它来量「日志头部」的高度。
    private var logHeaderRow: some View {
        HStack(spacing: 10) {
            Button {
                app.config.logVisible.toggle()
                app.persist()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: app.config.logVisible ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(app.config.logLevel == .checkOnly ? "自检记录" : "运行日志")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 折叠只收起日志内容；级别/日志文件/清空这些控制项保持常驻，
            // 不会跟着内容一起消失
            NativePopupSelect(
                selection: Binding(
                    get: { app.config.logLevel },
                    set: { v in app.config.logLevel = v; app.persist() }
                ),
                options: LogLevel.allCases.map { (title: $0.title, value: $0) },
                controlSize: .small
            )
            .frame(width: 96)

            Button {
                // 打开当前视图对应的那个文件，而不是永远打开运行日志
                let url = app.config.logLevel == .checkOnly ? LogFile.checkURL : LogFile.currentURL
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("日志文件", systemImage: "folder")
            }

            Button {
                app.clearLog()
            } label: {
                Label("清空", systemImage: "trash")
            }
        }
        .controlSize(.small)
    }

    private func logSection() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            logHeaderRow

            if app.config.logVisible {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(app.displayedLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(color(for: line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .onChange(of: app.logLines.count) { _ in
                        if let last = app.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                // 内边距放在滚动区外面，不占滚动内容高度：
                // 内容高 = 行数 × 14（13pt 字 + 1pt 间距），视图高 = 槽位 = 4×14 = 56，
                // 滚到底正好显示完整 4 行，不会多露一行残影。
                .frame(minHeight: logMinHeight, maxHeight: .infinity)
                .padding(8)
                .frostedCard()
            }
        }
    }

    /// 隐藏探针：与真实内容同构，但日志滚动区按固定槽位估算，并用 fixedSize
    /// 量「理想高度」—— 这个高度跟窗口实际被拉多高无关，是内容真实需要的。
    /// 窗口高度由它驱动（见 syncWindowHeight），展开/折叠/规则变化自动适配。
    private func layoutProbe(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
                .padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 12) {
                serverGroup
                coreGroup
                optionalGroup()
            }
            .padding(.horizontal, 16)

            Color.clear.frame(height: 10)

            VStack(alignment: .leading, spacing: 10) {
                actionRow
                VStack(alignment: .leading, spacing: 5) {
                    logHeaderRow
                    if app.config.logVisible {
                        // 槽位必须用能贡献实际高度的视图：Color.clear 在 fixedSize
                        // 下理想尺寸是 0，量出来日志区永远不占位，窗口就不跟随展开了。
                        // padding(8) 要跟真实布局一致：真实日志滚动区外套 8pt 内边距，
                        // 探针不补这段，窗口就会比内容矮 16pt，卡片底边被窗口裁掉。
                        Text(" ").frame(width: width, height: logSlotHeight).padding(8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(width: width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) { GeometryReader { p in
            Color.clear.preference(key: ContentHeightKey.self, value: p.size.height)
        } }
        .opacity(0)
    }

    // MARK: - 复用组件

    /// 分组卡片：左侧一个带色的图标块 + 标题，内容区磨砂玻璃
    @ViewBuilder
    private func group<C: View>(_ title: String, icon: String, tint: Color,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            content()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frostedCard()
        }
    }

    /// 整行：标签 + 撑满的输入框
    @ViewBuilder
    private func row(_ label: String, _ text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(height: 24)
        }
    }

    /// 半行：标签 + 输入框，用于同一行放两组
    @ViewBuilder
    private func labeled(_ label: String, _ text: Binding<String>,
                         placeholder: String, labelWidth: CGFloat? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth ?? self.labelWidth, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(height: 25)
        }
    }

    /// 主机名 + 端口分成两个输入框：端口独立成框，用户就不会因为
    /// 把冒号打成全角"："而连不上，也省得程序去猜他到底想输入什么。
    @ViewBuilder
    private func hostPortRow(_ label: String, host: Binding<String>, port: Binding<Int>,
                             hostPlaceholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth, alignment: .leading)
            TextField(hostPlaceholder, text: host)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            Text("端口：")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TextField("", value: port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(width: 96, height: 24)
                .multilineTextAlignment(.center)
        }
    }

    /// 敏感单行：原生 TextField，不聚焦时用圆点盖住明文；点击聚焦后正常显示编辑。
    @ViewBuilder
    private func maskedRow(_ label: String, _ text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth, alignment: .leading)
            MaskedField(text: text, placeholder: placeholder)
        }
    }

    /// 敏感主机名 + 端口：主机名圆点遮盖，端口保持可见（端口不是秘密）。
    @ViewBuilder
    private func maskedHostPortRow(_ label: String, host: Binding<String>, port: Binding<Int>,
                                   hostPlaceholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth, alignment: .leading)
            MaskedField(text: host, placeholder: hostPlaceholder)
            Text("端口：")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TextField("", value: port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(width: 96, height: 24)
                .multilineTextAlignment(.center)
        }
    }

    /// 敏感字段：保存后显示圆点掩码；点击/聚焦后显示原文可编辑，失焦回到掩码。
    /// TextField 放底层、掩码文本放顶层（allowsHitTesting(false) 不拦截点击），
    /// 否则掩码会被 TextField 圆角边框的背景盖住看不见。
    /// 掩码用系统语义色 .secondary，深浅色模式自动适配。
    private struct MaskedField: View {
        @Binding var text: String
        var placeholder: String
        @FocusState private var focused: Bool

        var body: some View {
            ZStack {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(focused || text.isEmpty ? .primary : .clear)
                    .focused($focused)
                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

                if !focused && !text.isEmpty {
                    Text(String(repeating: "*", count: text.count))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        }
    }

    /// 输入框 + 快捷填入下拉。
    /// 下拉不接管这个字段，只是往输入框里填一个常用值 ——
    /// 做成"选预设"和"自定义"二选一是错的：用户想在预设基础上改一个字，
    /// 就得先切到自定义再重新输入一遍。
    @ViewBuilder
    private func presetRow(_ label: String, _ text: Binding<String>,
                           options: [PresetOption], placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth, alignment: .leading)

            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

            Menu {
                ForEach(options) { o in
                    Button(o.label) { text.wrappedValue = o.value }
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
    }

    private func intBinding(_ key: WritableKeyPath<ServerConfig, Int>) -> Binding<Int> {
        Binding(
            get: { app.selected?[keyPath: key] ?? 0 },
            set: { v in app.update { $0[keyPath: key] = v } }
        )
    }

    private func binding(_ key: WritableKeyPath<ServerConfig, String>) -> Binding<String> {
        Binding(
            get: { app.selected?[keyPath: key] ?? "" },
            set: { v in app.update { $0[keyPath: key] = v } }
        )
    }

    /// 命名输入框的绑定：实时截断到显示宽度上限（8 汉字 / 16 英文），
    /// 输入框里就超不过，也就不会产生"名字太长"的报错。
    private var renameBinding: Binding<String> {
        Binding(
            get: { renameText },
            set: { renameText = $0.truncated(toWidth: 16) }
        )
    }

    private func color(for line: String) -> Color {
        if line.contains("失败") || line.contains("错误") || line.contains("error") { return .red }
        if line.contains("[系统代理]") { return .orange }
        if line.contains("[系统]") { return .accentColor }
        return .primary
    }
}

/// 菜单/按钮标签：图标染指定色、文字用默认色，图标与文字间距统一。
/// 「分享」「备份」「自检」三个都套这个。
/// 图标固定宽度，把不同 SF Symbol 字形（盾牌/硬盘/方框箭头）的固有留白差异抹平，
/// 保证图标右边缘到文字的距离三个按钮严格一致。
private struct TintedIconLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(color)
                .frame(width: 16)
            configuration.title
        }
    }
}

/// NSMenu 的 action 目标。分享/备份用普通 Button 弹 NSMenu（不用 SwiftUI Menu），
/// 这样按钮标签渲染和「自检」完全一致，图标文字间距才能统一。
@MainActor
final class MenuActionTarget: NSObject {
    var onShareExport: (() -> Void)?
    var onShareImport: (() -> Void)?
    var onBackupLocal: (() -> Void)?
    var onRestoreLocal: (() -> Void)?
    var onWebDAVSettings: (() -> Void)?
    var onBackupWebDAV: (() -> Void)?
    var onRestoreWebDAV: (() -> Void)?
    var onDeleteWebDAV: (() -> Void)?

    @objc func shareExport() { onShareExport?() }
    @objc func shareImport() { onShareImport?() }
    @objc func backupLocal() { onBackupLocal?() }
    @objc func restoreLocal() { onRestoreLocal?() }
    @objc func webdavSettings() { onWebDAVSettings?() }
    @objc func backupWebDAV() { onBackupWebDAV?() }
    @objc func restoreWebDAV() { onRestoreWebDAV?() }
    @objc func deleteWebDAV() { onDeleteWebDAV?() }
}
