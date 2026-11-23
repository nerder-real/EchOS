// 激活窗口：未激活 / 被吊销 / 校验过期时挡住主界面，让用户在这里把授权走完。
//
// 2026-11-23 视觉重构（保持交互口径不变）：
//   去掉整圈粗红框 + 30fps 流光，改为「顶部渐变高光条 + 状态胶囊」。
//   外层「客户端授权」大卡（GeometryReader 撑满窗口，段间弹性均分）
//   ├─ 头部：图标底板 + 标题 + 状态胶囊（错误态红色落在这里）
//   ├─ 💭 注册激活步骤：四步（序号圆与凭证标签同为淡蓝底蓝字）
//   ├─ 卡片一 凭证区：设备码 / 激活码各一行，标签块+码值块+按钮块三段带底色
//   └─ 卡片二 操作区：一行共享信息 + 四个带彩色符号按钮（点我去TG群 / 点击激活
//      / 检查网络 / 重新校验）
//   所有信息文案只占单行；4 步说明与信息行均 lineLimit(1)。
//
// 与 Win 同款的交互口径（本次一律不改）：
//   · 复制成功 → 按钮变绿「已复制」，2 秒还原；
//   · 激活按钮只有两态：蓝「激活」（失败后保持可重试，失败原因由提示行
//     报告）/ 绿「已激活」；改动输入立即复原；
//   · 「检查网络」是纯网络探测（真实 HTTPS 请求 + 延迟），**不触发授权
//     校验**；「重新校验」才是授权动作。状态区动作独占：点哪个按钮，
//     整个区就只显示那个按钮的结果，上一个动作的结论不残留；
//   · 页面不显示授权服务器地址、不显示设备码来源 —— 排查信息只在授权日志。
//   · 只有本地开发包（notConfigured）才藏激活码输入框；已吊销保留输入框：
//     管理员「恢复」后原码再点一次「激活」就能救回来。

import SwiftUI
import Network

// MARK: - 授权状态 chip（主界面操作行常驻，逐字对齐 Win home_page _LicenseChip）

extension LicenseService {
    /// 图标始终在场：有效=verified_user（对勾盾），其余=gpp_maybe（问号盾）。
    /// unreachable 也算有效——能出现在主界面的断网必然是「曾经可用」的会话
    /// （启动即断网且从未可用的机器整页在激活页，轮不到这枚角标说话）。
    var chipIcon: String {
        stage == .active || stage == .unreachable ? "checkmark.shield" : "exclamationmark.shield"
    }

    var chipText: String {
        switch stage {
        case .active: return "授权有效"
        case .notConfigured: return "未配置授权"
        // 措辞刻意是「校验已停用」而不是「授权有效」：此刻能进主界面，
        // 但这台机器未必激活过，别让人以为这份授权是自己的。
        case .enforcementOff: return "校验已停用"
        // 会话中断网按上一份有效结论展示：拦新不杀旧的口径下隧道照跑、
        // 会话照旧，这枚「凭证位」也维持有效（用户口径：这里只报有效/
        // 成功，不翻红）——故障真相走授权日志。
        case .unreachable: return "授权有效"
        case .revoked: return "授权已吊销"
        case .banned: return "授权已封禁"
        case .unregistered, .codeIssued: return "尚未激活"
        case .unknown: return "正在校验授权"
        }
    }

    /// 「授权有效」不是绿色——它是正常态，用次要文字色；只有真正被拦的
    /// 状态才红。unreachable 与「校验已停用」「未配置」同为灰：前者不是
    /// 故障（会话还在跑），后两者不是「被拦」。
    var chipColor: Color {
        switch stage {
        case .active, .unreachable, .notConfigured, .enforcementOff: return .secondary
        default: return .red
        }
    }
}

// MARK: - 激活窗口

struct ActivationView: View {
    @ObservedObject private var license = LicenseService.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var codeInput = ""
    @State private var tip = ""
    /// 提示行的红字位：只由激活 / 粘贴 / 剪贴板 / 跳转的失败置位，
    /// 「重新校验」的结果不碰它。
    @State private var actErr = false
    /// 授权状态行的红字位：只由「重新校验」的结果置位，激活的成败不碰它。
    @State private var authErr = false
    @State private var busy = false
    /// 哪个动作在进行：nil / "activate" / "auth" / "net"。busy 是三者的总闸
    /// （互斥、进行中全部按钮禁用），但状态行的进行时文案只属于 auth/net——
    /// 「激活」的进行时显示在提示行。若共用一个进行时文案，点「激活」时状态行
    /// 会跟着转「正在校验授权…」，两个按钮看起来就联动了。
    @State private var busyAction: String?
    /// 激活按钮的结果态：nil = 正常「激活」；"ok" = 绿色「已激活」。
    /// 失败不进按钮（Win 用户口径）：失败原因走提示行，按钮保持可重试。
    @State private var activateResult: String?
    @State private var copied = false
    @State private var copiedTimer: Timer?
    /// 「点我去 TG 群」链接：先拿本地缓存顶（进页面即可见），再向服务端取最新。
    @State private var inviteLink = ""
    /// 状态显示区当前归属哪个按钮的输出：
    /// nil=初始快照（启动校验）/ "auth"=重新校验 / "net"=检查网络。
    @State private var actionLine: String?
    /// 状态行的授权结论快照：只在授权动作（启动/重新校验）结束时刷新，
    /// 其他动作（检查网络/激活）触发的重建沿用上一条——否则检查网络一点，
    /// 状态行就把实时 stage 的结论渲染出来，看起来像检查网络产出了授权提示。
    @State private var authHeadline = ""
    /// 状态行结论的分类红字位（快照，与 authHeadline 一同刷新）。
    @State private var authToneRed = false
    /// 「检查网络」结果（真实 HTTPS 请求：TLS + HTTP 全链路）。
    @State private var netResult: (ok: Bool, ms: Int, detail: String)?
    /// 「检查网络」最近一次点击时刻（2 秒冷却：纯本机探测，连点没有意义）。
    @State private var lastNetCheckAt: Date?
    /// 统一信息行显示谁的结果："act"=激活/粘贴/跳转 / "auth"=校验 / "net"=网络。
    /// 四个按钮共用一行信息，靠它决定这行归哪个动作（动作独占，不残留）。
    @State private var infoSource = "auth"

    // 主题色（与 Win EchTheme 同源）
    private var accentBlue: Color { Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255) }
    private var accentGreen: Color { Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255) }
    private var accentRed: Color { Color(red: 255 / 255, green: 59 / 255, blue: 48 / 255) }

    private var cardFill: Color { colorScheme == .dark ? Color.white.opacity(0.035) : Color.white }
    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.08)
    }
    private var innerFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.primary.opacity(0.035)
    }
    private var innerStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.07)
    }

    var body: some View {
        // 按窗口实际可用空间布局：GeometryReader 把父视图的确切尺寸传进来，
        // 外层卡片在宽/高两个方向都撑满可用区（不再用固定自然高度 + 顶部对齐，
        // 那会在窗口拉大时留一大片空白、窗口变窄时溢出）。卡片内部用带最小
        // 间距的弹性 Spacer 分配富余：空间多时各段均匀拉开，空间不足时塌到
        // 最小间距保持紧凑，始终贴合窗口比例。
        GeometryReader { geo in
            outerCard
                .padding(20)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                codeInput = license.savedCode
                authHeadline = headline(license.stage)
                authToneRed = isBadStage(license.stage)
                actErr = false
                authErr = false
                // 本地缓存先顶上：进页面即可见按钮，不等一趟网络
                inviteLink = license.cachedInviteLink
                Task { await loadInviteLink() }
            }
            .onReceive(license.$stage.removeDuplicates()) { _ in
                alignSnapshotAfterRecovery()
            }
            .onReceive(license.resyncSubject) { _ in
                // 「断网→恢复」的跳变：stage 可能没变（吊销/封禁被保留），
                // 靠这条独立通知把状态行那快照对齐回真实档位。
                alignSnapshotAfterRecovery()
            }
    }

    /// 断网期间状态行挂着「连接失败」，网络其实已恢复时把它对齐回真实档位。
    private func alignSnapshotAfterRecovery() {
        if authHeadline.hasPrefix("授权服务器连接失败") && !license.netDown {
            authHeadline = headline(license.stage)
            authToneRed = isBadStage(license.stage)
        }
        if !license.netDown && inviteLink.isEmpty {
            Task { await loadInviteLink() }
        }
    }

    /// 「点我去 TG 群」链接：进页面先亮缓存，再向服务端取最新覆盖。
    private func loadInviteLink() async {
        let link = await license.fetchInviteLink()
        if !link.isEmpty { inviteLink = link }
    }

    // MARK: - 状态判定

    /// 外层大卡的错误基调（顶部高光条 + 头部胶囊）：
    /// 激活/粘贴失败、重新校验得到否定结论，或当前就停在错误档位。
    /// 「检查网络」失败**不**参与——它只是探测，不是授权结论；把它算进来
    /// 会出现「网络红框但授权有效」的自相矛盾。
    private var errored: Bool {
        actErr || authErr || isBadStage(license.stage)
    }

    /// 真正的「被拦下」档位（Win _stageBad）：码已签发是流程中段不是故障，
    /// 所以不在此列——头部胶囊保持蓝色。
    private func isBadStage(_ s: LicenseStage) -> Bool {
        switch s {
        // notConfigured 也按错误态红：用户口径——这台机器没走到激活，
        // 就是「还没授权」，不该显示成蓝色的正常态。
        case .unregistered, .revoked, .banned, .unreachable, .notConfigured: return true
        default: return false
        }
    }

    private var beamColor: Color { errored ? accentRed : accentBlue }

    // MARK: - 外层大卡

    private var outerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部渐变高光条：替代原来的整圈粗红框 + 流光。错误态红色、正常
            // 态蓝色，一条 2.5pt 的柔和高光足够定调，不抢内容焦点。
            topHighlight

            VStack(alignment: .leading, spacing: 0) {
                header

                // 富余空间在 4 个间隙弹性均分。关键：卡片一↔卡片二 与
                // 卡片二↔底部用同一种 sectionGap，两处距离永远一致（用户口径）。
                // frame 有确切高度（GeometryReader），spacer 不会把内容顶出窗口。
                sectionGap

                VStack(alignment: .leading, spacing: 18) {
                    stepTitle
                    stepsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(innerFill))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(innerStroke, lineWidth: 1))

                sectionGap

                credentialSection

                sectionGap

                // 四个按钮 + 一行共享信息：一个整体卡片，不再有上下两处重合
                // 提示行，也不需要额外横线分隔。
                actionPanel

                // 底部同样留一个 gap，与卡片一↔卡片二的间距对称
                sectionGap
            }
            .padding(EdgeInsets(top: 20, leading: 22, bottom: 0, trailing: 22))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(errored
                        ? accentRed.opacity(colorScheme == .dark ? 0.32 : 0.28)
                        : cardStroke,
                        lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    /// 段间弹性间距：空间富余时均分拉开，窗口小时塌到最小间距。
    private var sectionGap: some View {
        Spacer(minLength: 14)
    }

    private var stepTitle: some View {
        Text("💭 注册激活步骤")
            .font(.system(size: 18, weight: .semibold))
    }

    private var topHighlight: some View {
        LinearGradient(
            colors: [beamColor.opacity(0), beamColor.opacity(0.85), beamColor.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 2.5)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [beamColor.opacity(0.95), beamColor.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: errored ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
            .shadow(color: beamColor.opacity(0.22), radius: 8, y: 2)

            Text("客户端授权")
                .font(.system(size: 20, weight: .semibold))

            Spacer(minLength: 8)

            Text(statusBadgeText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(statusBadgeColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(statusBadgeColor.opacity(colorScheme == .dark ? 0.16 : 0.11))
                )
        }
    }

    private var statusBadgeText: String {
        switch license.stage {
        case .active, .unreachable: return "授权有效"
        case .notConfigured: return "未配置授权"
        case .enforcementOff: return "校验停用"
        case .unregistered, .codeIssued: return "尚未激活"
        case .revoked: return "已吊销"
        case .banned: return "已封禁"
        case .unknown: return "校验中"
        }
    }

    private var statusBadgeColor: Color {
        switch license.stage {
        case .active: return accentGreen
        // 未配置 / 未授权 / 被拦，一律红色基调
        case .unreachable, .revoked, .banned, .unregistered, .notConfigured: return accentRed
        case .codeIssued: return accentBlue
        default: return .secondary
        }
    }

    // MARK: - 注册激活步骤（三步时间线）

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 26) {
            stepLine(1, "复制本机设备码", "一机一码，请妥善保管。")
            stepLine(2, "前往 TG 群注册本机，获取激活码",
                     "目前仅向 TG 用户签发，签发后状态变为「激活码已签发」。")
            stepLine(3, "粘贴激活码，点击激活按钮完成注册",
                     "激活码形如 ECHS-XXXX-XXXX-XXXX-XXXX。")
            helpStep
        }
    }

    private func stepLine(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(accentBlue)
                .frame(width: 24, height: 24)
                .background(Circle().fill(accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.12)))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 凭证卡：设备码 / 激活码（一个卡片上下两行，标题加粗加大）

    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldRow(label: "设备码") {
                Text(license.deviceCode)
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
            } action: {
                GradientButton(title: copied ? "已复制" : "复制",
                               gradient: copied
                                   ? LinearGradient(colors: [accentGreen, accentGreen.opacity(0.85)],
                                                    startPoint: .leading, endPoint: .trailing)
                                   : nil,
                               filledWidth: 64, height: 34,
                               enabled: !busy) {
                    copyDeviceCode()
                }
            }

            if license.stage != .notConfigured {
                Divider()

                fieldRow(label: "激活码") {
                    TextField("ECHS-XXXX-XXXX-XXXX-XXXX", text: $codeInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        // 填入的码默认跟主题文字色，激活成功变蓝（Win _codeCard 同款；
                        // 失败不变色——失败由提示行报告）
                        .foregroundColor(activateResult == "ok" ? accentBlue : .primary)
                        .disabled(busy)
                        .onChange(of: codeInput) { _ in
                            // 改了码，上一次的激活结果就作废：按钮回到「激活」
                            if activateResult != nil { activateResult = nil }
                        }
                } action: {
                    GradientButton(title: "粘贴", filledWidth: 64, height: 34, enabled: !busy) {
                        pasteCode()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(innerFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(innerStroke, lineWidth: 1))
    }

    /// 卡内一行：标签块 + 码值块 + 动作块，三段各自带底色，横向排成一行。
    /// 标签用蓝色淡底胶囊，码值用更深的输入底，动作交给按钮自己的背景。
    private func fieldRow<Content: View, Action: View>(label: String,
                                                       @ViewBuilder content: () -> Content,
                                                       @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(accentBlue)
                .padding(.horizontal, 13)
                .frame(height: 34, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10))
                )

            content()
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.07) : Color.primary.opacity(0.06),
                                lineWidth: 1)
                )

            action()
        }
    }

    // MARK: - 操作面板：四个按钮 + 一行共享信息

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 唯一的信息行：由 infoSource 决定显示哪个动作的结果，动作独占、
            // 不残留——彻底解决原版「上方 tip 行 + 下方状态行」两处信息重合。
            infoLineView

            // 四个按钮 2×2：主操作「激活 / 点我去 TG 群」在上，
            // 诊断操作「检查网络 / 重新校验」在下。
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if !inviteLink.isEmpty {
                        GradientButton(title: "点我去 TG 群", height: 40, enabled: !busy,
                                       tint: accentBlue, symbol: "paperplane.fill", symbolColor: accentBlue) {
                            openInvite()
                        }
                    }
                    // 空码也保持可点：点了由信息行报「请输入激活码」。
                    // 按钮只有两态：蓝「点击激活」（默认与失败后）/ 绿「已激活」；改动输入立即复原。
                    GradientButton(title: activateResult == "ok" ? "已激活" : "点击激活",
                                   gradient: activateResult == "ok"
                                       ? LinearGradient(colors: [accentGreen, accentGreen.opacity(0.85)],
                                                        startPoint: .leading, endPoint: .trailing)
                                       : LinearGradient(colors: [accentBlue, accentBlue.opacity(0.85)],
                                                        startPoint: .leading, endPoint: .trailing),
                                   height: 40,
                                   enabled: !busy,
                                   symbol: "key.fill", symbolColor: .white) {
                        Task { await activate() }
                    }
                }
                HStack(spacing: 10) {
                    // 「检查网络」只在「授权不可达且本次还没测通」时红色强调——
                    // 测通了网络就被证明没问题，红着只会自相矛盾。
                    let netFailing = (netResult == nil && license.stage == .unreachable)
                        || netResult?.ok == false
                    GradientButton(title: "检查网络",
                                   gradient: netFailing
                                       ? LinearGradient(colors: [accentRed, accentRed.opacity(0.85)],
                                                        startPoint: .leading, endPoint: .trailing)
                                       : nil,
                                   height: 40,
                                   enabled: !busy,
                                   tint: netFailing ? nil : accentGreen,
                                   symbol: "wifi", symbolColor: netFailing ? .white : accentGreen) {
                        Task { await checkNetwork() }
                    }
                    GradientButton(title: "重新校验", height: 40, enabled: !busy,
                                   tint: accentBlue, symbol: "arrow.triangle.2.circlepath",
                                   symbolColor: accentBlue) {
                        Task { await reverify() }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(innerFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(innerStroke, lineWidth: 1))
    }

    /// 共享的信息行视图：永远显示一行——进行中转圈，结束按结论着色。
    /// 自带淡色底 + 上下留白，作为卡片二里的信息条，不再贴着按钮。
    private var infoLineView: some View {
        HStack(spacing: 9) {
            if infoLine.busy {
                ProgressView()
                    .scaleEffect(0.75)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: infoLine.icon)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(infoLine.text)
                .font(.system(size: 13, weight: infoLine.busy ? .regular : .medium))
                .foregroundColor(infoLine.tone)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(infoLine.tone.opacity(colorScheme == .dark ? 0.11 : 0.07))
        )
    }

    /// 唯一信息行的文案来源。动作独占口径与原实现一致：
    ///   · "act"   —— 激活/粘贴/跳转的结果（tip，成功蓝 / 失败红 / 默认灰）
    ///   · "net"   —— 检查网络结论（真实 HTTPS 探测，不是授权结论）
    ///   · "auth"  —— 重新校验/启动校验的授权结论快照（不被后台复查冲掉）
    private var infoLine: (icon: String, text: String, tone: Color, busy: Bool) {
        switch infoSource {
        case "act":
            if activateResult == "ok" {
                return ("checkmark.circle.fill", tip.isEmpty ? "已激活。" : tip, accentBlue, false)
            }
            if actErr {
                return ("exclamationmark.circle.fill", tip.isEmpty ? "操作失败。" : tip, accentRed, false)
            }
            if !tip.isEmpty {
                return ("info.circle", tip, .secondary, false)
            }
            return ("info.circle", "请粘贴激活码，点击激活按钮提交。", .secondary, false)

        case "net":
            if busy && netResult == nil {
                return ("hourglass", busyLabel, .secondary, true)
            } else if let net = netResult {
                let text = (net.ok ? "授权服务器连接成功" : "授权服务器连接失败")
                    + " · " + net.detail
                return (net.ok ? "checkmark.circle.fill" : "xmark.circle.fill",
                        text, net.ok ? accentGreen : accentRed, false)
            }

        default: // "auth"
            if busy {
                return ("hourglass", busyLabel, .secondary, true)
            }
            return (authToneRed ? "exclamationmark.triangle.fill" : "checkmark.shield.fill",
                    authHeadline,
                    authToneRed ? accentRed : Color.secondary.opacity(0.85),
                    false)
        }
        // "net" 动作完成但结果丢失（本地开发包早退）的兜底
        return ("hourglass", busyLabel, .secondary, true)
    }

    /// 进行时文案与触发它的按钮语义对齐。
    private var busyLabel: String {
        busyAction == "net" ? "正在检查网络…" : (busyAction == "activate" ? "正在校验激活码…" : "正在校验授权…")
    }

    /// 第 4 步：帮助与反馈（与前三步同一形态；Star 是主链接，给足视觉重量）
    private var helpStep: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("4")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(accentBlue)
                .frame(width: 24, height: 24)
                .background(Circle().fill(accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text("帮助与反馈")
                    .font(.system(size: 14, weight: .medium))
                Text("公益项目，为防止滥用设有注册激活机制，如有问题请提交 issue。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    Text("开源不易，帮忙")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Button {
                        if let url = URL(string: "https://github.com/nerder-real/EchOS") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text("点个 Star ⭐")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(accentBlue)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    Text("吧~")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 动作

    private func copyDeviceCode() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(license.deviceCode, forType: .string)
        copied = true
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated { copied = false }
        }
    }

    /// 从剪贴板取激活码填进框里。不自动提交：粘进来的是不是本机的码只有
    /// 服务端知道，先让用户看一眼再决定要不要点「激活」。
    private func pasteCode() {
        infoSource = "act"
        let text = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            tip = "剪贴板里没有内容"
            actErr = true
            return
        }
        codeInput = text
        activateResult = nil
        tip = "已粘贴，点击激活按钮提交"
        actErr = false
    }

    private func openInvite() {
        infoSource = "act"
        guard let url = URL(string: inviteLink) else {
            tip = "打开失败：链接无效"
            actErr = true
            return
        }
        if !NSWorkspace.shared.open(url) {
            tip = "打开失败：系统没有可处理该链接的应用"
            actErr = true
        }
    }

    private func activate() async {
        guard !busy else { return }
        infoSource = "act"
        busy = true
        busyAction = "activate"
        tip = "正在校验…"
        actErr = false
        activateResult = nil
        let r = await license.activate(codeInput)
        busy = false
        busyAction = nil
        let statusShowsNetFail = authHeadline.hasPrefix("授权服务器连接失败")
        tip = (r.stage == .unreachable || (!r.ok && statusShowsNetFail)) ? "" : r.message
        actErr = !r.ok
        activateResult = (r.ok && r.stage == .active) ? "ok" : nil
        if activateResult == "ok" {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            license.resync()
        }
    }

    /// 纯网络探测（真实 HTTPS 请求：TCP 能通不代表 TLS/HTTP 能通）：
    /// 走完整 TLS + HTTP，任何 HTTP 应答（含 4xx）都算通，失败带回错误原因。
    /// 强制直连，不走系统代理。
    private func checkNetwork() async {
        guard !busy else { return }
        let now = Date()
        if let last = lastNetCheckAt, now.timeIntervalSince(last) < 2 { return }
        lastNetCheckAt = now
        infoSource = "net"
        busy = true
        busyAction = "net"
        netResult = nil
        actionLine = "net"
        let base = license.serverBaseURL
        guard !base.isEmpty else {
            // 本地开发包（没注入授权地址）：界面不留提示，信息行归位回授权线
            busy = false
            busyAction = nil
            actionLine = nil
            infoSource = "auth"
            return
        }
        let (ok, ms, detail) = await httpsProbe(base: base, timeout: 6)
        busy = false
        busyAction = nil
        netResult = (ok, ms, detail)
        if ok && inviteLink.isEmpty {
            Task { await loadInviteLink() }
        }
    }

    private func httpsProbe(base: String, timeout: TimeInterval) async -> (Bool, Int, String) {
        guard let url = URL(string: base) else { return (false, 0, "地址无效") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let start = Date()
        do {
            let _ = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return (true, ms, "网络延迟 \(ms) ms")
        } catch {
            let hint = LicenseService.describeNetError(error) ?? "网络异常，请检查本机网络"
            if hint == "网络异常，请检查本机网络" {
                license.logAuth("检查网络失败：\(error.localizedDescription)")
            }
            return (false, 0, hint)
        }
    }

    private func reverify() async {
        guard !busy else { return }
        infoSource = "auth"
        busy = true
        busyAction = "auth"
        netResult = nil
        actionLine = "auth"
        let r = await license.verify(force: true, source: "用户手动").value
        busy = false
        busyAction = nil
        if r.throttled { return }
        authErr = !r.ok
        if !r.ok && r.stage != .unreachable {
            authHeadline = license.netFailHeadline
            authToneRed = true
        } else {
            authHeadline = headline(license.stage)
            authToneRed = isBadStage(license.stage)
        }
    }

    /// 状态行的授权结论。**每个状态都必须有非空文案**。
    private func headline(_ s: LicenseStage) -> String {
        switch s {
        case .unregistered:
            return "客户端暂「未授权」，请访问TG群获取激活码。"
        case .codeIssued:
            return "激活码已签发，请粘贴后点击激活按钮完成注册。"
        case .revoked:
            return "客户端授权「已吊销」，如有问题请联系管理员反馈。"
        case .banned:
            return "客户端授权「已被封禁」，如有问题请联系管理员反馈。"
        case .unreachable:
            return license.netFailHeadline
        case .unknown:
            return "正在校验授权…"
        case .notConfigured:
            return "未配置授权服务器（本地开发包）。"
        case .enforcementOff:
            return "校验已停用：服务端当前不校验授权。"
        case .active:
            return "授权有效。"
        }
    }
}

// MARK: - 渐变/描边胶囊按钮（Win AppButton 同款形态：主按钮 42pt、小按钮 30/34pt）

struct GradientButton: View {
    let title: String
    var gradient: LinearGradient?
    /// 固定宽度（卡片右侧的小按钮用）；nil = 占满可用宽度
    var filledWidth: CGFloat?
    var height: CGFloat = 40
    var enabled = true
    /// 描边按钮的着色（文字 + 边框 + 淡底），用于次主操作的分级
    var tint: Color?
    /// 按钮文字前的符号（SF Symbol 名），给每个按钮一个彩色标识
    var symbol: String?
    var symbolColor: Color?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(symbolColor ?? foreground)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(foreground)
            }
            .frame(width: filledWidth, height: height)
            .frame(maxWidth: filledWidth == nil ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(gradient.map { AnyShapeStyle($0) }
                          ?? AnyShapeStyle(fillColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(borderColor, lineWidth: tint != nil ? 1.2 : 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    private var foreground: Color {
        if gradient != nil { return .white }
        if let tint { return tint }
        return .primary
    }

    private var fillColor: Color {
        if let tint { return tint.opacity(colorScheme == .dark ? 0.14 : 0.08) }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045)
    }

    private var borderColor: Color {
        if gradient != nil { return .clear }
        if let tint { return tint.opacity(colorScheme == .dark ? 0.55 : 0.45) }
        return Color.primary.opacity(0.12)
    }
}
