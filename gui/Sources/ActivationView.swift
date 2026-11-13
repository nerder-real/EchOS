// 激活窗口：未激活 / 被吊销 / 校验过期时挡住主界面，让用户在这里把授权走完。
//
// 布局与交互逐块还原 Win 端 activation_page.dart：
//   外层「客户端授权」大卡（错误分类时红色基调：感叹号盾 + 红边框）
//   ├─ 卡片一「💭 注册激活步骤」：四步说明（蓝色序号圆）+ 设备码卡片（复制）
//   │   + 激活码卡片（粘贴）+ 结果提示行 + [点我去 TG 群] [激活]
//   └─ 卡片二「状态与网络」：动作独占的状态显示区（永远一行）+ [检查网络] [重新校验]
//
// 与 Win 同款的交互口径：
//   · 复制成功 → 按钮变绿「已复制」，2 秒还原；
//   · 激活按钮只有两态：蓝「激活」（失败后保持可重试，失败原因由提示行
//     报告——按钮变成「激活失败」的话，提示行「点『激活』提交」指的按钮
//     就不在页面上了）/ 绿「已激活」；改动输入立即复原；
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

    // 主题色（与 Win EchTheme 同源）
    private var accentBlue: Color { Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255) }
    private var accentGreen: Color { Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255) }
    private var accentRed: Color { Color(red: 255 / 255, green: 59 / 255, blue: 48 / 255) }
    private var sectionFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : accentBlue.opacity(0.08)
    }
    private var sectionStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : accentBlue.opacity(0.16)
    }
    private var cardFill: Color { colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55) }
    private var cardStroke: Color { colorScheme == .dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.1) }

    var body: some View {
        // 页面内容与高度固定，**不允许出现滚动**：纯静态布局，外层大卡在
        // 窗口内垂直居中。
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            outerCard
                .frame(maxWidth: 560)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // 状态行还挂着「连接失败」而网络其实已恢复（快速重试链拿到了新
        // 结论，但硬拦档位没变、没有 stage 变化事件）——事件到来时把快照
        // 对齐回真实档位，不让断网时的那句话一直盖着真实结论。
        if authHeadline.hasPrefix("授权服务器连接失败") && !license.netDown {
            authHeadline = headline(license.stage)
            authToneRed = isBadStage(license.stage)
        }
        // 页面打开时断网、邀请链接还是空的：网络恢复的事件到来时补取一次
        if !license.netDown && inviteLink.isEmpty {
            Task { await loadInviteLink() }
        }
    }

    /// 「点我去 TG 群」链接：进页面先亮缓存，再向服务端取最新覆盖。
    /// 取不到不重试循环——network 恢复会通过 stage 事件触发补取；断网时按钮
    /// 照常显示（入口不因网络消失，没网时恰恰最需要它）。
    private func loadInviteLink() async {
        let link = await license.fetchInviteLink()
        if !link.isEmpty { inviteLink = link }
    }

    // MARK: 外层大卡

    /// 外层大卡的错误基调（感叹号 logo + 红边框 = Win 的 errored）：
    /// 激活/粘贴失败、重新校验得到否定结论，或当前就停在错误档位。
    /// 「检查网络」失败**不**参与——它只是探测，不是授权结论；把它算进来
    /// 会出现「网络红框但授权有效」的自相矛盾。
    private var errored: Bool {
        actErr || authErr || isBadStage(license.stage)
    }

    /// 真正的「被拦下」档位（Win _stageBad）：码已签发是流程中段不是故障，
    /// 所以不在此列——头部和边框保持蓝色。
    private func isBadStage(_ s: LicenseStage) -> Bool {
        switch s {
        case .unregistered, .revoked, .banned, .unreachable: return true
        default: return false
        }
    }

    private var outerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部：图标 + 标题（无关闭按钮——激活页唯一出路是激活成功）
            HStack(spacing: 8) {
                Image(systemName: errored ? "exclamationmark.shield" : "checkmark.shield")
                    .font(.system(size: 17))
                    .foregroundColor(errored ? accentRed : accentBlue)
                Text("客户端授权")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }

            sectionCard { registerSection }
            sectionCard { statusSection }
        }
        .padding(EdgeInsets(top: 20, leading: 18, bottom: 14, trailing: 18))
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(errored ? accentRed.opacity(0.4) : accentBlue.opacity(0.3), lineWidth: 1))
    }

    /// 内层分区卡（Win _sectionCard）：磨砂质感的蓝色淡染
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(EdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(sectionFill))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(sectionStroke, lineWidth: 1))
            .padding(.horizontal, 2)
    }

    // MARK: 卡片一：注册激活步骤

    private var registerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("💭 注册激活步骤")
                .font(.system(size: 15, weight: .semibold))

            stepLine(1, "复制本机<设备码>", "一机一码，注意保护个人隐私。")
            stepLine(2, "跳转 TG 授权群注册本机获取激活码",
                     "暂时仅签发TG用户，签发后状态会变成「激活码已签发」。")
            stepLine(3, "将<激活码>粘贴到「激活码」卡片，点击「激活」",
                     "激活码形如 ECHS-XXXX-XXXX-XXXX-XXXX，请妥善保管。")
            helpLine

            deviceCard
            if license.stage != .notConfigured {
                codeCard
                // 结果提示行：报告「刚才那次激活/粘贴怎么了」，离触发按钮最近
                if !tip.isEmpty {
                    Text(tip)
                        .font(.system(size: 11, weight: tipColor == .secondary ? .regular : .medium))
                        .foregroundColor(tipColor)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
                actionButtons
            } else if !inviteLink.isEmpty {
                GradientButton(title: "点我去 TG 群", enabled: !busy) {
                    openInvite()
                }
                if !tip.isEmpty {
                    Text(tip)
                        .font(.system(size: 11, weight: tipColor == .secondary ? .regular : .medium))
                        .foregroundColor(tipColor)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func stepLine(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accentBlue)
                .frame(width: 18, height: 18)
                .background(Circle().fill(accentBlue.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    /// 第 ④ 步：帮助与反馈（含仓库 Star 链接）
    private var helpLine: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("4")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accentBlue)
                .frame(width: 18, height: 18)
                .background(Circle().fill(accentBlue.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text("帮助与反馈")
                    .font(.system(size: 12.5, weight: .medium))
                Text("公益项目，避免传播与滥用设置了注册激活机制，如有问题请提交issue。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                HStack(spacing: 2) {
                    Text("开源不易，帮忙")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button {
                        if let url = URL(string: "https://github.com/nerder-real/EchOS") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text("点个Star⭐")
                            .font(.system(size: 11))
                            .foregroundColor(accentBlue)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    Text("吧~")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    // MARK: 设备码卡片 / 激活码卡片（同一个壳：小标签 + 内容 + 右侧动作按钮）

    private var deviceCard: some View {
        fieldCard(label: "设备码") {
            Text(license.deviceCode)
                .font(.system(size: 15, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                // 撑满整行：复制按钮落到行尾右对齐，与「粘贴」按钮同一布局，
                // 不挨着编码挤在中间
                .frame(maxWidth: .infinity, alignment: .leading)
        } action: {
            GradientButton(title: copied ? "已复制" : "复制",
                           gradient: copied
                               ? LinearGradient(colors: [accentGreen, accentGreen.opacity(0.85)],
                                                startPoint: .leading, endPoint: .trailing)
                               : nil,
                           filledWidth: 64,
                           enabled: !busy) {
                copyDeviceCode()
            }
        }
    }

    private var codeCard: some View {
        fieldCard(label: "激活码") {
            TextField("ECHS-XXXX-XXXX-XXXX-XXXX", text: $codeInput)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced))
                // 填入的码默认跟主题文字色，激活成功变蓝（Win _codeCard 同款；
                // 失败不变色——失败由提示行报告）
                .foregroundColor(activateResult == "ok" ? accentBlue : .primary)
                .disabled(busy)
                .onChange(of: codeInput) { _ in
                    // 改了码，上一次的激活结果就作废：按钮回到「激活」
                    if activateResult != nil { activateResult = nil }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        } action: {
            GradientButton(title: "粘贴", filledWidth: 64, enabled: !busy) {
                pasteCode()
            }
        }
    }

    /// 卡片壳（Win _card）：小标签 + 内容 + 右侧动作按钮
    private func fieldCard<Content: View, Action: View>(label: String,
                                                        @ViewBuilder content: () -> Content,
                                                        @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                content()
                action()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(cardStroke, lineWidth: 1))
    }

    /// 按钮行（Win 同款：两个独立按钮并排，跳转在前、主动作在后）。
    /// 「点我去 TG 群」描边样式（非主动作无背景高亮），链接取到即显示；
    /// DNS 污染修复后首次加载即可达，不再出现延迟弹出的布局跳动。
    private var actionButtons: some View {
        HStack(spacing: 10) {
            if !inviteLink.isEmpty {
                GradientButton(title: "点我去 TG 群", enabled: !busy) {
                    openInvite()
                }
            }
            // 空码也保持可点：点了由提示行报「请输入激活码」。
            // 按钮只有两态：蓝「激活」（默认与失败后——失败原因由提示行
            // 报告，按钮变红「激活失败」的话，提示行里「点『激活』提交」
            // 指的那个按钮就不在页面上了）/ 绿「已激活」；改动输入立即复原。
            GradientButton(title: activateResult == "ok" ? "已激活" : "激活",
                           gradient: activateResult == "ok"
                               ? LinearGradient(colors: [accentGreen, accentGreen.opacity(0.85)],
                                                startPoint: .leading, endPoint: .trailing)
                               : LinearGradient(colors: [accentBlue, accentBlue.opacity(0.85)],
                                                startPoint: .leading, endPoint: .trailing),
                           enabled: !busy) {
                Task { await activate() }
            }
        }
        .padding(.top, 4)
    }

    /// 提示行跟随结果分类：成功蓝（与激活按钮同一套指示）、失败红、默认灰
    private var tipColor: Color {
        if activateResult == "ok" { return accentBlue }
        if actErr { return accentRed }
        return .secondary
    }

    // MARK: 卡片二：状态与网络

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 状态显示区（动作独占）：**永远显示一行信息**——进行中显示
            // 执行内容，结束显示结论。文字按结论分类着色，没有任何状态允许空行。
            if actionLine == "net" {
                if busy && netResult == nil {
                    Text(busyLabel)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                } else if let net = netResult {
                    HStack(spacing: 6) {
                        Image(systemName: net.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(net.ok ? accentGreen : accentRed)
                        Text(net.ok ? "授权服务器连接成功" : "授权服务器连接失败")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(net.ok ? accentBlue : accentRed)
                        Text(net.detail)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.secondary.opacity(0.75))
                            .lineLimit(1)
                    }
                } else {
                    // 动作完成但结果丢失（本地开发包早退）：兜底显示执行内容
                    Text(busyLabel)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                }
            } else {
                // 读快照而不是实时 stage：「重新校验」的结论定格到下一次授权
                // 动作，后台定时复查改变 stage 不会实时冲掉这一行（动作独占）。
                // 进行时只属于授权/网络动作——点「激活」时这一行保持上一条结论，
                // 「激活」的进行时由提示行自己承担，两边各说各的。
                Text(statusBusy ? busyLabel : authHeadline)
                    .font(.system(size: 12.5, weight: statusBusy ? .regular : .medium))
                    .foregroundColor(statusBusy ? .secondary
                                     : (authToneRed ? accentRed : Color.secondary.opacity(0.85)))
            }

            // 状态按钮行：常驻。「检查网络」只在「授权不可达且本次还没测通」
            // 时红色强调——测通了网络就被证明没问题，红着只会自相矛盾。
            HStack(spacing: 10) {
                GradientButton(title: "检查网络",
                               gradient: (netResult == nil
                                          && license.stage == .unreachable)
                                   || netResult?.ok == false
                                   ? LinearGradient(colors: [accentRed, accentRed.opacity(0.85)],
                                                    startPoint: .leading, endPoint: .trailing)
                                   : nil,
                               enabled: !busy) {
                    Task { await checkNetwork() }
                }
                GradientButton(title: "重新校验", enabled: !busy) {
                    Task { await reverify() }
                }
            }
        }
    }

    /// 状态区的进行时只属于授权/网络动作：点「激活」时这一行不动。
    private var statusBusy: Bool { busy && busyAction != "activate" }

    /// 进行时文案与触发它的按钮语义对齐。
    private var busyLabel: String {
        busyAction == "net" ? "正在检查网络…" : "正在校验授权…"
    }

    // MARK: 动作

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
        let text = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            tip = "剪贴板里没有内容"
            actErr = true
            return
        }
        codeInput = text
        // 粘贴换了码，上一次的激活结果随之作废（与手动输入同一条规矩），
        // 不然按钮和输入框还停在「已激活」的旧结果上。
        activateResult = nil
        tip = "已粘贴，点「激活」提交"
        actErr = false
    }

    private func openInvite() {
        guard let url = URL(string: inviteLink) else {
            tip = "打开失败：链接无效"
            actErr = true
            return
        }
        // 与 Win openExternalUrl 同口径：打不开要在提示行说一句，
        // 不能让按钮点了毫无反应。
        if !NSWorkspace.shared.open(url) {
            tip = "打开失败：系统没有可处理该链接的应用"
            actErr = true
        }
    }

    private func activate() async {
        guard !busy else { return }
        busy = true
        busyAction = "activate"
        tip = "正在校验…"
        actErr = false
        activateResult = nil
        let r = await license.activate(codeInput)
        busy = false
        busyAction = nil
        // 激活失败也可能是因为连不上服务器：状态行已挂着那句「连接失败」
        // （刚按过重新校验）提示行就不再复述同一句；状态行还在说旧结论时
        // 由提示行自己报一次。失败原因归提示行（红色），按钮保持可重试。
        let statusShowsNetFail = authHeadline.hasPrefix("授权服务器连接失败")
        tip = (r.stage == .unreachable || (!r.ok && statusShowsNetFail)) ? "" : r.message
        actErr = !r.ok
        // 按钮只有两态（Win 用户口径）：成功 → 绿「已激活」；失败 → 保持
        // 蓝「激活」随时可重试——失败原因由提示行报告，若把按钮变成红色
        // 「激活失败」，提示行里「点『激活』提交」指的那个按钮就不在页面上了
        activateResult = (r.ok && r.stage == .active) ? "ok" : nil
        // 激活成功由根视图按 stage 自动切回主界面（对齐 Win：激活页没有
        // 返回键，唯一出路是激活成功）。事件万一没送达，600ms 后重发一次：
        // 对已切换的实例是无害的幂等通知，对卡在本页的实例是确定性的解药。
        if activateResult == "ok" {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            license.resync()
        }
    }

    /// 纯网络探测（**真实 HTTPS 请求**，替换早期的纯 TCP 握手）：TCP 能通
    /// 只说明「有东西在 443 应答」——本机过滤/代理工具（如 AdGuard 的
    /// HTTPS 过滤）会本地代答，出现「TCP 2ms 成功、TLS 实际被掐」的假象。
    /// 这里走完整 TLS + HTTP，任何 HTTP 应答（含 4xx）都算通，失败带回
    /// 错误原因。强制直连，不走系统代理。
    private func checkNetwork() async {
        guard !busy else { return }
        // 2 秒冷却：纯本机探测对服务端零负担，连点没有意义。冷却期内的
        // 重复点击直接忽略，按钮也不进「正在检查」假态。
        let now = Date()
        if let last = lastNetCheckAt, now.timeIntervalSince(last) < 2 { return }
        lastNetCheckAt = now
        busy = true
        busyAction = "net"
        netResult = nil
        actionLine = "net"
        let base = license.serverBaseURL
        guard !base.isEmpty else {
            // 本地开发包（没注入授权地址）：界面不留提示，状态区归位回授权线
            busy = false
            busyAction = nil
            actionLine = nil
            return
        }
        let (ok, ms, detail) = await httpsProbe(base: base, timeout: 6)
        busy = false
        busyAction = nil
        netResult = (ok, ms, detail)
        // 网络通了但邀请链接还空着：多半是打开页面那一次取链接抖动失败，
        // 补取一次，别让按钮凭空消失
        if ok && inviteLink.isEmpty {
            Task { await loadInviteLink() }
        }
    }

    private func httpsProbe(base: String, timeout: TimeInterval) async -> (Bool, Int, String) {
        guard let url = URL(string: base) else { return (false, 0, "地址无效") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // 直连，不走系统代理
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
        busy = true
        busyAction = "auth"
        // 独占制：点重新校验，整个状态区就只属于授权校验，上一次检查网络的
        // 结果一并清掉。
        netResult = nil
        actionLine = "auth"
        // 用户按钮：击穿 TTL
        let r = await license.verify(force: true, source: "用户手动").value
        busy = false
        busyAction = nil
        // 节流命中：这一按没有产生任何新信息，状态行维持原样——尤其不能
        // 按旧档位结论刷新回去，那会和真实失败的「连接失败」来回翻面。
        if r.throttled { return }
        authErr = !r.ok
        // 一按一条消息，且只占状态行一行（一行信息原则）：问出否定结论时
        // 报「连接失败」那句（带具体网络原因），否则按档位说话。
        if !r.ok && r.stage != .unreachable {
            authHeadline = license.netFailHeadline
            authToneRed = true
        } else {
            authHeadline = headline(license.stage)
            authToneRed = isBadStage(license.stage)
        }
    }

    /// 状态行的授权结论。**每个状态都必须有非空文案**——状态区在结构上只有
    /// 一行，留空就是一行空白（Win 用空格占位，Mac 直接给出能读的话）。
    private func headline(_ s: LicenseStage) -> String {
        switch s {
        case .unregistered:
            return "客户端暂「未授权」，请访问TG群获取激活码。"
        case .codeIssued:
            return "激活码「已签发」，请将激活码粘贴到输入框后，点击「激活」完成注册。"
        case .revoked:
            return "客户端授权「已吊销」，如有问题请联系管理员反馈。"
        case .banned:
            return "客户端授权「已被封禁」，如有问题请联系管理员反馈。"
        case .unreachable:
            // 带具体网络原因（service 侧对最近一次失败的分类），一行说完
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

// MARK: - 渐变/描边胶囊按钮（Win AppButton 同款形态：40pt 高、半宽、主动作在右）

struct GradientButton: View {
    let title: String
    var gradient: LinearGradient?
    /// 固定宽度（卡片右侧的小按钮用）；nil = 占满可用宽度
    var filledWidth: CGFloat?
    var height: CGFloat = 40
    var enabled = true
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(foreground)
                .frame(width: filledWidth, height: height)
                .frame(maxWidth: filledWidth == nil ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(gradient.map { AnyShapeStyle($0) }
                              ?? AnyShapeStyle(colorScheme == .dark
                                               ? Color.white.opacity(0.08)
                                               : Color.white.opacity(0.6))))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    private var foreground: Color {
        gradient != nil ? .white : .primary
    }

    private var borderColor: Color {
        gradient != nil ? .clear : Color.primary.opacity(0.15)
    }
}
