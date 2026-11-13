// 授权：激活、校验、以及「此刻要不要拦着用户」。
//
// Swift 移植自 Windows 端 EchOS-Flutter-ZCode 的 lib/services/license_service.dart，
// 状态机、触发节奏、复核护栏逐条对齐；行为依据见 docs/archive/授权流程.md。
//
// ## 整体模型（服务端签码，客户端只是照着走）
//   1. 客户端算出设备码（DeviceIdentity）：ECHC-XXXX-XXXX-XXXX-XXXX。
//   2. 用户经 TG 机器人或管理后台拿到激活码（ECHS-XXXX-XXXX-XXXX-XXXX），
//      填回客户端，调 /activate 去「领」——把服务端那条记录从 pending 改 active。
//   3. 之后每次启动/定时/被催，客户端调 /verify 问一句「我还算数吗」。纯读。
//
// ## 哪些情况不拦
//   active          本次联网校验通过
//   notConfigured   构建时没注入授权地址（本地开发包，Info.plist 无 EchOSLicenseURL）
//   enforcementOff  服务端把全局强制开关关了（管理员手动打开的逃生门）
//   unreachable     且本机留有成功校验记录——拦新不杀旧，重启不比会话更危险
//                    （见 blocked；吊销绕行仍关死，否定结论落地即清时间戳）
// 其余情况——没登记、码没领、被吊销、封禁、从未可用过的断网、返回看不懂——一律拦。
// 连不上也拦（无离线宽限期）：断网放行等于给吊销开洞。代价由服务端的
// enforce 开关承担，客户端侧不留后门。
//
// ## 激活信息存在哪、为什么不会被顺走
// ~/Library/Application Support/EchOS/license.json（0600），只存设备码、
// 激活码、上次校验成功时间。刻意不进 AppConfig（config.json）：服务器分享、
// 本地/WebDAV 备份序列化的都是 AppConfig，激活信息一旦进去就随备份外传。
// 卸载 App 不删该目录，重装后不必重新激活。

import Foundation
import Combine

/// 客户端在授权这件事上的全部状态。界面直接按这个分支，不自己拼字符串判断。
enum LicenseStage: Equatable {
    /// 还没问过服务端（启动瞬间）。
    case unknown
    /// 没配授权服务地址：不拦截，本地开发用。
    case notConfigured
    /// 服务端不认识这台设备：还没人给它发过码（或记录被删除/解绑）。
    case unregistered
    /// 服务端已经给这台设备发过码，但用户还没把码填进来领。
    case codeIssued
    /// 已激活，且本次联网校验通过。
    case active
    /// 授权被吊销。
    case revoked
    /// 授权被管理员封禁（黑名单）。与吊销同处置：立即停代理。
    case banned
    /// 服务端把全局强制校验关了，所有设备一律放行。
    /// 这一档**不代表本机已激活**——它只表示服务端此刻不拦。
    case enforcementOff
    /// 网络异常 / 服务端返回看不懂的东西。一律拦。
    case unreachable
}

/// 一次校验/激活的结果。ok 只表示「这一步网络往返成功且服务端认了」，
/// 不等于「已激活」——想问激活状态看 stage。
struct LicenseResult {
    let ok: Bool
    let stage: LicenseStage
    let message: String
    /// 这一发是「手动校验节流命中」的维持现状答复：没有产生任何新信息
    ///（没发请求、没到结论），界面**不应**据此刷新消息行——否则断网时连点
    /// 按钮，状态行会在「连接失败」（真实失败）与旧档位结论（节流答复带
    /// ok:true）之间来回翻面。
    var throttled = false
}

@MainActor
final class LicenseService: ObservableObject {
    static let shared = LicenseService()
    private init() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "EchOSLicenseURL") as? String ?? ""
        baseUrl = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 授权服务地址。构建期注入（build.sh 把 ECH_LICENSE_URL 写进 App 包的
    /// Info.plist），为空 = 不启用授权（本地开发包，永不拦截）。
    private let baseUrl: String
    var enabled: Bool { !baseUrl.isEmpty }

    // MARK: - 对外状态

    @Published private(set) var stage: LicenseStage = .unknown
    @Published private(set) var message = ""
    @Published private(set) var lastVerifiedAt: Date?
    /// 首验是否已出结果（首验落地前显示启动页，不显示主界面也不显示激活页）。
    @Published private(set) var bootstrapped = false

    private var code = ""
    /// 本地已存的激活码（激活页预填用；日志里只允许出现末四位）。
    var savedCode: String { code }
    var deviceCode: String { DeviceIdentity.current }
    /// 授权服务基址（激活页「检查网络」的 HTTPS 探测用）；本地开发包返回空。
    var serverBaseURL: String { baseUrl }

    /// 重复广播当前状态。`@Published stage` 只在值**变化**时发事件，而
    /// 「断网→恢复」这类跳变 stage 可能压根没变（吊销/封禁被保留），
    /// 界面却需要一次通知来把快照对齐回真实档位。这个通道专门补这一类。
    let resyncSubject = PassthroughSubject<Void, Never>()

    /// 重发一遍当前状态的通知。激活成功后主界面靠 stage 变化切页，广播万一
    /// 被吞（监听器时序、微任务竞争），补一发就能把卡在激活页的实例拉回；
    /// 对已切换的实例是无害的幂等通知。
    func resync() { resyncSubject.send() }

    /// 上报版本标识：`<版本号>-Mac`（对接规范：平台短标编进 appVersion，
    /// 服务端识别集 Win/Mac/Linux/Android/iOS，总长 ≤32 字符；
    /// 服务端仅在值变化时写一次 KV，稳态零写）。版本号取 Info.plist 的
    /// CFBundleShortVersionString，与发布标签同一套编号。
    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard !v.isEmpty else { return "" }
        let tag = "\(v)-Mac"
        return String(tag.prefix(32))
    }

    /// 是否要拦「新的启动」（起不了隧道、不自动恢复代理）。
    ///
    /// 例外：**留下过成功校验记录的机器断网不算拦**。那条时间戳证明它曾经
    /// 通过校验，断网时它和会话中途掉线是同一处境（拦新不杀旧），重启不比
    /// 会话更危险。没有这条例外的后果是死锁：直连被劫持的环境里首验必然
    /// 失败 →「连不上就不恢复代理」→ 代理不跑、校验只能靠直连 → 永远拦死。
    /// 吊销绕行依然关死：任何否定结论落地时都会清掉这条时间戳。
    var blocked: Bool {
        if stage == .active || stage == .notConfigured || stage == .enforcementOff { return false }
        if stage == .unreachable && lastVerifiedAt != nil { return false }
        return true
    }

    /// blocked 里「服务器明确说不」的那一档：未登记、码未领、码被换、被吊销、被封禁。
    /// 与 unreachable（只是这一刻问不到答案）分开：后者本机多半是有授权的，
    /// 正在跑的会话不该被殃及。两个词对应两种处置：
    /// hardBlocked 停隧道/关窗即退，blocked 只是进不了主界面、起不了新隧道。
    var hardBlocked: Bool { blocked && stage != .unreachable }

    /// 是否整页锁成激活窗口。与 blocked 差一档：
    /// 服务器明确说不（hardBlocked）一定锁；unreachable 只在「这台机器
    /// 从来没有可用过、也没有本地凭证」时锁——全新机器或上次结论已是否定
    /// 的机器断网启动，没有可保的会话，拦新就该连界面一起拦，激活页正好
    /// 有「检查网络」这个自助入口。会话中途掉线的已激活用户不锁，主界面
    /// 照常、隧道照跑，恢复后复查自动回 active。
    var uiLocked: Bool {
        if hardBlocked { return true }
        return stage == .unreachable && !everUsable && lastVerifiedAt == nil
    }

    /// 授权日志出口。AppState 启动时接到自己的 log() 上；
    /// `[授权]` 前缀的行在 log() 里单独成册（authorization.log），保证
    /// 「这台机器此刻凭什么能用」的凭据不被日志级别开关吃掉。
    var onLog: ((String) -> Void)?

    /// 这台机器是否曾经走到过可用档（active/校验停用/未配置）。
    /// uiLocked 用它区分「从未可用过」与「用过但此刻断网」。
    private var everUsable = false

    /// 最近一次授权请求是否因网络失败。与 stage 解耦：硬拦档位（吊销/封禁）
    /// 在断网时被保留，那时 stage 不再是 unreachable，界面要判断「此刻到底
    /// 是不是断网」只能看这里。
    private(set) var netDown = false

    /// 最近一次网络失败的分类原因（连上后清空）。重新校验失败时并进状态行
    /// 那一句话里——一行信息原则下没有第二行放细节。
    private var netErrorHint: String?

    /// 本次校验是否经历了「断网 → 恢复」的跳变。恢复的瞬间要补发一次
    /// stage 事件（stage 未变也发）：激活页状态行的「连接失败」快照靠它
    /// 对齐回真实档位——吊销/封禁被保留时根本没有 stage 事件可等。
    private var netRecovered = false

    /// 重新校验失败时状态行的那句话：带具体原因，一行说完。
    var netFailHeadline: String {
        guard let h = netErrorHint, !h.isEmpty else {
            return "授权服务器连接失败，请检查网络"
        }
        return "授权服务器连接失败：\(h)，请检查网络"
    }

    private func authLog(_ msg: String) {
        onLog?("[授权] \(msg)")
    }

    /// 供视图层写入授权日志（如「检查网络」的失败定位信息）。
    func logAuth(_ msg: String) {
        authLog(msg)
    }

    // MARK: - 内部状态

    /// 服务端给的 TTL 锚点（revalidateAt）：在此之前自动校验自我抑制。
    private var revalidateAt: Date?
    /// 最近一次**真正发出** /verify 的时刻（TTL 抑制掉的、在途合并的都不计）。
    private var lastDispatchAt: Date?
    /// 最近一次 /verify 的 HTTP 状态码，仅用于授权日志说明文字，不参与判定。
    private var lastStatusCode = 0
    private var unreachableRetries = 0
    /// 「本机已激活，下一次校验却拿到否定答复」的双读复核计数。
    private var negStreak = 0
    /// 最近一次「有效」状态的记录变更时间（服务端时钟）。active 答复携带。
    private var lastPositiveAt: Date?
    /// 收到 resync 的时刻。用于判断「刚刚这次 active 答复可能是 KV 旧读」。
    private var resyncSeenAt: Date?
    /// 掉线兜底轮询的计数与起点（指数降档用）。
    private var outageTicks = 0
    private var activePollTicks = 0
    /// 隧道是否在跑（isRunning || isStarting），由 AppState 推送。
    private var tunnelRunning = false

    // 定时器
    private var tickTimer: Timer?          // 300s 基础 tick
    private var backstopTimer: Timer?      // 启动后 90s 补查
    private var quickRetryTimer: Timer?    // 失败 5s 快速重试
    private var rateRetryTimer: Timer?     // 429 retryAfter 补射
    private var resyncConfirmTimer: Timer? // resync 后 30s 确认复核
    private var negConfirmTimer: Timer?    // 双读复核 20s
    private var cutRecheckTimer: Timer?    // 切断后 30/90/90 三发复检
    private var activePollTimer: Timer?    // 运行期兜底轮询
    private var unreachableRecheckTimer: Timer? // 不可达恢复复查

    /// 推送在线时的慢速兜底校验间隔（分钟）。推送是尽力而为的通知，丢一次
    /// 就可能让吊销不被察觉，这条是唯一的保底。
    private static let safetyNetMinutes = 60
    /// resync 确认复核的等待时长。
    private static let resyncConfirmWindow: TimeInterval = 30
    /// 手动「重新校验」的客户端节流间隔：3 秒内的连点只放第一枪。
    /// 服务端对 /verify 本就有按 IP 的滑窗限流（撞线回 429），这里不是防
    /// 滥用，是替用户自己拦手——连点除了把自己点进 429、再触发一串限流
    /// 补射之外没有任何产出。节流到点后静默返回当前结论（不伪造新结果、
    /// 不动状态），人手正常节奏完全感知不到。
    private static let manualThrottle: TimeInterval = 3
    /// 上次手动校验的放行时刻（见 verify 开头的节流说明）。
    private var lastManualAt: Date?

    /// 推送通道。
    private lazy var push: LicensePush = makePush()
    var pushLive: Bool { push.isLive }
    var pushOutageMinutes: Int { push.outageMinutes }

    /// 在途校验：同一时刻至多一个，后来的调用共享同一个结果，而不是各发
    /// 一个请求再赌谁先回来。
    private var inFlightTask: Task<LicenseResult, Never>?
    /// 授权网络操作（verify/activate）的串行链：前一趟没落地，后一趟不出发。
    /// 两个并发请求，旧的那个晚回来会把刚生效的新状态（比如吊销）用旧答案
    /// 覆盖回去——串行之后时序自然有序。
    private var netChain: Task<Void, Never> = Task {}

    // MARK: - 启动

    /// 读本地状态 → 联网校验 → 起定时器与推送。App 启动时调一次（await）。
    func bootstrap() async {
        loadLocal()
        guard enabled else {
            authLog("本构建未配置授权服务器（缺少 ECHOS_LICENSE_URL）：属本地开发构建，不做任何校验与拦截")
            set(.notConfigured, "未配置授权服务器（本地构建）")
            bootstrapped = true
            return
        }
        message = "正在校验授权…"
        authLog("=== 启动：开始本次授权校验（设备 \(deviceCode)，客户端版本 \(appVersion)）===")
        let bootStart = Date()
        _ = await verify(source: "启动校验").value
        // 启动页至少停留 0.8 秒：网络极快时一闪而过，观感上等于「没有启动页」
        let elapsed = Date().timeIntervalSince(bootStart)
        if elapsed < 0.8 {
            try? await Task.sleep(nanoseconds: UInt64((0.8 - elapsed) * 1_000_000_000))
        }
        startTimers()
        push.start()
        bootstrapped = true
    }

    private func startTimers() {
        tickTimer?.invalidate()
        tickTimer = scheduledTimer(300, repeats: true) { [weak self] in self?.tick() }
        // 启动后 90 秒补查（事件驱动改造后仅 WS 掉线时才有意义：KV 最终
        // 一致 ~60 秒，推送在线时 resync 会自己来，掉线时这枪补窗口）。
        backstopTimer?.invalidate()
        backstopTimer = scheduledTimer(90) { [weak self] in
            guard let self, !self.pushLive else { return }
            self.verify(source: "启动补查")
        }
    }

    /// 基础 tick（300s）：推送在线 → 慢速兜底（60 分钟一次，普通 verify，
    /// 服务端 TTL 会抑制掉绝大多数）；掉线 → 按掉线时长跳 tick（指数降档）。
    private func tick() {
        if pushLive {
            if let last = lastDispatchAt,
               Date().timeIntervalSince(last) < Double(Self.safetyNetMinutes * 60) {
                return
            }
            authLog("推送在线，慢速兜底校验（距上次校验超过 \(Self.safetyNetMinutes) 分钟）")
            verify(source: "慢速兜底")
            return
        }
        let minsDown = pushOutageMinutes
        let step = minsDown >= 20 ? 3 : (minsDown >= 10 ? 2 : 1)
        let shouldRun = outageTicks % step == 0
        outageTicks += 1
        guard shouldRun else { return }
        authLog("推送通道掉线中（\(minsDown) 分钟），轮询兜底")
        // force：这两个轮询存在的意义就是「推送掉线期间的吊销感知」——
        // resync 收不到时它们是唯一通道，被服务端 TTL（revalidateAfter，
        // 最长 1 小时）压死等于吊销盲区。实测曾出现「吊销 3 分钟无响应、
        // 隧道照常可用」，根因即此。频次（≥5 分钟一次）远在限流之下。
        verify(force: true, source: "掉线轮询")
    }

    // MARK: - 运行期兜底轮询（隧道在跑时的第二条节奏）

    /// AppState 在 isRunning/isStarting 变化时推送。运行中的隧道是「吊销真正
    /// 要切断的对象」，运行期加密轮询：推送在线时暂停（秒级 resync 已覆盖），
    /// 推送掉线时 5 分钟一查、按掉线时长降档。unreachable 不算被拦：隧道还在
    /// 跑，轮询要继续——否则一次网络抖动过后，恢复全靠慢速兜底或回前台。
    func setTunnelRunning(_ running: Bool) {
        tunnelRunning = running
        syncActivePoll()
    }

    private func syncActivePoll() {
        if tunnelRunning && !hardBlocked && !pushLive {
            guard activePollTimer == nil else { return }
            activePollTicks = 0
            activePollTimer = scheduledTimer(300, repeats: true) { [weak self] in
                self?.activePollTick()
            }
        } else if activePollTimer != nil {
            activePollTimer?.invalidate()
            activePollTimer = nil
        }
    }

    private func activePollTick() {
        let minsDown = pushOutageMinutes
        let step = minsDown >= 20 ? 3 : (minsDown >= 10 ? 2 : 1)
        let shouldRun = activePollTicks % step == 0
        activePollTicks += 1
        guard shouldRun else { return }
        // force：同「掉线轮询」——运行中的隧道是吊销真正要切断的对象，
        // 推送掉线时它不能被 TTL 压成盲区
        verify(force: true, source: "运行期兜底")
    }

    // MARK: - 校验

    /// 问服务端「这台设备还算数吗」。
    /// 同一时刻至多一个校验在途（定时器、回前台、resync、运行期轮询可能同时
    /// 触发，在途时后来的共享同一个结果）；TTL 只拦自动来源——用户按钮/
    /// 启动预检/resync 推送传 force:true 击穿。
    @discardableResult
    func verify(force: Bool = false, source: String = "") -> Task<LicenseResult, Never> {
        if !enabled {
            return Task { LicenseResult(ok: true, stage: .notConfigured, message: "") }
        }
        // 手动「重新校验」的客户端节流：3 秒内的连点只放第一枪。
        // 服务端对 /verify 本就有按 IP 的滑窗限流（撞线回 429），这里不是
        // 防滥用，是替用户自己拦手——按钮连点除了把自己点进 429、再触发
        // 一串限流补射之外没有任何产出。节流到点后静默返回当前结论
        //（不伪造新结果、不动状态），人手正常节奏完全感知不到。
        // 界面靠 throttled 标志识别「这一发没有新信息」，不据此刷新消息行。
        if source == "用户手动" {
            let now = Date()
            if let last = lastManualAt, now.timeIntervalSince(last) < Self.manualThrottle {
                let s = stage, m = message
                authLog("手动校验节流命中：距上次点击不足 \(Int(Self.manualThrottle)) 秒，本次不发请求")
                return Task { LicenseResult(ok: true, stage: s, message: m, throttled: true) }
            }
            lastManualAt = now
        }
        // 快速重试链已在 5 秒一发地轮询、或限流补射正在等服务端的 retryAfter
        // 时，回前台/窗口显示这类高频聚焦事件不再各补一枪——两条链本身就是
        // 既定的节奏，补枪只贡献请求量与 429（TUN 提权重启的焦点风暴正是靠
        // 它撞爆闸门的）；链落定后的聚焦照常触发，恢复真相不缺入口。
        if source == "回前台" || source == "窗口显示" || source == "系统唤醒" {
            if quickRetryTimer?.isValid == true || rateRetryTimer?.isValid == true {
                let s = stage, m = message
                return Task { LicenseResult(ok: true, stage: s, message: m) }
            }
        }
        if !force, let revalidateAt, Date() < revalidateAt {
            authLog("TTL 内跳过自动校验（服务端指示 \(Int(revalidateAt.timeIntervalSinceNow)) 秒内无需复查）"
                + (source.isEmpty ? "" : "，来源 \(source)"))
            let s = stage, m = message
            return Task { LicenseResult(ok: true, stage: s, message: m) }
        }
        if let running = inFlightTask { return running }
        // 记录「真发出去了」的时刻，慢速兜底据此算间隔；TTL 抑制与在途合并
        // 都不算，否则一次被抑制的调用会把兜底时钟往前推。
        lastDispatchAt = Date()
        if !source.isEmpty { authLog("校验触发来源：\(source)") }
        let task = chained { await self.verifyWithRetry() }
        inFlightTask = task
        Task { [weak self] in
            _ = await task.value
            self?.inFlightTask = nil
        }
        return task
    }

    private func verifyWithRetry() async -> LicenseResult {
        let r = await verifyOnce()
        // 断网→恢复的瞬间补发一次通知（stage 未变也要发）：激活页状态行的
        // 「连接失败」快照靠它对齐回真实档位（吊销/封禁被保留时没有 stage
        // 事件可等）。幂等，纯通知。
        if netRecovered {
            netRecovered = false
            resync()
        }
        if r.ok && !netDown {
            unreachableRetries = 0
            return r
        }
        // 本机过滤层/弱网常把个别请求掐成瞬时失败：失败后 5 秒自动补一发，
        // 连续快速重试有上限（约 1 分钟），之后交回周期与回前台校验。
        // 判据用 netDown 而不是 stage：硬拦档位（吊销/封禁）在断网时被保留，
        // stage 不再是 unreachable，但网络依然是断的——此时若停了重试链，
        // 管理员恢复授权后客户端就再也不会自己发现（隧道已停、推送多半也断）。
        if netDown && unreachableRetries < 12 {
            unreachableRetries += 1
            quickRetryTimer?.invalidate()
            quickRetryTimer = scheduledTimer(5) { [weak self] in
                guard let self, self.netDown else { return }
                self.verify(source: "失败重试")
            }
        }
        return r
    }

    private func verifyOnce() async -> LicenseResult {
        if !enabled { return LicenseResult(ok: true, stage: .notConfigured, message: "") }
        authLog("开始校验授权：设备码 \(deviceCode)"
            + (code.isEmpty ? "，本机未保存激活码" : "，本机已保存激活码"))
        // 携带本地保存的激活码：服务端比对记录里当前的码，不一致回
        // code_mismatch——管理端「修改激活码」后旧码持有者即被切断。
        guard let res = await post("/verify", [
            "deviceCode": deviceCode,
            "code": code,
            "appVersion": appVersion,
        ]) else {
            let r = handleUnreachable()
            authLog("校验未完成：连不上授权服务器（\(message)）")
            return r
        }
        if netDown { netRecovered = true }
        netDown = false
        netErrorHint = nil
        authLog(Self.httpNote("/verify", lastStatusCode, res["status"] as? String))

        switch res["status"] as? String {
        case "active":
            // 服务端 enforce 被关掉时会对**任何**设备都回这一档（包括从没
            // 登记过的），并带 active:false。意思是「服务器此刻放行」，不是
            // 「你已激活」——开关重新打开后还得靠 /verify 重新拿到真 active。
            if res["enforced"] as? Bool == false || res["active"] as? Bool == false {
                authLog("服务端强制校验已关闭：本次按放行处理，"
                    + "注意这不代表本机已激活（放行开关由管理员在后台控制）")
                negStreak = 0
                negConfirmTimer?.invalidate()
                set(.enforcementOff, "")
                return LicenseResult(ok: true, stage: .enforcementOff, message: "")
            }
            lastVerifiedAt = Date()
            saveLocal()
            unreachableRetries = 0
            negStreak = 0
            negConfirmTimer?.invalidate()
            // TTL 锚点：从这次成功答复起算 revalidateAfter 秒
            let ttl = (res["revalidateAfter"] as? NSNumber)?.intValue ?? 3600
            revalidateAt = Date().addingTimeInterval(TimeInterval(ttl))
            // 记下服务端侧的记录变更时间：后续否定答复用它判别「真变更」还是
            // 「KV 过期读」。
            lastPositiveAt = Self.parseServerDate(res["updatedAt"] as? String ?? "")
            // 刚被 resync 催过就拿到 active：可能问得太早、读到 KV 未收敛的
            // 旧值，吊销会被一份新鲜的权威答复吞掉。补一枪延后复核。
            scheduleResyncConfirm()
            authLog("校验通过：本机授权有效，记录本次成功时间")
            set(.active, "")
            return LicenseResult(ok: true, stage: .active, message: "")

        case "pending":
            authLog("尚未完成激活：服务端已签发激活码，等待用户填入领取")
            if !shouldApplyNegative(.codeIssued, res["updatedAt"] as? String ?? "") {
                return LicenseResult(ok: true, stage: .codeIssued, message: "")
            }
            set(.codeIssued, "激活码已签发，请将激活码粘贴到输入框后，点击「激活」完成注册")
            return LicenseResult(ok: true, stage: .codeIssued, message: message)

        case "revoked":
            revalidateAt = nil
            if !shouldApplyNegative(.revoked, res["updatedAt"] as? String ?? "") {
                return LicenseResult(ok: true, stage: .revoked, message: "")
            }
            lastVerifiedAt = nil
            saveLocal()
            authLog("校验未通过：管理员已吊销本机授权，客户端被拦下")
            set(.revoked, "客户端授权已吊销，如有问题请联系管理员反馈。")
            return LicenseResult(ok: true, stage: .revoked, message: "")

        case "banned":
            // 封禁与吊销同处置：立即停代理，不进复核——封禁不在 license 记录
            // 上、没有时间戳可比；管理语义就是「此人不可用」。
            lastVerifiedAt = nil
            saveLocal()
            authLog("校验未通过：该账号已被管理员封禁，名下设备全部停用")
            set(.banned, "客户端授权已被封禁，如有问题请联系管理员反馈。")
            return LicenseResult(ok: true, stage: .banned, message: "")

        case "code_mismatch":
            revalidateAt = nil
            // 管理端已更换本机的激活码：旧码持有者在此刻被切断。状态回到
            // 未登记同档（激活码卡片重现），用户填入新码即恢复。
            if !shouldApplyNegative(.unregistered, res["updatedAt"] as? String ?? "") {
                return LicenseResult(ok: true, stage: .unregistered, message: "")
            }
            lastVerifiedAt = nil
            saveLocal()
            authLog("校验未通过：管理端已更换本机激活码，本机保存的旧码作废，需向管理员索取新激活码")
            set(.unregistered, "激活码校验失败，请确认与设备绑定一致")
            return LicenseResult(ok: true, stage: .unregistered, message: message)

        case "unknown_device":
            revalidateAt = nil
            // 删除/解绑后记录不存在，没有时间戳可判别新旧。立即停代理不走
            // 复核：真被删除的机器多跑一秒都是白用；若是 KV 抖出的假 404，
            // 下次校验回到 active 自愈（隧道需手动重开，这是错杀的代价）。
            lastVerifiedAt = nil
            saveLocal()
            authLog("校验未通过：服务端查不到本设备码（已删除/解绑），立即停代理")
            set(.unregistered, "本机尚未登记，请前往TG群注册并获取激活码")
            return LicenseResult(ok: true, stage: .unregistered, message: "")

        case "rate_limited":
            // 限流不是授权结论，是「这一枪打得太快」：维持上一份已知结论，
            // 按服务端给的 retryAfter 排一次补射。补射必须 force（这次压根
            // 没拿到结论，让 TTL 拦住补射等于把判定永久丢掉）。
            let raw = (res["retryAfter"] as? NSNumber)?.intValue ?? 5
            let waitSec = min(max(raw, 2), 60)
            rateRetryTimer?.invalidate()
            rateRetryTimer = scheduledTimer(TimeInterval(waitSec)) { [weak self] in
                self?.verify(force: true, source: "限流重试")
            }
            authLog("校验被限流：维持上一次结论，\(waitSec) 秒后自动重试")
            return LicenseResult(ok: true, stage: stage, message: message)

        default:
            // 服务端加了新状态而客户端版本旧了。宁可拦住也不能当成已激活放过去。
            authLog("校验未通过：服务端返回了无法识别的状态「\(res["status"] ?? "nil")」，"
                + "可能是服务端已升级而客户端版本偏旧")
            set(.unreachable, "授权校验返回了无法识别的结果")
            return LicenseResult(ok: false, stage: .unreachable, message: message)
        }
    }

    /// 「本机已激活，下一次校验却拿到否定答复」的双读复核护栏。
    ///
    /// KV 是最终一致：管理端的吊销/恢复要约 60 秒才在全球边缘收敛。客户端
    /// 恰好在窗口里校验会读到旧值——刚激活的机器被打回激活页，来回翻面。
    /// 规则：stage == active 时收到「服务端明确说不」（仅 revoked/unregistered/
    /// codeIssued 三档），时间戳比 lastPositiveAt 新 → 真变更立即执行；否则
    /// 第一次只记日志、暂维持可用，20 秒后自动复核，连续两次否定才真正切换。
    /// fresh 启动（stage 还是 unknown 等）不受护栏影响，第一次否定立即拦。
    /// 返回 true = 这次否定应当生效；false = 已进入复核期，不改状态。
    private func shouldApplyNegative(_ next: LicenseStage, _ negUpdatedAt: String) -> Bool {
        if stage != .active {
            negStreak = 0
            return true
        }
        if next != .revoked && next != .unregistered && next != .codeIssued {
            return true
        }
        let negAt = Self.parseServerDate(negUpdatedAt)
        if let negAt, let posAt = lastPositiveAt, negAt > posAt {
            negStreak = 0
            negConfirmTimer?.invalidate()
            authLog("服务端答复的变更时间晚于本机最近一次有效状态——真实的最新变更，立即执行")
            return true
        }
        negStreak += 1
        if negStreak >= 2 {
            negStreak = 0
            negConfirmTimer?.invalidate()
            return true
        }
        authLog("服务端给出否定答复（\(Self.stageName(next))），但其变更时间不晚于本机"
            + "最近一次有效状态——大概率是 KV 传播未收敛的过期读。"
            + "暂维持本机可用，20 秒后自动复核；复核仍是否定将立即拦下。")
        negConfirmTimer?.invalidate()
        negConfirmTimer = scheduledTimer(20) { [weak self] in
            self?.verify(source: "否定复核")
        }
        return false
    }

    /// 连不上服务端时一律拦，没有例外分支（无离线宽限期）。
    private func handleUnreachable() -> LicenseResult {
        // 连不上时 TTL 必须让位：快速重试链要能立即出发。
        revalidateAt = nil
        netDown = true
        set(.unreachable, netFailHeadline)
        return LicenseResult(ok: false, stage: .unreachable, message: message)
    }

    /// resync 之后的确认复核：刚被服务端催过就拿到 active 时补一枪。
    /// 管理端写完 KV 立刻广播，客户端往往在写入后 1~2 秒就来问，而 Cloudflare
    /// KV 的写此刻还没收敛到读的那个边缘节点——拿到的是写入前的旧值 active。
    /// 这份答复把 TTL 推到一小时、推送在线时又不会有轮询，吊销就永久丢失。
    /// 间隔 30 秒（实测 KV 收敛约 4.4 秒，留近 7 倍余量），复核走 force。
    private func scheduleResyncConfirm() {
        guard let seen = resyncSeenAt else { return }
        let waited = Date().timeIntervalSince(seen)
        if waited > Self.resyncConfirmWindow {
            resyncSeenAt = nil
            return
        }
        resyncSeenAt = nil
        resyncConfirmTimer?.invalidate()
        resyncConfirmTimer = scheduledTimer(Self.resyncConfirmWindow) { [weak self] in
            guard let self else { return }
            self.authLog("resync 后确认复核：刚才那份「有效」有可能读到 KV 旧值，"
                + "现在重新问一次（间隔 30 秒）")
            self.verify(force: true, source: "resync确认")
        }
    }

    // MARK: - 状态迁移

    private func set(_ s: LicenseStage, _ msg: String) {
        let old = stage
        guard old != s else {
            message = msg
            return
        }
        stage = s
        message = msg
        if s == .active || s == .enforcementOff || s == .notConfigured {
            everUsable = true
        }
        onStageChanged(old, s)
        syncActivePoll()
        syncUnreachableRecheck()
    }

    /// unreachable 的快速归队：落在这个态时每 60 秒 force 复查一次，直到
    /// 离开为止。否则「一次网络抖动 + 推送在线」的组合会把恢复拖到慢速
    /// 兜底的下一个周期（最长 1 小时），期间状态文字一直喊「不可达」，
    /// 而网络其实早就通了（实测：chip 显示不可达、检查网络却 2ms）。
    private func syncUnreachableRecheck() {
        if stage == .unreachable {
            guard unreachableRecheckTimer == nil else { return }
            unreachableRecheckTimer = scheduledTimer(60, repeats: true) { [weak self] in
                guard let self, self.stage == .unreachable else { return }
                self.verify(force: true, source: "不可达恢复复查")
            }
        } else {
            unreachableRecheckTimer?.invalidate()
            unreachableRecheckTimer = nil
        }
    }

    /// 状态迁移钩子：从 active 落到任一「服务器明确说不」的档位时，隧道已被
    /// 停掉、运行期轮询随之取消——若管理员其实刚做了「吊销→恢复」，
    /// 靠慢速兜底回 active 要等一小时。切断后头几分钟用短周期复检兜底：
    /// 30s / 120s / 300s 各补一发（读到 active 立即恢复，幂等纯读）。
    /// 只覆盖「曾处于 active」的会话——全新机器的首次否定没有可失去的东西。
    private func onStageChanged(_ old: LicenseStage, _ s: LicenseStage) {
        cutRecheckTimer?.invalidate()
        cutRecheckTimer = nil
        cutRecheckCount = 0
        guard old == .active, s != .active else { return }
        switch s {
        case .revoked, .banned, .unregistered, .codeIssued: break
        default: return
        }
        cutRecheckCount = 3
        scheduleCutRecheck(30)
    }

    private var cutRecheckCount = 0

    private func scheduleCutRecheck(_ delay: TimeInterval) {
        cutRecheckTimer = scheduledTimer(delay) { [weak self] in
            guard let self, self.cutRecheckCount > 0 else { return }
            self.cutRecheckCount -= 1
            self.authLog("切断后复检（剩余 \(self.cutRecheckCount) 次）：确认服务端最新状态")
            self.verify(source: "切断复检")
            if self.cutRecheckCount > 0 {
                self.scheduleCutRecheck(90)
            }
        }
    }

    // MARK: - 激活

    /// 用激活码领授权。成功即本地落盘并进入 active。
    /// 格式先卡一道：必须严格是 ECHS-XXXX-XXXX-XXXX-XXXX，不做静默归一——
    /// 发出去的串就是用户看到的那串。
    func activate(_ raw: String) async -> LicenseResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            authLog("提交激活失败：没有输入任何内容")
            return LicenseResult(ok: false, stage: .unknown, message: "请输入激活码")
        }
        if !ActivationCodeValidator.isValid(trimmed) {
            authLog("提交激活失败：激活码格式不正确"
                + "（应为 ECHS-XXXX-XXXX-XXXX-XXXX，大写且含连字符，原样复制即可）")
            return LicenseResult(ok: false, stage: .unknown,
                                 message: "激活码格式不正确，应为 ECHS-XXXX-XXXX-XXXX-XXXX（大写、含连字符）")
        }
        if !enabled {
            authLog("提交激活失败：当前构建未配置授权服务器，无法激活")
            return LicenseResult(ok: false, stage: .notConfigured, message: "未配置授权服务器")
        }
        // 码本身不落日志：授权日志用户能直接看到，留一份激活码在那里等于
        // 把它抄送给每个看得到日志的人。对账只看末四位。
        authLog("提交激活：设备码 \(deviceCode)，激活码末四位 …\(trimmed.suffix(4))")
        // 排到串行链上：此刻若有 /verify 在途，先让它落地——它的响应取自
        // 激活写入之前的服务端状态，一旦晚于 activate 返回，会把刚激活的
        // 机器又打回未激活。
        return await chained { () -> LicenseResult in
            guard let res = await self.post("/activate", [
                "deviceCode": self.deviceCode,
                "code": trimmed,
                "appVersion": self.appVersion,
            ]) else {
                let r = self.handleUnreachable()
                self.authLog("提交激活未完成：连不上授权服务器")
                return r
            }
            self.authLog(Self.httpNote("/activate", self.lastStatusCode, res["status"] as? String))
            self.netDown = false
            self.netErrorHint = nil
            switch res["status"] as? String {
            case "active":
                self.code = trimmed
                self.lastVerifiedAt = Date()
                self.saveLocal()
                self.authLog("激活成功：本机设备码与激活码已绑定，授权生效")
                self.set(.active, "激活成功")
                return LicenseResult(ok: true, stage: .active, message: "激活成功")
            case "invalid_code":
                self.authLog("激活失败：服务端不存在这张激活码，请确认是否复制完整或已被管理员回收")
                return LicenseResult(ok: false, stage: .unknown, message: "该激活码不存在")
            case "revoked":
                self.authLog("激活失败：这张激活码已被管理员吊销")
                return LicenseResult(ok: false, stage: .revoked, message: "该激活码已被吊销")
            case "device_mismatch":
                self.authLog("激活失败：该激活码绑定的是另一台设备（本机 \(self.deviceCode)），一机一码，不能跨设备使用")
                return LicenseResult(ok: false, stage: .unknown,
                                     message: "激活码与本机不匹配，请正确输入本机绑定的激活码。")
            case "rate_limited":
                // 限流是激活这一步里唯一「稍后重试真的会好」的失败：服务端
                // 按 IP 开了闸门（activateGate），与码对不对无关，不能报成
                // 「激活码不存在」让用户白换码。retryAfter 服务端必带。
                let raw = (res["retryAfter"] as? NSNumber)?.intValue ?? 5
                let waitSec = min(max(raw, 2), 60)
                self.authLog("激活被限流：\(waitSec) 秒后可再试（服务端按 IP 计数）")
                return LicenseResult(ok: false, stage: .unknown,
                                     message: "操作过于频繁，请 \(waitSec) 秒后再试")
            case "banned":
                // 封禁是终态，重试永远过不去，唯一出路是联系管理员——
                // 不能落进 default 的「请稍后重试」。
                self.authLog("激活失败：该激活码对应的账号已被管理员封禁")
                return LicenseResult(ok: false, stage: .banned,
                                     message: "该账号已被封禁，如有问题请联系管理员反馈。")
            default:
                self.authLog("激活失败：服务端返回了无法识别的状态「\(res["status"] ?? "nil")」")
                return LicenseResult(ok: false, stage: .unknown, message: "激活失败，请稍后重试")
            }
        }.value
    }

    // MARK: - 授权群邀请链接

    /// 邀请链接的本地缓存文件。与 license.json 同一目录，但它不是凭证：
    /// 丢了只是按钮晚一拍出现，不参与任何判定。
    private var inviteCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchOS/invite-link.txt")
    }

    /// 最近一次联网取到的邀请链接。服务端取不到时激活页用这份兜底显示按钮；
    /// 从未联网取到过（全新机器且一直没网）才是空——那种情况没有可跳的地址，
    /// 隐藏按钮是诚实的做法。没网的时候恰恰最需要这个入口，所以必须缓存。
    var cachedInviteLink: String {
        (try? String(contentsOf: inviteCacheURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func saveInviteCache(_ link: String) {
        guard !link.isEmpty else { return }
        try? FileManager.default.createDirectory(at: inviteCacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? link.write(to: inviteCacheURL, atomically: true, encoding: .utf8)
    }

    /// 激活窗口「去 TG 群」要跳的链接。链接放服务端是为了改链接不必重新发版；
    /// 取不到时回空串，界面上就不显示那个按钮——这一项只影响跳转，
    /// 为它失败没有意义（服务端也刻意返回 200 加空链接）。
    func fetchInviteLink() async -> String {
        guard enabled, let url = URL(string: baseUrl + "/client-config") else { return "" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await Self.directSession.data(for: req)
            guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let link = obj["inviteLink"] as? String else { return "" }
            let trimmed = link.trimmingCharacters(in: .whitespaces)
            saveInviteCache(trimmed)
            return trimmed
        } catch {
            return ""
        }
    }

    // MARK: - HTTP（强制直连，不走系统代理）

    /// 直连不走系统代理：校验此刻多半发生在隧道未起/被吊销还原的过程中，
    /// 而且授权校验走代理等于让「能不能用」取决于「能不能上网」，会把两种
    /// 故障混成一个现象。
    private static let directSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // 空字典 = 不走系统代理，直连
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    /// 服务端的 4xx 是应用层答复（unknown_device / invalid_code / already_active…），
    /// 不是传输失败——照常解码交给调用方按 status 分流。只有解析不出 JSON 的
    /// 响应（代理劫持页、网关错误页）才当「连不上」。
    private func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: baseUrl + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await Self.directSession.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            lastStatusCode = status
            netErrorHint = nil
            guard let decoded = try? JSONSerialization.jsonObject(with: data) else {
                authLog("\(path) 响应不是有效 JSON（代理劫持页/网关错误页？），按连不上处理")
                return nil
            }
            if (400..<500).contains(status), let dict = decoded as? [String: Any] {
                return dict
            }
            if !(200..<300).contains(status) {
                let head = String(data: data.prefix(200), encoding: .utf8) ?? ""
                authLog("\(path) 收到异常 HTTP \(status)（应为 2xx/4xx 应用层答复），响应开头：\(head)")
                return nil
            }
            return decoded as? [String: Any]
        } catch {
            lastStatusCode = 0
            let hint = Self.describeNetError(error)
            netErrorHint = hint
            authLog("\(path) 请求失败：\(hint ?? "未分类网络错误（\(Self.shortError(error))）")")
            return nil
        }
    }

    /// 把传输层错误翻成一句人话，供状态行直接显示。分类只看错误文案关键词，
    /// 匹配不中返回 nil（状态行退回笼统话）。
    static func describeNetError(_ error: Error) -> String? {
        let ns = error as NSError
        var text = ns.localizedDescription.lowercased()
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " " + underlying.localizedDescription.lowercased()
        }
        // TLS 先判：证书问题在这套栈里也会落成「安全连接失败」，若先撞上
        // 下面那些关键词就会被误报成普通网络故障
        if text.contains("certificate") || text.contains("ssl") || text.contains("tls")
            || text.contains("secure connection") || text.contains("证书") {
            if text.contains("certificate") || text.contains("证书") {
                return "TLS 证书校验失败"
            }
            return "TLS 握手失败"
        }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "连接超时"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "域名解析失败"
            case NSURLErrorCannotConnectToHost: return "连接被拒绝"
            case NSURLErrorNetworkConnectionLost: return "连接被重置"
            case NSURLErrorNotConnectedToInternet: return "网络不可达"
            case NSURLErrorCannotLoadFromNetwork: return "连接被中断"
            default: break
            }
        }
        if text.contains("timed out") || text.contains("timeout") || text.contains("超时") { return "连接超时" }
        if text.contains("refused") || text.contains("拒绝") { return "连接被拒绝" }
        if text.contains("failed host lookup") || text.contains("dns") || text.contains("解析") { return "域名解析失败" }
        if text.contains("no route") || text.contains("unreachable") || text.contains("network is down")
            || text.contains("不可达") { return "网络不可达" }
        if text.contains("reset") { return "连接被重置" }
        return nil
    }

    /// 未分类错误的简短摘要（只进日志，单行，不把多行英文栈砸进日志）。
    private static func shortError(_ error: Error) -> String {
        let raw = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        return raw.count > 120 ? String(raw.prefix(120)) + "…" : raw
    }

    // MARK: - 本地状态

    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchOS/license.json")
    }

    private func loadLocal() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            authLog("读取本地授权记录：文件不存在，本机为首次启动（从未激活过）")
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                authLog("读取本地授权记录：内容不是有效对象，将按未激活处理")
                return
            }
            code = obj["code"] as? String ?? ""
            if let at = obj["lastVerifiedAt"] as? String {
                lastVerifiedAt = Self.parseServerDate(at)
            }
            authLog(code.isEmpty
                ? "读取本地授权记录：未保存激活码（激活未完成或已被要求换码）"
                : "读取本地授权记录：本机保存的激活码末四位 …\(code.suffix(4))"
                    + (lastVerifiedAt == nil ? "，且没有成功校验记录" : "，上次成功校验 \(Self.ago(lastVerifiedAt!))"))
        } catch {
            // 本地状态损坏不是致命错误：最坏情况退回「未激活」，重新走流程。
            authLog("读取本地授权记录失败（\(error.localizedDescription)），按未激活处理")
        }
    }

    private func saveLocal() {
        let obj: [String: Any] = [
            "deviceCode": deviceCode,
            "code": code,
            "lastVerifiedAt": lastVerifiedAt.map { Self.isoString($0) } ?? "",
        ]
        do {
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: storeURL.path)
        } catch {
            authLog("写入本地授权记录失败（\(error.localizedDescription)）：本次校验结论无法留到下次启动，不影响本次放行判定")
        }
    }

    // MARK: - 推送通道装配

    private func makePush() -> LicensePush {
        let p = LicensePush()
        p.baseURLProvider = { [weak self] in self?.baseUrl ?? "" }
        p.onEventLog = { [weak self] in self?.authLog($0) }
        p.onResync = { [weak self] in
            guard let self else { return }
            // 打标记放在收到的那一刻而不是校验分支里：verify 有在途合并，
            // resync 撞上在途请求时会直接复用那个结果，标记挂在分支里这次
            // 询问就没有「刚被 resync 催过」的上下文，确认复核会被跳过。
            self.resyncSeenAt = Date()
            self.verify(force: true, source: "resync推送")
        }
        p.onLivenessChanged = { [weak self] in self?.syncActivePoll() }
        p.onCatchup = { [weak self] in
            self?.verify(source: "重连补课")
        }
        return p
    }

    // MARK: - 工具

    /// 网络操作串行链：前一趟没落地，后一趟不出发。
    private func chained<T>(_ op: @escaping () async -> T) -> Task<T, Never> {
        let prev = netChain
        let task = Task<T, Never> {
            await prev.value
            return await op()
        }
        netChain = Task { _ = await task.value }
        return task
    }

    /// Timer 便捷封装：block 回到 MainActor（scheduledTimer 的 block 不是
    /// @MainActor，但从主线程调度时 assumeIsolated 是安全的）。
    @discardableResult
    private func scheduledTimer(_ interval: TimeInterval, repeats: Bool = false,
                                _ handler: @escaping @MainActor () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    // MARK: - 静态工具（文案/解析，与 Windows 端逐字对齐）

    /// 一次校验/激活请求的落点说明：路径 + HTTP 码 + 服务端答复的 status。
    static func httpNote(_ path: String, _ statusCode: Int, _ status: String?) -> String {
        let note: String
        switch status {
        case "active": note = "校验通过，授权有效"
        case "pending": note = "激活码已签发，等待客户端填入领取"
        case "revoked": note = "授权已被管理员吊销"
        case "code_mismatch": note = "客户端持有的激活码与服务端记录不一致（管理端换过码），旧码作废"
        case "banned": note = "该账号已被管理员封禁，名下设备全部停用"
        case "unknown_device": note = "服务端不认识这台设备，尚未登记发码"
        case "bad_request": note = "请求内容不合规"
        case "rate_limited": note = "请求过于频繁被限流（服务端要求稍后再问）"
        case "ok": note = "请求已受理"
        case nil: note = "服务端未给出状态"
        case let other?: note = "服务端返回「\(other)」"
        }
        return "\(path) 往返完成（HTTP \(statusCode)）：\(note)"
    }

    static func stageName(_ s: LicenseStage) -> String {
        switch s {
        case .revoked: return "已吊销"
        case .banned: return "已封禁"
        case .unregistered: return "未登记/码已更换"
        case .codeIssued: return "码已签发未领取"
        default: return "\(s)"
        }
    }

    /// 大致多久之前。只用于给人看，不参与任何判定。
    static func ago(_ t: Date) -> String {
        let d = Date().timeIntervalSince(t)
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        return "\(Int(d / 86400)) 天前"
    }

    /// 服务端时间戳解析（ISO8601，可能带毫秒）。
    private static let isoNoFrac: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions.insert(.withFractionalSeconds)
        return f
    }()

    static func parseServerDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return Self.isoFrac.date(from: s) ?? Self.isoNoFrac.date(from: s)
    }

    static func isoString(_ d: Date) -> String {
        Self.isoNoFrac.string(from: d)
    }
}
