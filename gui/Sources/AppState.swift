import Foundation
import SwiftUI
import AppKit

/// 启动时被占用的监听端口，以及占着它的进程。弹窗确认要杀谁时用。
struct PortConflict: Identifiable {
    var id: Int { port }
    var label: String      // SOCKS5 / HTTP
    var port: Int
    var name: String       // 占用进程名
    var pid: Int
}

@MainActor
final class AppState: NSObject, ObservableObject {
    @Published var config: AppConfig
    @Published var isRunning = false {
        didSet { refreshStatusText() }
    }
    /// 启动中但自检尚未完成。此时内核已在运行，但还在等自检结果。
    /// 只有自检通过（或至少跑完）后才把 isRunning 设为 true。
    @Published var isStarting = false
    @Published var logLines: [String] = []
    /// 自检记录单独一份，切到"自检记录"视图时显示这个
    @Published var checkLines: [String] = []
    @Published var systemProxySummary: String = ""
    /// 刚新增/重建了还没起名的服务器，界面据此立刻弹起命名框
    @Published var needsNameInput = false
    @Published var proxyTakenOver = SystemProxy.isActive
    /// 系统代理是否已**成功接管**（enable 执行完且验证通过）。
    /// 与 proxyTakenOver（从标记接管那一刻起就为 true）不同，这个只在
    /// 真正设置成功后才变 true —— 菜单栏图标据此才变蓝，避免"说好了其实没成"。
    /// 初始不信任残留的 SystemProxy.isActive：崩溃/强杀后系统代理可能残留接管，
    /// 但那只是旧标记、本地端口早已没人监听，图标不该假蓝（真的接管成功才会蓝）。
    @Published var proxyReady = false
    /// WebDAV 上传/下载进行中（用来置灰按钮、防连点）
    @Published var webdavBusy = false

    // MARK: - 更新相关状态
    /// 发现了比本地更新的版本（有值即弹更新提示）
    @Published var updateInfo: Updater.ReleaseInfo?
    /// 检查/下载更新的进度文案（"正在检查…""正在下载 45%…""已是最新"）
    @Published var updateStatus: String = ""
    /// 需要弹窗提示的错误（nil = 不弹）。
    /// 菜单栏触发启动失败时窗口可能关着，日志看不到，必须弹窗
    @Published var alertMessage: String?
    @Published var alertTitle = "出错"
    /// 启动时发现监听端口被占用，待用户确认是否强制结束占用进程（nil = 无待处理）
    @Published var pendingPortConflict: PortConflict?
    /// DMG 下载进度 0~1；nil = 没有在下载
    @Published var downloadProgress: Double?
    /// 正在下载分流数据
    @Published var geoUpdating = false
    /// 分流数据状态文案（版本 + 更新时间）
    @Published var geoStatus: String = ""

    private var process: Process?
    private var stdoutPipe: Pipe?
    private let maxLogLines = 2000
    /// 每台服务器「最后一次点保存」时的完整副本，是落盘的唯一数据源。
    /// config.servers 存的是当前编辑值（界面在编辑时直接改它），
    /// persist 只写这里的值 —— 未保存的改动绝不会被带进配置文件。
    /// 是否"有未保存改动"也用它对比：当前编辑值 ≠ 已保存副本即 dirty。
    @Published private(set) var savedServers: [UUID: ServerConfig] = [:]
    /// 系统代理的接管/还原/查询都在这个 actor 里跑（后台串行），
    /// 否则同步跑几十个 networksetup 子进程会把主线程卡成风火轮。
    private let proxyWorker = SystemProxyWorker()

    /// 本次运行实际使用的本地端口（自动挑选，界面上不需要用户填）
    private(set) var activeSocks: (host: String, port: Int)?
    private(set) var activeHTTP: (host: String, port: Int)?

    /// 顶部状态条文字，例如「已连接 · 全局代理已开启」
    @Published var statusText: String = "已停止"

    override init() {
        let cfg = AppConfig.load()
        self.config = cfg
        super.init()
        // 磁盘读进来的服务器就是「已保存版本」，作为落盘副本的初始值
        savedServers = Dictionary(uniqueKeysWithValues: cfg.servers.map { ($0.id, $0) })
        // 读进来时可能做过格式迁移（比如把 host:port 拆成两个字段），
        // 立刻回写一次让文件里也是新格式，免得迁移逻辑一直悬着。
        // 全新安装（还没有配置文件）就不写：保持零配置，等用户第一次操作再落盘。
        if FileManager.default.fileExists(atPath: AppConfig.fileURL.path) {
            persist()
        }
        LogFile.startNewSession()
        recoverFromUncleanExit()
        refreshProxySummary()
    }

    /// 上次没能正常退出（被强杀、断电、崩溃）时的自愈：
    /// 1) 内核进程会变成孤儿继续跑，占着端口；
    /// 2) 系统代理停在"已接管"状态，指向一个已经没人监听的端口 —— 用户看起来就是断网。
    /// 两件事都要在启动时收拾干净，否则用户只会觉得"这软件把我网搞坏了"。
    private func recoverFromUncleanExit() {
        var recovered = false

        if KernelPID.killLeftover(expecting: kernelPath()) {
            pendingLogs.append("[系统] 清理了上次残留的内核进程")
            recovered = true
        }

        if SystemProxy.isActive {
            // 还原放后台跑：接管时跑了几十个 networksetup 子进程，启动时
            // 在主线程同步跑一遍，App 刚打开就在 Dock 里卡成风火轮。
            // proxyWorker 是 actor，串行排队，和之后的接管不会打架。
            pendingLogs.append("[系统代理] 上次未正常退出，正在还原系统代理…")
            Task {
                let warnings = await proxyWorker.restore()
                warnings.forEach { log("[系统代理] \($0)") }
                proxyTakenOver = false
                proxyReady = false
                log("[系统代理] 已把系统代理还原回你原来的设置")
            }
            recovered = true
        }

        if recovered { pendingLogs.append("[系统] 环境已恢复正常，可以直接启动") }
    }

    /// init 阶段还没人订阅日志，先攒着，界面出来后再吐出去
    private var pendingLogs: [String] = []

    func flushPendingLogs() {
        guard !pendingLogs.isEmpty else { return }
        pendingLogs.forEach { log($0) }
        pendingLogs.removeAll()
    }

    var selected: ServerConfig? {
        guard let id = config.selectedID else { return config.servers.first }
        return config.servers.first { $0.id == id } ?? config.servers.first
    }

    var selectedIndex: Int? {
        guard let s = selected else { return nil }
        return config.servers.firstIndex { $0.id == s.id }
    }

    /// 是否还存在没保存过的服务器。有的话不允许新增下一个。
    var hasUncommittedServer: Bool {
        config.servers.contains { savedServers[$0.id] == nil }
    }

    /// 该服务器是否已点过「保存」（通过校验、允许写盘）。
    /// 分享导出只导出这种"真实"的服务器，没保存的空壳不往外发。
    func isServerSaved(_ id: UUID) -> Bool {
        savedServers[id] != nil
    }

    /// 当前选中的服务器是否有未保存改动（含从未保存过的情况）。
    /// 保存按钮据此高亮提醒。直接对比「当前编辑值」与「已保存副本」，
    /// 改回去也算没改动 —— 删掉一个字符再输回来，值一样就不算 dirty。
    var isServerDirty: Bool {
        guard let s = selected else { return false }
        return savedServers[s.id] != s
    }

    /// 编辑服务器字段的唯一入口：字段绑定、分流模式、分流规则全走这里。
    /// 不用手动打标：dirty 由「当前值 != 已保存副本」实时推导。
    /// TextField 点击聚焦会回调一次 set 写入当前值，值没变自然不算改动。
    func update(_ mutate: (inout ServerConfig) -> Void) {
        guard let idx = selectedIndex else { return }
        mutate(&config.servers[idx])
    }

    /// 落盘：只写「已保存」的服务器副本。
    /// 未点过「保存」的服务器不持久化 —— 退出、切设置开关等任何保存路径
    /// 都不会把内存里没校验过的服务器带进配置文件。
    /// 写的是 savedServers 里的已保存副本，不是 config.servers 的当前编辑值 ——
    /// 界面改了一半没保存的参数，绝不会被这里带进磁盘。
    func persist() {
        var out = config
        out.servers = config.servers
            .compactMap { savedServers[$0.id] }
        out.save()
    }

    private static let nameTooLongMessage = "名字太长：最多 8 个汉字或 16 个英文/数字/符号"

    /// 保存当前服务器配置到文件。不完整时返回错误原因并拒绝保存，成功返回 nil。
    @discardableResult
    func saveCurrentServer() -> String? {
        guard let idx = selectedIndex else { return "没有选中的服务器" }
        let n = config.servers[idx].name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "请先给服务器起个名字" }
        if n.displayWidth > 16 { return Self.nameTooLongMessage }
        if config.servers.contains(where: { $0.id != config.servers[idx].id
            && $0.name.trimmingCharacters(in: .whitespaces) == n }) {
            return "已存在该名称服务器，请重试。"
        }
        if let err = config.servers[idx].validate() {
            log("[系统] 保存失败：\(err)")
            return err
        }
        savedServers[config.servers[idx].id] = config.servers[idx]
        persist()
        log("[系统] 服务器配置已保存")
        return nil
    }

    func addServer() {
        var s = ServerConfig()
        // 不自动起名「服务器 N」：名字由弹窗里用户亲手输入，
        // 免得每次新增都白得一个还得手动改掉的默认名。
        s.name = ""
        config.servers.append(s)
        config.selectedID = s.id
        needsNameInput = true
        // 不立即持久化：新服务器一个字段都没填，跟着「必填」逻辑走 ——
        // 填完整点「保存」才算数。免得导入配置时混进一堆空服务器。
    }

    /// 复制当前服务器：换个优选 IP 试的时候很方便
    func duplicateSelected() {
        guard let cur = selected else { return }
        var copy = cur
        copy.id = UUID()
        let base = cur.name + " 副本"
        var n = base
        var i = 2
        while config.servers.contains(where: { $0.name.trimmingCharacters(in: .whitespaces) == n }) {
            n = base + " \(i)"
            i += 1
        }
        copy.name = n
        config.servers.append(copy)
        config.selectedID = copy.id
        savedServers[copy.id] = copy
        persist()
    }

    /// 起名/改名。名字为空或与其它服务器重名时拒绝，返回错误原因，成功返回 nil。
    @discardableResult
    func rename(to newName: String) -> String? {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return "服务器名称不能为空" }
        if n.displayWidth > 16 { return Self.nameTooLongMessage }
        guard let idx = selectedIndex else { return "没有选中的服务器" }
        let id = config.servers[idx].id
        if config.servers.contains(where: { $0.id != id && $0.name.trimmingCharacters(in: .whitespaces) == n }) {
            return "已存在该服务器名称，请重试。"
        }
        config.servers[idx].name = n
        // 重命名要同步进"已保存副本"：persist 只写 savedServers，
        // 不更新的话退出后名字变回旧值，还会误报"有未保存改动"。
        if savedServers[id] != nil {
            savedServers[id]?.name = n
            persist()
        }
        return nil
    }

    func delete(id: UUID) {
        guard let idx = config.servers.firstIndex(where: { $0.id == id }) else { return }
        config.servers.remove(at: idx)
        savedServers.removeValue(forKey: id)

        // 删到一个不剩就补一个空白的。之前是"最后一个不许删"，
        // 可用户想清空重填时只能一个个改字段，很别扭 ——
        // 让他删，然后给个干净的新配置继续填。
        if config.servers.isEmpty {
            var fresh = ServerConfig()
            fresh.name = ""
            config.servers = [fresh]
            needsNameInput = true
        }
        if config.selectedID == id || !config.servers.contains(where: { $0.id == config.selectedID }) {
            config.selectedID = config.servers.first?.id
        }
        persist()
    }

    func deleteSelected() {
        guard let s = selected else { return }
        delete(id: s.id)
    }

    /// 切换选中的服务器。运行中切换会重启代理用新服务器生效（会短暂断开）——
    /// 否则光改选中项、连的还是旧服务器，用户会以为切换坏了。
    /// 不落盘：选中状态等下一次真正保存时一并持久化（避免把还没通过「必填」
    /// 校验的服务器写进配置，Picker 的 set 在界面刷新时会回调到这里）。
    func select(_ id: UUID) async {
        let prev = config.selectedID
        config.selectedID = id
        guard isRunning, prev != id else { return }
        log("[系统] 已切换服务器，正在重启代理（会短暂断开）…")
        await stop()
        start()
    }

    // MARK: - 自定义分流规则

    /// 规则改过但还没重启内核。规则是启动参数，改完不重启等于没改，
    /// 必须让用户看见这个状态，否则他会以为改完就生效了。
    @Published var rulesDirty = false

    func addRule() {
        update { $0.customRules.append(CustomRule()) }
        if isRunning { rulesDirty = true }
    }

    func removeRule(_ id: UUID) {
        update { $0.customRules.removeAll { $0.id == id } }
        if isRunning { rulesDirty = true }
    }

    /// 重启内核让规则生效。
    ///
    /// 注意：这是手动的，和 switchRouteMode 的自动重启刻意不同——
    /// 规则是多字段编辑（类型/域名/动作下拉连点），每个改动都自动重启
    /// 会频繁断网、还可能在用户还没填完时就重启。所以编辑只标记
    /// rulesDirty，让用户改完统一点「立即重启」。模式是单选控件，
    /// 点一次就完成，才适合自动重启。别把它们"统一"了。
    func applyRules() async {
        guard isRunning else { rulesDirty = false; return }
        log("[系统] 应用新的分流规则，正在重启代理（会短暂断开）…")
        await stop()
        start()
        rulesDirty = false
    }

    func updateRule(_ id: UUID, kind: RuleKind? = nil, target: String? = nil, action: String? = nil) {
        update { cfg in
            guard let i = cfg.customRules.firstIndex(where: { $0.id == id }) else { return }
            if let kind {
                cfg.customRules[i].kind = kind
                // 换了类型，原来填的内容多半对不上了，清掉免得留个无效规则。
                // 切到分类就直接给个默认选项，省得用户面对一个空下拉。
                cfg.customRules[i].target = (kind == .category) ? RuleCategory.all[0].value : ""
            }
            if let target { cfg.customRules[i].target = target }
            if let action { cfg.customRules[i].action = action }
        }
        if isRunning { rulesDirty = true }
    }

    // MARK: - 程序坞图标

    /// 切换程序坞图标显示。默认隐藏，通过菜单栏开关控制。
    /// 状态持久化到配置文件，重启后保持不变。
    func setShowDockIcon(_ show: Bool) {
        config.showDockIcon = show
        persist()
        applyDockIconPolicy()
        log("[系统] 程序坞图标已\(show ? "显示" : "隐藏")")
    }

    func applyDockIconPolicy() {
        if config.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: config.showDockIcon)
    }

    // MARK: - 开机自启动

    var launchAtLogin: Bool { LoginItem.isEnabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            let state = LoginItem.isEnabled ? "已开启" : "已关闭"
            log("[系统] 开机自启动已设为\(on ? "开启" : "关闭")（实际状态：\(state)）")
        } catch {
            log("[系统] 设置开机自启动失败：\(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    // MARK: - 日志

    /// 写日志的同时弹窗提示。启动失败这类错误窗口可能关着，
    /// 只看日志用户根本发现不了，必须弹窗。
    func notify(_ text: String, title: String = "出错") {
        log("[系统] \(text)")
        alertTitle = title
        alertMessage = text
    }

    /// 从最近的内核日志里识别「服务器侧」的失败原因，返回给用户看的简短说明。
    /// 识别不出来返回 nil（本地原因走通用提示）。只读日志，不改任何状态。
    ///
    /// 弹窗文案要短：SwiftUI 的 alert 长了会换行、排版不居中，
    /// 所以这里每一条都压在一行以内。
    private func serverFailureHint() -> String? {
        let hints = Array(logLines.suffix(30)).joined(separator: "\n")
        let lower = hints.lowercased()
        if lower.contains("认证失败")
            || lower.contains("token 不匹配")
            || lower.contains("unauthorized")
            || lower.contains("401") {
            return "TOKEN 与服务器端不一致"
        }
        if lower.contains("no such host")
            || lower.contains("lookup")
            || lower.contains("找不到主机") {
            // 内核日志用 (IP:xxx) 标注实际拨号目标：填了优选IP/域名就是它，
            // 没填则显示"自动解析"（此时解析的是服务地址）。据此精确指认字段。
            if let r = hints.range(of: #"\(IP:[^)]*\)"#, options: .regularExpression) {
                let label = String(hints[r])
                return label.contains("自动解析")
                    ? "服务地址解析失败，请检查「服务地址」"
                    : "优选IP/域名解析失败，请检查「优选IP/域名」"
            }
            return "服务器连接失败"
        }
        if lower.contains("connection refused")
            || lower.contains("i/o timeout")
            || lower.contains("deadline exceeded")
            || lower.contains("timed out")
            || lower.contains("bad handshake")
            || lower.contains("handshake failure")
            || lower.contains("handshake 失败")
            || lower.contains("reset by peer") {
            return "服务器连接失败"
        }
        return nil
    }

    func log(_ text: String) {
        // 级别选「关闭」就是真的什么都不记：界面不显示，文件也不写。
        // 代价是出问题时没有记录可查，但这是用户明确要的行为 ——
        // 留一份"看不见但一直在写"的日志更违反直觉。
        guard config.logLevel != .off else { return }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // 自检结论完全走单独通道，不进运行日志。
            // 它是一次次的结论，混进连续流水只会把两边都搅浑。
            if line.contains("[自检]") {
                checkLines.append(line)
                LogFile.writeCheck(line)
                if checkLines.count > 300 {
                    checkLines.removeFirst(checkLines.count - 300)
                }
                continue
            }

            // 文件留全量，界面按级别过滤：文件是用来事后排查的，
            // 界面是用来当下扫一眼的，两者详略要求不同。
            LogFile.write(line)
            guard LogLevel.classify(line).rank <= config.logLevel.rank else { continue }
            logLines.append(line)
        }
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    /// 清空日志：界面和文件一起清。
    /// 只清界面而留着文件，用户会以为已经清干净了，下次打开日志文件又是一堆旧记录。
    func clearLog() {
        logLines.removeAll()
        checkLines.removeAll()
        LogFile.clear()
    }

    /// 当前视图该显示哪一份记录
    var displayedLines: [String] {
        config.logLevel == .checkOnly ? checkLines : logLines
    }

    // MARK: - 内核进程

    /// 内核 x-tunnel 的位置：优先 App 包内，其次可执行文件同级目录（方便开发时直接跑）
    private func kernelPath() -> String? {
        if let p = Bundle.main.path(forResource: "x-tunnel", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("x-tunnel").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return nil
    }

    func start() {
        guard !isRunning && !isStarting else { return }
        guard let cfg = selected else { notify("请先新增一个服务器"); return }
        if let err = cfg.validate() { notify(err); return }
        // 有未保存改动就拦住：启动必须用真实已保存的配置，不能带着
        // 内存里改了一半的参数跑起来。保存按钮会高亮提示当前有改动。
        if savedServers[cfg.id] != cfg {
            let reason = savedServers[cfg.id] != nil
                ? "服务器配置已修改但未保存，请先点「保存」再启动。"
                : "这台服务器还没有保存过，请先点「保存」再启动。"
            notify(reason, title: "启动失败")
            return
        }
        guard let kernel = kernelPath() else {
            notify("找不到内核程序 x-tunnel，请确认 App 完整"); return
        }

        // 监听地址由主机名 + 端口拼出来，两个字段在界面上是分开填的
        let listen = cfg.expandedListen

        // 端口预检查只是"提前给个说法"，不该当门禁用。
        // 之前它拦下过明明能启动的情况：bind 说被占用，lsof 却查不到任何监听者，
        // 两个结论对不上，用户就被卡在一句无从下手的报错上。
        // 现在只有 lsof 真的指出占用进程时才拦，其余情况放行 ——
        // 内核自己起不来会给出准确原因，比这里瞎猜强。
        // 同时检查 SOCKS 和 HTTP 两个端口，避免 HTTP 端口被占导致内核无声失败
        let portsToCheck = [
            (ServerConfig.socksEndpoint(in: listen), "SOCKS5"),
            (ServerConfig.httpEndpoint(in: listen), "HTTP")
        ]
        for (ep, label) in portsToCheck {
            guard let s = ep else { continue }
            var free = PortPicker.isFree(s.port)
            for _ in 0..<10 where !free {
                usleep(100_000)
                free = PortPicker.isFree(s.port)
            }
            if !free {
                if let occ = PortPicker.occupant(of: s.port) {
                    log("[系统] \(label) 端口 \(s.port) 被 \(occ.label) 占用，等待用户确认…")
                    pendingPortConflict = PortConflict(label: label,
                                                       port: s.port, name: occ.name, pid: occ.pid)
                    return
                }
                log("[系统] \(label) 端口 \(s.port) 预检查未通过（\(PortPicker.lastBindReason)），但没有进程在监听，继续启动")
            }
        }
        activeSocks = ServerConfig.socksEndpoint(in: listen)
        activeHTTP = ServerConfig.httpEndpoint(in: listen)

        // 分流数据：优先用更新下载到数据目录的新版，没有再退回 App 内置
        var geoip: String?, geosite: String?
        if config.routeMode.needsGeoData {
            geoip = Updater.geoDataPath(for: "geoip.dat")
                ?? Bundle.main.path(forResource: "geoip", ofType: "dat")
            geosite = Updater.geoDataPath(for: "geosite.dat")
                ?? Bundle.main.path(forResource: "geosite", ofType: "dat")
            if geoip == nil || geosite == nil {
                // 这不是"降级运行"就能糊弄过去的事：少了数据，"跳过中国大陆"
                // 会退化成把国内流量也塞进隧道，用户只会觉得又慢又不通。
                notify("App 内缺少分流数据文件（geoip.dat / geosite.dat），请改用「全局代理」模式或重新安装完整版本")
                return
            }
        }

        log("[系统] 正在启动内核进程…")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: kernel)
        p.arguments = cfg.arguments(listen: listen, geoip: geoip, geosite: geosite, mode: config.routeMode)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        stdoutPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let me = self
            Task { @MainActor in me?.log(text) }
        }

        p.terminationHandler = { [weak self] proc in
            let me = self
            Task { @MainActor in
                guard let me else { return }
                me.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                me.stdoutPipe = nil
                me.process = nil
                me.isRunning = false
                me.isStarting = false
                me.checkState = .idle
                KernelPID.clear()
                me.log("[系统] 内核已退出（状态码 \(proc.terminationStatus)）")
                if me.proxyTakenOver { me.disableSystemProxy() }
                me.refreshStatusText()

                // 非零退出码 = 启动失败或运行中崩溃。stop() 会先把 terminationHandler
                // 置 nil，所以走到这里一定是异常退出。绝大多数是端口被占用，
                // 从内核日志里找"address already in use / bind"这类关键字，
                // 给出明确的修复提示，而不是只显示一个生硬的"状态码"。
                if proc.terminationStatus != 0 {
                    let hints = Array(me.logLines.suffix(20)).joined(separator: "\n")
                    let lower = hints.lowercased()
                    if lower.contains("address already in use")
                        || lower.contains("cannot bind")
                        || lower.contains("bind:") {
                        // 内核 bind 失败：查得到占用者就走弹窗确认（和预检查一致），
                        // 查不到（如刚释放的 TIME_WAIT）就纯提示。
                        let conflict = [me.activeSocks, me.activeHTTP]
                            .compactMap { $0 }
                            .lazy
                            .compactMap { ep -> (String, Int, PortPicker.Occupant)? in
                                guard let o = PortPicker.occupant(of: ep.port) else { return nil }
                                let label = (ep.port == me.activeSocks?.port) ? "SOCKS5" : "HTTP"
                                return (label, ep.port, o)
                            }.first
                        if let (label, port, o) = conflict {
                            me.log("[系统] \(label) 端口 \(port) 被 \(o.label) 占用，等待用户确认…")
                            me.pendingPortConflict = PortConflict(label: label, port: port, name: o.name, pid: o.pid)
                        } else {
                            me.notify("端口暂时无法绑定，请稍后重试或换个监听端口。", title: "启动失败")
                        }
                    } else if let hint = me.serverFailureHint() {
                        me.notify(hint, title: "启动失败")
                    } else {
                        me.notify("请查看运行日志", title: "启动失败")
                    }
                }
            }
        }

        do {
            try p.run()
        } catch {
            isStarting = false
            checkState = .idle
            notify("启动内核失败：\(error.localizedDescription)")
            return
        }
        process = p
        KernelPID.record(p.processIdentifier)
        log("[系统] 内核进程已启动（PID \(p.processIdentifier)）")
        if let s = activeSocks { log("[系统] 本地端口 SOCKS5 \(s.host):\(s.port)") }

        // 系统代理先不接管 —— 自检通过后才算真正的"运行中"
        // 但先存好 activeSocks/activeHTTP 供自检使用

        rulesDirty = false
        refreshStatusText()

        // 启动流程：先等内核监听端口就绪（约 5 秒上限）→ 立刻接管系统代理。
        // 内核是"隧道建好才监听端口"，所以端口就绪 ≈ 隧道已通，
        // 不必再等完整的 HTTP 探针 —— 探针放后台跑，只更新自检状态，不阻塞接管。
        isStarting = true
        checkState = .running
        log("[系统] 正在等待代理端口就绪…")
        Task { @MainActor in
            guard let socks = self.activeSocks else {
                // activeSocks 取不到（服务器被删、端口配置丢了等极端情况），
                // 绝不该假装"运行中"——否则界面亮绿灯而内核早就没了。
                // 这里只负责收尾状态，等 terminationHandler 统一处置内核。
                self.checkState = .idle
                self.isStarting = false
                return
            }
            let mode = self.config.routeMode

            // 1) 等本地端口开始监听（内核起来、隧道就绪才监听）。
            //    上限 10 秒，和内核 WaitForChannelReady(10s) 对齐：慢隧道也能等到。
            var portReady = false
            for attempt in 1...10 {
                guard self.isStarting, self.process?.isRunning == true else {
                    self.isStarting = false
                    return
                }
                if !PortPicker.isFree(socks.port) {
                    portReady = true
                    break
                }
                if attempt < 10 {
                    self.log("[系统] 代理端口尚未就绪，1 秒后重试（第 \(attempt) 次）…")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            self.isStarting = false

            if !portReady {
                // 端口一直没就绪：内核可能启动失败。
                // 关键：把没能就绪的内核进程清掉。之前这里只标记失败就返回，
                // 内核进程还活着、占着监听端口 —— 下次启动就报"端口被占用"；
                // 而且 App 认为没在运行、点按钮只会触发 start() 而不是 stop()，
                // 等于这个代理关不掉了。
                self.log("[系统] 代理端口未就绪，内核可能启动失败，正在清理残留内核进程…")
                await self.stop()
                self.checkState = .failed("本地代理端口 \(socks.port) 未监听，内核可能未启动成功")
                // 服务器侧的原因（TOKEN 错、地址不通）用户从日志里看不出来，
                // 启动失败要弹一次窗点明原因，别让人一头雾水反复点启动。
                // serverFailureHint 从内核日志里认字，识别不了就走通用文案。
                if let hint = self.serverFailureHint() {
                    self.notify(hint, title: "启动失败")
                } else {
                    self.notify("请查看运行日志", title: "启动失败")
                }
                return
            }

            // 2) 端口就绪 → 标记运行中。系统代理先不接管：
            //    自检通过前不对外暴露代理状态（菜单栏不变蓝），
            //    避免"隧道其实不通却已把浏览器流量导入"的假成功。
            self.isRunning = true
            self.log("[系统] 代理端口已就绪，正在自检…")

            // 3) 后台跑连通性探针，只更新自检状态
            Task { @MainActor in
                let results = await SelfCheck.run(socks: socks, mode: mode)
                let failed = results.filter { !$0.ok }
                for r in results {
                    self.log("[自检] \(r.ok ? "✓" : "✗") \(r.title)：\(r.note)")
                }
                if failed.isEmpty {
                    let detail = results.map { "\($0.title)：\($0.note)" }.joined(separator: "\n")
                    self.checkState = .ok(detail)
                    // 自检通过才算真正接管：接管成功 → proxyReady=true → 菜单栏变蓝
                    self.log("[系统] 自检通过，正在接管系统代理…")
                    if self.config.autoSystemProxy {
                        self.enableSystemProxy()
                    }
                } else {
                    let detail = failed.map { "\($0.title)：\($0.note)" }.joined(separator: "\n")
                    self.checkState = .failed(detail)
                    self.log("[系统] 隧道自检未完全通过，请查看上方运行日志")
                    // 探针发现隧道其实不通：让浏览器继续走这个"死隧道"，
                    // 用户只会看到所有网页打不开。此时代理是坏的状态，
                    // 必须彻底关闭（停内核 + 还原系统代理 + 清状态），
                    // 不能只撤系统代理留着内核跑 —— 否则下次启动会撞端口占用，
                    // 界面状态（灯/按钮）也和真实情况对不上。
                    // 只信"必须经隧道"的探针（国外站点）：国内直连/本地端口的失败
                    // 可能只是网络本身的问题，隧道未必坏了，不能因为它就关闭。
                    if self.proxyTakenOver, failed.contains(where: { $0.dependsOnTunnel }) {
                        self.log("[系统] 隧道自检失败，为避免浏览器全挂，正在关闭代理…")
                        await self.stop()
                    }
                }
            }
        }
    }

    /// 用户确认强制结束占用进程后：杀掉 → 等端口释放 → 重新走一遍启动。
    /// 这属于用户明确的"帮我解决它"操作，杀错了责任在确认弹窗上，这里只管做。
    func resolvePortConflictByKilling() {
        guard let c = pendingPortConflict else { return }
        pendingPortConflict = nil
        log("[系统] 正在结束占用端口的进程 \(c.name)(PID \(c.pid))…")
        guard PortPicker.kill(pid: c.pid) else {
            notify("无法结束进程 \(c.name)(PID \(c.pid))，请手动关闭后再启动", title: "启动失败")
            return
        }
        // 给端口一点时间真正释放，再重新启动
        for _ in 0..<10 {
            if PortPicker.isFree(c.port) { break }
            usleep(100_000)
        }
        log("[系统] \(c.label) 端口 \(c.port) 已释放，重新启动代理")
        start()
    }

    /// 用户取消：不杀进程，也不启动，保持停止状态
    func cancelPortConflict() {
        guard pendingPortConflict != nil else { return }
        pendingPortConflict = nil
        log("[系统] 已取消启动")
    }

    func stop() async {
        isStarting = false
        if proxyTakenOver { disableSystemProxy() }
        guard let p = process else { isRunning = false; return }
        p.terminationHandler = nil
        p.terminate()
        // 等它真的退出再往下走。SIGTERM 只是"请你退出"，进程还要一点时间收尾；
        // 之前发完信号就立刻返回，用户切换模式时紧接着点启动，
        // 就会撞上尚未释放的端口，报"端口 30000 已被占用"。
        // 睡眠用 Task.sleep，不占主线程 —— 不然用户点「停止」就卡出风火轮。
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        process = nil
        isRunning = false
        KernelPID.clear()

        // 等端口真正释放再返回。进程退出和内核放开监听端口之间还有延迟，
        // 光等进程结束不够 —— 紧接着的 start() 会撞上尚未释放的端口，
        // 报一句"端口被占用"，用户只会觉得莫名其妙（切分流模式时最容易撞上）。
        // SOCKS 和 HTTP 两个都要等：只等前者的话，内核仍会因为后者起不来。
        for ep in [activeSocks, activeHTTP].compactMap({ $0 }) {
            for _ in 0..<40 where !PortPicker.isFree(ep.port) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        activeSocks = nil
        activeHTTP = nil
        checkState = .idle
        log("[系统] 已停止")
        refreshStatusText()
    }

    func toggle() async { (isRunning || isStarting) ? await stop() : start() }

    /// 切换分流模式。分流模式是全局参数（AppConfig.routeMode），切换立即
    /// 落盘，与 autoSystemProxy / logLevel 这些全局开关一致 —— 不像服务器
    /// 参数那样要等点「保存」。分流规则是启动时作为命令行参数传给内核的，
    /// 运行中切换自动重启内核让其生效（会短暂断开）。
    func switchRouteMode(_ mode: RouteMode) async {
        guard config.routeMode != mode else { return }
        config.routeMode = mode
        persist()

        guard isRunning else { return }
        log("[系统] 分流模式已切换为「\(mode.title)」，正在重启代理（会短暂断开）…")
        await stop()
        start()
    }

    // MARK: - 自检

    /// 自检结果。做成一盏灯而不是往日志里刷 ——
    /// 日志是连续的流水，自检是一次性的结论，混在一起两边都看不清；
    /// 而且用户一旦关掉日志，自检结果也跟着消失了，那自检就白做了。
    enum CheckState: Equatable {
        case idle          // 还没测
        case running       // 正在测
        case ok(String)    // 通过，附一句摘要
        case failed(String) // 失败，附失败原因
    }

    @Published var checkState: CheckState = .idle
    @Published var checking = false

    /// 跑一轮连通性自检。
    /// - silent: 静默模式（启动后自动跑的那次）只更新状态灯，不往日志里写；
    ///   手动点按钮才写日志，那时用户是主动来看细节的。
    /// 代理未运行时也能点：改成预检服务端 / DoH 可达性，人工确认这套配置
    /// 在启动前"能不能用"——不必先启动一趟才知道连不上。
    func runSelfCheck(silent: Bool = false) {
        guard !checking else { return }
        checking = true
        checkState = .running
        if !silent { log("[自检] 开始检测…") }

        // 代理没在跑：没有本地端口可测，走预检分支。
        guard (isRunning || isStarting), let socks = activeSocks else {
            guard let cfg = selected else {
                checking = false
                if !silent { log("[自检] 请先添加并选中服务器") }
                return
            }
            if let err = cfg.validate() {
                checking = false
                checkState = .failed(err)
                if !silent { log("[自检] ✗ 配置不完整：\(err)") }
                return
            }
            if !silent { log("[自检] 代理未启动，预检服务端连通性…") }
            Task { @MainActor in
                // 至少让"检测中"显示 800 毫秒，灯一闪而过等于没有反馈
                async let probe = SelfCheck.runPreflight(config: cfg)
                async let minShow: Void = Task.sleep(nanoseconds: 800_000_000)
                let results = await probe
                _ = try? await minShow
                presentCheckResults(results, silent: silent)
                checking = false
            }
            return
        }

        Task { @MainActor in
            let mode = config.routeMode
            async let probe = SelfCheck.run(socks: socks, mode: mode)
            // 至少让"检测中"显示 800 毫秒。检测本身可能几百毫秒就完了，
            // 灯一闪而过等于没有反馈，用户只会觉得"它根本没检测"。
            async let minShow: Void = Task.sleep(nanoseconds: 800_000_000)
            let results = await probe
            _ = try? await minShow
            presentCheckResults(results, silent: silent)
            checking = false
        }
    }

    /// 自检结果的统一呈现：写日志（非静默）+ 更新状态灯（ok/failed 摘要）。
    /// 非静默时结果只打一遍；静默模式不打扰，失败项也单独记一笔。
    @MainActor
    private func presentCheckResults(_ results: [SelfCheck.Result], silent: Bool) {
        if !silent {
            for r in results {
                log("[自检] \(r.ok ? "✓" : "✗") \(r.title)：\(r.note)")
            }
        }

        let failed = results.filter { !$0.ok }
        if failed.isEmpty {
            // 摘要里带上延迟，一眼能看出快慢
            let detail = results.map { "\($0.title)：\($0.note)" }.joined(separator: "\n")
            checkState = .ok(detail)
            // 手动自检：结果统一弹窗，不依赖用户切去查日志。
            if !silent {
                notify(detail, title: "自检通过")
            }
            // 静默模式（启动后自动跑的那次）：通过的结果也进自检记录，
            // 只记失败的话，看不出平时延迟是多少，也就没法判断"今天怎么变慢了"。
            if silent {
                for r in results {
                    log("[自检] ✓ \(r.title)：\(r.note)")
                }
            }
        } else {
            let detail = failed.map { "\($0.title)：\($0.note)" }.joined(separator: "\n")
            checkState = .failed(detail)
            // 手动自检失败：统一弹窗点明哪几项没过。
            if !silent {
                notify(detail, title: "自检未通过")
            }
            // 静默模式下失败无论如何都记一笔，而且要带上原因 ——
            // 只写"某项未通过"等于没说，用户照样不知道该查什么。
            if silent {
                for f in failed {
                    log("[自检] ✗ \(f.title)：\(f.note)")
                }
            }
        }
    }

    // MARK: - 系统代理

    func enableSystemProxy() {
        // 先标记再异步接管：万一接管还没跑完用户就点停止，stop() 里依然能
        // 看到 proxyTakenOver=true 而去还原系统代理，不会把代理漏在系统里。
        proxyTakenOver = true
        proxyReady = false   // 接管中 → 图标不该蓝
        let socks = activeSocks.map { SystemProxyWorker.Endpoint(host: $0.host, port: $0.port) }
        let http = activeHTTP.map { SystemProxyWorker.Endpoint(host: $0.host, port: $0.port) }
        Task {
            do {
                let warnings = try await proxyWorker.enable(socks: socks, http: http)
                warnings.forEach { log("[系统代理] \($0)") }
                proxyReady = true   // 设置成功、验证通过，才亮蓝
                log("[系统代理] 浏览器等程序已自动走本工具")
            } catch {
                proxyTakenOver = false
                proxyReady = false
                log("[系统代理] 自动设置失败：\(error.localizedDescription)")
            }
            refreshProxySummary()
        }
    }

    /// 切换「自动设置系统代理」。
    ///
    /// 这个开关原来只在点启动的瞬间被读一次，运行中改它没有任何反应 ——
    /// 用户会以为软件坏了。现在做成即时生效：正在运行就立刻接管/还原，
    /// 没运行则只记下偏好，等下次启动时用。
    func setAutoSystemProxy(_ on: Bool) {
        config.autoSystemProxy = on
        persist()

        guard isRunning else {
            log("[系统代理] 已\(on ? "开启" : "关闭")自动设置，下次启动代理时生效")
            return
        }
        if on {
            enableSystemProxy()
        } else {
            disableSystemProxy()
        }
    }

    func disableSystemProxy() {
        proxyTakenOver = false
        proxyReady = false
        Task {
            let warnings = await proxyWorker.restore()
            warnings.forEach { log("[系统代理] \($0)") }
            log("[系统代理] 已还原为你原来的设置")
            refreshProxySummary()
        }
    }

    func refreshProxySummary() {
        Task {
            systemProxySummary = await proxyWorker.summary()
            refreshStatusText()
        }
    }

    func refreshStatusText() {
        guard isRunning else {
            statusText = isStarting ? "启动中…" : "已停止"
            return
        }
        var t = "运行中"
        if let s = activeSocks { t += " · 本地端口 \(s.port)" }
        // 这里说的是"系统代理有没有被接管"，跟分流模式里的"全局代理"是两回事，
        // 早先都叫"全局代理"，用户会以为分流模式被改了。
        t += proxyTakenOver ? " · 已接管系统代理" : " · 未接管系统代理"
        statusText = t
    }

    // MARK: - 服务器分享

    /// 把选中的服务器导出成分享文件。只导出点过「保存」的服务器，
    /// 没保存的空壳服务器（参数不全）不往外发。
    func exportSelectedServers(_ ids: Set<UUID>, to url: URL) {
        let servers = config.servers.filter { ids.contains($0.id) && savedServers[$0.id] != nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(ServerShareFile(servers: servers))
            try data.write(to: url, options: .atomic)
            log("[系统] 已导出 \(servers.count) 个服务器到 \(url.lastPathComponent)")
            showInfoDialog(title: "导出成功", text: "已导出 \(servers.count) 台服务器")
        } catch {
            log("[系统] 导出失败：\(error.localizedDescription)")
            showInfoDialog(title: "导出失败", text: "未能写入分享文件")
        }
    }

    /// 从分享文件导入服务器，追加到现有列表。
    /// 重新生成 id，避免和已有服务器撞车。
    /// 规则：
    ///  1) 地址/端口等参数不完整（token 可选）的视为无效服务器，直接过滤；
    ///  2) 名称不能重复：名称撞车时看服务地址+端口 —— 完全相同是真重复，跳过；
    ///     参数不同则自动改名「名称-01」再导入（不同目标但同名，不该被当成同一台）；
    ///  3) 导入成功后，当前所有未保存的"空服务器/草稿"一律删除 ——
    ///     它们不算真实数据，留着只会产生垃圾配置。
    func importServers(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(ServerShareFile.self, from: data)
            guard file.format == "echos-servers" else { throw ShareError.notShareFile }
            var added = 0
            var skipped = 0
            var renamed = 0
            // 已保存服务器的名称集合，名称不允许重复
            var names = Set(config.servers.filter { savedServers[$0.id] != nil }
                .map { $0.name.trimmingCharacters(in: .whitespaces) })
            for var s in file.servers {
                // 1) 参数不完整（不含 token，token 可选）→ 无效，过滤
                if let err = s.validate() {
                    skipped += 1
                    log("[系统] 跳过无效服务器：\(err)")
                    continue
                }
                let baseName = s.name.trimmingCharacters(in: .whitespaces)
                if names.contains(baseName) {
                    // 2) 名称撞车：看服务地址+端口是不是完全一样
                    let sameTarget = config.servers.contains { existing in
                        savedServers[existing.id] != nil
                            && existing.name.trimmingCharacters(in: .whitespaces) == baseName
                            && existing.server.trimmingCharacters(in: .whitespaces) == s.server.trimmingCharacters(in: .whitespaces)
                            && existing.serverPort == s.serverPort
                    }
                    if sameTarget {
                        skipped += 1
                        log("[系统] 跳过重复服务器：\(baseName)（同一服务地址和端口）")
                        continue
                    }
                    // 参数不同：自动改名「-01」「-02」…，保证名称唯一
                    s.name = availableName(baseName, in: names)
                    renamed += 1
                    log("[系统] 「\(baseName)」已存在且参数不同，自动改名为「\(s.name)」")
                }
                s.id = UUID()
                config.servers.append(s)
                savedServers[s.id] = s   // 导入即视为已保存，可立即使用
                names.insert(s.name.trimmingCharacters(in: .whitespaces))
                added += 1
            }
            // 3) 删除所有未保存的服务器（空壳/未完成草稿）
            let before = config.servers.count
            config.servers.removeAll { savedServers[$0.id] == nil }
            let removedDrafts = before - config.servers.count
            if removedDrafts > 0 {
                log("[系统] 已删除 \(removedDrafts) 台未保存的空服务器")
            }
            // 选中项可能指向被删的草稿，修回第一个有效服务器
            if config.selectedID == nil || !config.servers.contains(where: { $0.id == config.selectedID }) {
                config.selectedID = config.servers.first?.id
            }
            // 用 persist() 而不是 save()：只落盘已保存的服务器，
            // 否则内存里那个还没点「保存」的草稿会被一并写进文件，
            // 重启后变成"已保存"的无效服务器（被"卡 bug 保存"）。
            persist()
            var tail = ""
            if renamed > 0 { tail += "，改名 \(renamed) 台" }
            if skipped > 0 { tail += "，跳过 \(skipped) 台无效/重复" }
            log("[系统] 已导入 \(added) 个服务器\(tail)")
            showInfoDialog(title: "导入成功", text: "已导入 \(added) 台服务器")
        } catch {
            log("[系统] 导入失败：请选择服务器分享文件（.json）")
            showInfoDialog(title: "导入失败", text: "不是有效的服务器分享文件")
        }
    }

    /// 给撞名的服务器找一个不冲突的名字：名称-01、-02…，并控制总长度不超上限。
    private func availableName(_ base: String, in names: Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        for i in 1...99 {
            let suffix = String(format: "-%02d", i)
            let candidate = trimmed.truncated(toWidth: 16 - suffix.displayWidth) + suffix
            if !names.contains(candidate) { return candidate }
        }
        return trimmed.truncated(toWidth: 16)
    }

    // MARK: - 整配置备份 / 还原

    /// 备份前的"干净配置"：只留点过「保存」的服务器，未保存的草稿不进备份，
    /// 免得还原到别的机器上混进一堆空壳。
    /// 注意：备份导出的是已保存副本（savedServers），不是带未保存改动的编辑值。
    private var cleanConfig: AppConfig {
        var out = config
        out.servers = config.servers.compactMap { savedServers[$0.id] }
        return out
    }

    func backupConfigLocal(to url: URL) {
        let out = cleanConfig
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(out)
            try data.write(to: url, options: .atomic)
            log("[系统] 配置已备份到 \(url.lastPathComponent)（\(out.servers.count) 个服务器）")
            showInfoDialog(title: "本地备份成功", text: "已备份到本机（\(out.servers.count) 台服务器）")
        } catch {
            log("[系统] 备份失败：\(error.localizedDescription)")
            showInfoDialog(title: "本地备份失败", text: "未能写入备份文件")
        }
    }

    func restoreConfigLocal(from url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let cfg = try JSONDecoder().decode(AppConfig.self, from: data)
            await applyRestored(cfg)
            log("[系统] 配置已还原")
            showInfoDialog(title: "本地还原成功", text: "配置已还原")
        } catch {
            log("[系统] 还原失败：文件不是有效的配置备份")
            showInfoDialog(title: "本地还原失败", text: "不是有效的配置备份")
        }
    }

    /// 把一份配置应用到当前 App。还原期间先停代理，避免配置和连接对不上。
    /// 还原前逐台校验，参数不完整的服务器直接跳过，不让坏数据污染整体。
    private func applyRestored(_ cfg: AppConfig) async {
        if isRunning || isStarting {
            log("[系统] 还原配置，先停止代理…")
            await stop()
        }
        var c = cfg
        var dropped = 0
        c.servers = c.servers.filter { s in
            if s.validate() == nil { return true }
            dropped += 1
            return false
        }
        if dropped > 0 { log("[系统] 还原时跳过 \(dropped) 台参数不完整的服务器") }
        if c.servers.isEmpty {
            var first = ServerConfig()
            first.name = "服务器 1"
            c.servers = [first]
        }
        if c.selectedID == nil || !c.servers.contains(where: { $0.id == c.selectedID }) {
            c.selectedID = c.servers.first?.id
        }
        config = c
        savedServers = Dictionary(uniqueKeysWithValues: c.servers.map { ($0.id, $0) })   // 还原的服务器一律视为已保存
        persist()
        rulesDirty = false
        applyDockIconPolicy()
        refreshProxySummary()
        log("[系统] 配置已还原（\(c.servers.count) 个服务器）")
    }

    // MARK: - WebDAV

    /// 当前 WebDAV 账号在钥匙串里的密码
    var webdavPassword: String? {
        guard let u = config.webdav?.username, !u.isEmpty else { return nil }
        return KeychainStore.read(account: u)
    }

    func saveWebDAV(url: String, username: String, password: String, directory: String) {
        let cleanURL = url.trimmingCharacters(in: .whitespaces)
        let user = username.trimmingCharacters(in: .whitespaces)
        config.webdav = WebDAVConfig(url: cleanURL, username: user, directory: directory.trimmingCharacters(in: .whitespaces))
        persist()   // 只落盘已保存服务器，别把未保存草稿一起写进去
        if !user.isEmpty && !password.isEmpty {
            KeychainStore.save(account: user, password: password)
        }
        log("[系统] WebDAV 设置已保存")
    }

    func backupToWebDAV() async {
        guard let w = config.webdav, !w.url.isEmpty else {
            showInfoDialog(title: "WebDAV 备份", text: "请先填写 WebDAV 地址")
            return
        }
        guard let url = WebDAVClient.endpoint(w.url, directory: w.directory) else {
            showInfoDialog(title: "WebDAV 备份", text: "WebDAV 地址无效")
            return
        }
        guard let password = webdavPassword else {
            showInfoDialog(title: "WebDAV 备份", text: "请先设置 WebDAV 密码")
            return
        }
        webdavBusy = true
        defer { webdavBusy = false }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(cleanConfig)
            try await WebDAVClient.upload(data, to: url, username: w.username, password: password)
            log("[系统] 已备份到 WebDAV")
            showInfoDialog(title: "WebDAV 备份", text: "已备份到 WebDAV")
        } catch {
            let msg = describeWebDAVError(error)
            log("[系统] WebDAV 备份失败：\(msg)")
            showInfoDialog(title: "WebDAV 备份失败", text: "服务器连接失败")
        }
    }

    /// WebDAV 错误按原因分类（3+1：认证失败 / 网络不通 / 服务器问题 + 其他兜底），
    /// 供日志与失败弹窗共用。
    private func describeWebDAVError(_ error: Error) -> String {
        if let we = error as? WebDAVError {
            switch we {
            case .badURL:
                return "其他错误：WebDAV 地址无效"
            case .badStatus(let code):
                switch code {
                case 401, 403:
                    return "认证失败：用户名 / 密码不正确，或服务器要求登录"
                case 404:
                    return "服务器问题：文件或目录不存在（检查地址与目录）"
                case 405:
                    return "服务器问题：不支持写入，可能不是 WebDAV 服务"
                case 507:
                    return "服务器问题：存储空间不足"
                default:
                    return "服务器问题：返回 HTTP \(code)"
                }
            }
        }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut, .cannotFindHost, .dnsLookupFailed,
                 .cannotConnectToHost, .notConnectedToInternet,
                 .networkConnectionLost:
                return "网络不通：无法连接到服务器（检查网络或地址）"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected:
                return "网络不通：SSL / TLS 证书验证失败"
            default:
                return "网络不通：\(error.localizedDescription)"
            }
        }
        return "其他错误：\(error.localizedDescription)"
    }

    func restoreFromWebDAV() async {
        guard let w = config.webdav, !w.url.isEmpty else {
            showInfoDialog(title: "WebDAV 还原", text: "请先填写 WebDAV 地址")
            return
        }
        guard let url = WebDAVClient.endpoint(w.url, directory: w.directory) else {
            showInfoDialog(title: "WebDAV 还原", text: "WebDAV 地址无效")
            return
        }
        guard let password = webdavPassword else {
            showInfoDialog(title: "WebDAV 还原", text: "请先设置 WebDAV 密码")
            return
        }
        webdavBusy = true
        defer { webdavBusy = false }
        do {
            let data = try await WebDAVClient.download(from: url, username: w.username, password: password)
            let cfg = try JSONDecoder().decode(AppConfig.self, from: data)
            await applyRestored(cfg)
            log("[系统] 已从 WebDAV 还原配置")
            showInfoDialog(title: "WebDAV 还原", text: "已从 WebDAV 还原")
        } catch {
            let msg = describeWebDAVError(error)
            log("[系统] WebDAV 还原失败：\(msg)")
            showInfoDialog(title: "WebDAV 还原失败", text: "服务器连接失败")
        }
    }

    /// 删除 WebDAV 服务器上的备份文件（不删本地配置）。
    func deleteWebDAVBackup() async {
        guard let w = config.webdav, !w.url.isEmpty else {
            showInfoDialog(title: "删除远程WebDAV备份", text: "请先填写 WebDAV 地址")
            return
        }
        guard let url = WebDAVClient.endpoint(w.url, directory: w.directory) else {
            showInfoDialog(title: "删除远程WebDAV备份", text: "WebDAV 地址无效")
            return
        }
        guard let password = webdavPassword else {
            showInfoDialog(title: "删除远程WebDAV备份", text: "请先设置 WebDAV 密码")
            return
        }
        webdavBusy = true
        defer { webdavBusy = false }
        do {
            try await WebDAVClient.delete(from: url, username: w.username, password: password)
            log("[系统] 已删除 WebDAV 上的备份")
            showInfoDialog(title: "删除远程WebDAV备份", text: "已删除 WebDAV 上的备份")
        } catch {
            let msg = describeWebDAVError(error)
            log("[系统] 删除远程WebDAV备份失败：\(msg)")
            showInfoDialog(title: "删除远程WebDAV备份失败", text: "服务器连接失败")
        }
    }

    /// 删除已保存的 WebDAV 服务器设置（含钥匙串里的密码），不再作为备份目标。
    func removeWebDAVServer() {
        if let u = config.webdav?.username, !u.isEmpty {
            KeychainStore.delete(account: u)
        }
        config.webdav = nil
        persist()
        log("[系统] 已删除 WebDAV 服务器")
    }

    /// App 退出前的收尾：停内核 + 还原系统代理，避免把用户网络留在坏状态。
    /// 退出时记录代理是否在运行，供下次启动自动恢复（更新重启也恢复）。
    static let proxyWasRunningKey = "EchOS.proxyWasRunning"

    func shutdown() {
        // 退出前快照代理运行状态：下次启动（含自动更新重启）据此自动恢复
        UserDefaults.standard.set(isRunning, forKey: Self.proxyWasRunningKey)
        // 退出前清掉自检结论：新一轮启动会重新自检，残留的失败态不该
        // 在下次启动时继续影响状态灯/恢复逻辑。
        checkState = .idle
        if proxyTakenOver { SystemProxy.restore() }
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        KernelPID.clear()
        // 只有已保存过服务器、或本来就有配置文件时才落盘：
        // 全新安装啥都没保存就退出，不凭空生成配置文件（否则下次启动
        // 会被当成"空配置"而不是"全新安装"，命名框就不会弹了）。
        if !savedServers.isEmpty || FileManager.default.fileExists(atPath: AppConfig.fileURL.path) {
            persist()
        }
        LogFile.close()
    }

    // MARK: - 更新

    /// 启动时调用：上次退出时代理正在运行则自动恢复（含自动更新重启）。
    /// 一次性标志：恢复尝试后即清除，避免每次冷启动都自动连。
    /// 若上次异常退出（崩溃/强杀）导致系统代理残留接管，则自愈还原：
    /// 旧标记下本地端口早已没人监听，留着会让浏览器流量打到黑洞、图标假蓝。
    func restoreProxyIfNeeded() {
        let shouldRestore = UserDefaults.standard.bool(forKey: Self.proxyWasRunningKey)
        UserDefaults.standard.set(false, forKey: Self.proxyWasRunningKey)
        if shouldRestore && !isRunning && !isStarting {
            log("[系统] 上次退出时代理正在运行，自动恢复代理…")
            start()
        } else if SystemProxy.isActive && !isRunning && !isStarting {
            log("[系统] 检测到残留的系统代理接管，正在还原…")
            proxyTakenOver = false
            Task.detached { SystemProxy.restore() }
        }
    }

    /// 启动时调用：后台检查 App 新版本 + 分流数据，都不阻塞启动。
    /// 延后几秒再查，先把窗口和菜单栏准备好，网络慢也不影响首屏。
    func checkForUpdatesAtStartup() {
        refreshGeoStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkEverything(silent: true)
        }
    }

    /// 菜单栏「检查更新」：软件版本 + 分流数据一起查。
    /// silent = 启动时的静默检查（geo 更新不打断，只写日志）。
    func checkEverything(silent: Bool = false) {
        checkAppUpdate(silent: silent)
        updateGeoData(force: false, silent: silent)
    }

    /// 检查 App 是否有新版本（手动/启动共用）。completion 在结果确定后主线程回调。
    /// 手动检查（silent = false）结果用独立 NSAlert 显示，不打开主窗口。
    func checkAppUpdate(silent: Bool, completion: (() -> Void)? = nil) {
        guard !Updater.repo.isEmpty else {
            updateStatus = "未配置更新源，无法检查更新"
            if !silent { showSimpleDialog("未配置更新源，无法检查更新") }
            completion?()
            return
        }
        log("[更新] 正在检查新版本…")
        Updater.fetchLatestRelease { [weak self] info in
            guard let self else { completion?(); return }
            guard let info else {
                self.updateStatus = "检查失败（网络或 GitHub 不可达）"
                self.log("[更新] 检查失败：网络或 GitHub 不可达")
                if !silent { self.showSimpleDialog("检查更新失败，请检查网络") }
                completion?()
                return
            }
            let local = Updater.parseVersion(Updater.localVersion)
            let remote = Updater.parseVersion(info.version)
            if Updater.version(remote, isNewerThan: local) {
                self.updateInfo = info
                self.updateStatus = "发现新版本 \(info.tag)"
                self.log("[更新] 发现新版本 \(info.tag)（当前 \(Updater.localVersion)）")
                self.promptUpdateDialog(info)   // 独立弹窗，不打开主窗口
            } else {
                self.updateStatus = "已是最新版本"
                self.log("[更新] 已是最新版本（\(Updater.localVersion)）")
                if !silent { self.showSimpleDialog("已是最新版本（v\(Updater.localVersion)）") }
            }
            completion?()
        }
    }

    /// 把弹窗放到所在屏幕上部居中：水平居中、垂直靠上（顶部留 120pt），
    /// 符合 macOS 对话框"靠上"的原生观感。runModal() 的模态循环会自行重排
    /// 窗口位置/尺寸（长文本尤其明显），所以用 Timer 在模态会话期间持续
    /// 把窗口拉回目标位置。Timer 同时挂 .default / .common / .modalPanel
    /// 三种 runloop mode——runModal 实际用哪个 mode 都能触发。
    /// 先激活 App，弹窗才不会躲在别的窗口后面变成"看不见的残留窗口"。
    static func runModalTopCentered(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        alert.layout()
        let win = alert.window
        positionTopCenter(win)
        win.makeKeyAndOrderFront(nil)
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated { positionTopCenter(win) }
        }
        let rl = RunLoop.main
        rl.add(timer, forMode: .default)
        rl.add(timer, forMode: .common)
        rl.add(timer, forMode: .modalPanel)
        let resp = alert.runModal()
        timer.invalidate()
        // 模态结束立即隐藏窗口：accessory（无 Dock 图标）模式下模态窗口
        // 有时不会自动消失，会残留成菜单栏下方的透明幽灵窗——一次弹窗留
        // 一个、越积越多（每个都占着屏幕上的一个空位，点不掉）。
        win.orderOut(nil)
        return resp
    }

    /// 手动把窗口放到所在屏幕上部居中。不用 win.center()：它在 modal 窗口上
    /// 基准不可靠（实测可见区中心在 (960,558)，center() 却停在 (960,740)），
    /// 自己算坐标最可控。
    @MainActor
    private static func positionTopCenter(_ win: NSWindow) {
        guard let screen = win.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let f = win.frame
        win.setFrameOrigin(NSPoint(x: vf.midX - f.width / 2, y: vf.maxY - f.height - 120))
    }

    /// 单一按钮的信息弹窗（检查更新的"已是最新/失败/未配置"结果）。
    private func showSimpleDialog(_ text: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "检查更新"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        _ = Self.runModalTopCentered(alert)
    }

    /// 通用信息提示弹窗（自定义标题）。如备份/还原结果。
    private func showInfoDialog(title: String, text: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.icon = NSApp.applicationIconImage
            alert.messageText = title
            alert.informativeText = text
            alert.addButton(withTitle: "好")
            _ = Self.runModalTopCentered(alert)
        }
    }

    /// 发现新版本时的独立弹窗（不打开主窗口）。
    /// 标题（加粗）= 当前版本；正文 = 发现新版本。
    private func promptUpdateDialog(_ info: Updater.ReleaseInfo) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "EchOS 版本：\(Updater.localVersion)"
        alert.informativeText = "发现新版本 \(info.tag)"
        alert.addButton(withTitle: "下载并更新")
        alert.addButton(withTitle: "以后再说")
        if Self.runModalTopCentered(alert) == .alertFirstButtonReturn {
            downloadUpdate()
        }
    }

    /// 下载新版 DMG 到 ~/Downloads，完成后自动替换 /Applications 里的旧版并重启。
    func downloadUpdate() {
        guard let info = updateInfo else { return }
        showDownloadProgress()
        downloadProgress = 0
        updateStatus = "正在下载 \(info.dmgName ?? "新版本")…"
        log("[更新] 开始下载 \(info.dmgName ?? "")…")
        let downloader = Updater.downloadDMG(info) { [weak self] p in
            self?.downloadProgress = p
            self?.updateStatus = String(format: "正在下载 %.0f%%…", p * 100)
            self?.updateDownloadProgress(p)
        } finish: { [weak self] url in
            guard let self else { return }
            let cancelled = self.activeDownloader?.isCancelled ?? false
            self.activeDownloader = nil
            self.hideDownloadProgress()
            self.downloadProgress = nil
            if cancelled {
                self.updateStatus = "下载已取消"
                self.log("[更新] 下载已取消")
            } else if let url {
                self.updateStatus = "下载完成，正在替换…"
                self.log("[更新] 下载完成：\(url.path)")
                self.performAutoUpdate(dmgURL: url)
            } else {
                self.updateStatus = "下载失败"
                self.log("[更新] 下载失败，请稍后重试")
            }
        }
        activeDownloader = downloader
    }

    // MARK: - 下载进度面板（独立小窗，主窗口隐藏时也能看到进度）

    private var progressPanel: NSPanel?
    private var progressIndicator: NSProgressIndicator?
    /// 当前正在进行的 DMG 下载器（供取消）
    private var activeDownloader: DMGDownloader?

    /// 点进度面板的「取消」：中断下载并关面板。
    @objc func cancelDownload() {
        activeDownloader?.cancel()
        activeDownloader = nil
        hideDownloadProgress()
        downloadProgress = nil
        updateStatus = "下载已取消"
        log("[更新] 下载已取消")
    }

    /// 下载开始时弹出带进度条的小面板。
    private func showDownloadProgress() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.title = "正在下载更新"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "正在下载 \(updateInfo?.dmgName ?? "新版本")…")
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center   // 内容居中
        label.lineBreakMode = .byTruncatingMiddle

        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = 0

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelDownload))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"   // Esc 键取消
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, indicator, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX   // 内容水平居中
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.widthAnchor.constraint(equalToConstant: 340).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 20).isActive = true
        cancelButton.widthAnchor.constraint(equalToConstant: 80).isActive = true
        panel.contentView = stack

        panel.center()
        panel.orderFrontRegardless()
        progressPanel = panel
        progressIndicator = indicator
    }

    /// 下载进度回调：主线程更新进度条。
    private func updateDownloadProgress(_ p: Double) {
        progressIndicator?.doubleValue = p
    }

    /// 下载结束（成功/失败）关掉进度面板。
    private func hideDownloadProgress() {
        progressPanel?.orderOut(nil)
        progressPanel = nil
        progressIndicator = nil
    }

    /// 自动更新：挂载 DMG → 写更新脚本 → 退出主进程 → 脚本替换 /Applications 后重启。
    /// 任一步失败都退回"打开 DMG 手动拖入"。
    private func performAutoUpdate(dmgURL: URL) {
        guard let mountPoint = Updater.mountDMG(dmgURL) else {
            updateStatus = "自动更新失败，已退回手动方式"
            log("[更新] DMG 挂载失败，请手动打开并拖入 Applications")
            NSWorkspace.shared.open(dmgURL)
            return
        }
        let newApp = URL(fileURLWithPath: mountPoint).appendingPathComponent("EchOS.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            updateStatus = "自动更新失败，已退回手动方式"
            log("[更新] DMG 里没找到 EchOS.app，请手动拖入")
            hdiutilDetach(mountPoint)
            NSWorkspace.shared.open(dmgURL)
            return
        }
        guard let scriptURL = writeUpdateScript(newAppPath: newApp.path, mountPoint: mountPoint, dmgPath: dmgURL.path) else {
            updateStatus = "自动更新失败，已退回手动方式"
            log("[更新] 更新脚本创建失败，请手动拖入")
            hdiutilDetach(mountPoint)
            NSWorkspace.shared.open(dmgURL)
            return
        }
        updateStatus = "正在重启 App 完成更新…"
        log("[更新] 正在替换 /Applications/EchOS.app 并重启…")
        // 脚本先在后台跑起来；它等主进程退出后再替换，所以这里退出主进程
        launchDetached(scriptURL, newAppPath: newApp.path, mountPoint: mountPoint, dmgPath: dmgURL.path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.shutdown()
            NSApp.terminate(nil)
        }
    }

    /// 把更新脚本写到 /tmp，返回路径。脚本：等 EchOS 退出 → 替换 → 删 DMG → 重启。
    private func writeUpdateScript(newAppPath: String, mountPoint: String, dmgPath: String) -> URL? {
        let script = """
        #!/bin/bash
        APP="/Applications/EchOS.app"
        NEW="$1"
        MP="$2"
        DMG="$3"
        for i in $(seq 1 200); do
          if ! pgrep -x "EchOS" > /dev/null 2>&1; then break; fi
          sleep 0.1
        done
        # 无论旧实例是正常退出还是超时，这里都无条件强制结束它，并留一点时间给
        # 系统移除它的菜单栏图标，再启动新实例——避免"新旧两个图标短暂并存"。
        # 停在 pkill 时新实例尚未启动，不会误杀自己。
        pkill -x "EchOS" 2>/dev/null || true
        sleep 2
        rm -rf "$APP"
        cp -R "$NEW" "$APP" 2>/dev/null
        chmod +x "$APP/Contents/MacOS/EchOS" 2>/dev/null
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        if [ -n "$MP" ]; then hdiutil detach "$MP" > /dev/null 2>&1; fi
        # 更新替换成功才删除已下载的 DMG；失败退回手动方式时保留它
        if [ -n "$DMG" ] && [ -f "$DMG" ]; then rm -f "$DMG"; fi
        # 写更新标记：新实例启动时据此只弹"更新完成"、不打开主窗口
        VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null)
        MARKER="$HOME/Library/Application Support/EchOS/.updated-version"
        mkdir -p "$HOME/Library/Application Support/EchOS"
        echo "$VER" > "$MARKER"
        # 重启用直接后台执行二进制，不用 open：open 在脚本上下文不可靠（曾返回
        # 成功却没拉起进程、或新旧 bundle 注册残留导致不启动），直接执行已验证
        # 能正常出现菜单栏图标。后台 + disown 让新进程脱离脚本会话独立存活。
        "$APP/Contents/MacOS/EchOS" > /dev/null 2>&1 &
        disown
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("echos-update-\(Int(Date().timeIntervalSince1970)).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// 后台启动脚本（不等待）。父进程退出后脚本继续执行。
    private func launchDetached(_ script: URL, newAppPath: String, mountPoint: String, dmgPath: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, newAppPath, mountPoint, dmgPath]
        try? p.run()
    }

    private func hdiutilDetach(_ mountPoint: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["detach", mountPoint]
        try? p.run()
        p.waitUntilExit()
    }

    /// 更新分流数据。silent = 启动时的静默检查（不打断用户，只写日志）。
    func updateGeoData(force: Bool, silent: Bool = false) {
        guard !geoUpdating else { return }
        geoUpdating = true
        if !silent { log("[更新] 开始更新分流数据…") }
        Updater.updateGeoData(force: force,
                              log: { [weak self] text in self?.log(text) }) { [weak self] ok, message in
            guard let self else { return }
            self.geoUpdating = false
            self.log("[更新] \(message)")
            self.refreshGeoStatus()
        }
    }

    /// 刷新界面上"分流数据"行的文案
    func refreshGeoStatus() {
        let v = Updater.localGeoVersion()
        if v.isEmpty {
            geoStatus = "未更新（使用 App 内置数据）"
        } else {
            geoStatus = "数据版本 \(v)（\(Updater.hasLocalGeoData() ? "已下载到本地" : "使用内置数据")）"
        }
    }
}
