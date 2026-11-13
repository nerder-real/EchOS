import Foundation

/// 一个网络服务（Wi-Fi / Ethernet ...）上三类代理的原始状态
struct ProxyBackup: Codable {
    struct Entry: Codable {
        var enabled: Bool = false
        var server: String = ""
        var port: Int = 0
    }
    /// PAC 自动代理（v2rayN 等会用 .pac URL 而非具体端口，必须单独备份还原）
    struct PacEntry: Codable {
        var enabled: Bool = false
        var url: String = ""
    }
    var service: String
    var web: Entry = Entry()        // HTTP
    var secureWeb: Entry = Entry()  // HTTPS
    var socks: Entry = Entry()      // SOCKS
    var pac: PacEntry = PacEntry()  // 自动代理（PAC）
}

/// 用 networksetup 接管 / 还原 macOS 系统代理，替代 v2rayN 的「自动配置系统代理」。
///
/// 设计上把"还原"看得比"接管"更重要：备份在接管前写入 UserDefaults，
/// 即使 App 崩溃或被强杀，下次启动也能把用户原来的代理设置还原回去。
enum SystemProxy {
    private static let tool = "/usr/sbin/networksetup"
    private static let backupKey = "SystemProxyBackup"
    private static let activeKey = "SystemProxyActive"

    /// 当前是否处于"已接管"状态（跨进程持久，用于崩溃后自愈）
    static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    @discardableResult
    private static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: edata, encoding: .utf8) ?? ""
            let sout = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "SystemProxy", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "networksetup \(args.joined(separator: " ")) 失败: \(msg.isEmpty ? sout : msg)"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 所有已启用的网络服务（跳过名字前带 * 的禁用项）
    static func networkServices() throws -> [String] {
        let out = try run(["-listallnetworkservices"])
        return out.split(separator: "\n").dropFirst()   // 第一行是说明文字
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// 取默认路由所在的网络接口（如 en0）。查询只读，不需要权限。
    /// route 万一挂起（个别系统状态），5 秒后强制结束，调用方会退回全部服务，
    /// 不会把接管流程卡死 —— 之前教训：在后台/actor 上下文里挂起会让接管永久排队。
    private static func defaultRouteInterface() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if p.isRunning { p.terminate() }
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            if let range = line.range(of: "interface:") {
                return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 从 listnetworkserviceorder 解析出「设备(en0/en1) → 服务名」映射。
    private static func deviceToService() throws -> [String: String] {
        let text = (try? run(["-listnetworkserviceorder"])) ?? ""
        var map: [String: String] = [:]
        var lastService = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(") {
                lastService = line.components(separatedBy: ")").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
            } else if lastService.isEmpty == false,
                      line.contains("Hardware Port:"),
                      let devPart = line.split(separator: ",").last?
                          .trimmingCharacters(in: .whitespaces) {
                let dev = devPart.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty { map[dev] = lastService }
            }
        }
        return map
    }

    /// 当前真正在用的网络服务：默认路由所在接口对应的那一个。
    /// 只对它设置系统代理，跳过没连接/没在用的服务（又快、又不会给将来才
    /// 连上的接口留下旧代理设置）。解析不到时退回全部服务。
    static func activeNetworkServices() throws -> [String] {
        let all = try networkServices()
        // 解析不到默认路由 → 退回全部（保持原有兜底行为）。
        guard let iface = defaultRouteInterface() else { return all }

        // 默认路由在虚拟接口（utun/tap/ppp/ipsec…）= 有 VPN 在跑。
        // 此时再给系统代理动手既和 VPN 抢流量、又可能把 VPN 自己设的代理顶掉，
        // 保守起见返回空 → enable 视为「不可接管」，宁可不动也绝不去搅乱 VPN。
        let vpnPrefix = ["utun", "tap", "ppp", "ipsec", "ipsec0", "lo0"]
        if vpnPrefix.contains(where: iface.hasPrefix) {
            return []
        }

        // 正常：默认路由在物理接口（en0/en1...），只对那一个服务设置系统代理，
        // 跳过没连接、没在用的服务（又快、又不会给将来才连上的接口留下旧代理）。
        guard let map = try? deviceToService(),
              let svc = map[iface], !svc.isEmpty,
              all.contains(svc) else {
            return all
        }
        return [svc]
    }

    // MARK: - 自家残留清洗（2026-11-13 复盘新增）

    /// EchOS 内核历次用过的监听端口（含本次）。必须持久化：还原常常发生在
    /// **下一次进程启动**（崩溃/强杀后的自愈），那时内存里的 static 早已不存在。
    ///
    /// 存「集合」而不存「上一次那一对」，是因为单值会漏掉这条序列：
    /// 用 30000 接管 → 被强杀（系统代理留在 30000）→ 改端口用 31000 接管。
    /// 若只记 31000，30000 的污染就会被当成用户原值存进备份，再还原回去
    /// 仍是一个死端口 —— 正是今晚断网的那个病，换个数还会复发。
    ///
    /// 只认「回环地址 + 名单内端口」为自家遗留，名单外的端口一概不碰：
    /// 用户自己的 v2rayN 10808 / Clash 7890 不会被误判成 EchOS 残留。
    private static let ownPortsKey = "SystemProxyOwnPorts"
    /// 名单上限：端口改动是极低频操作，留一点余量足够，防 UserDefaults 无限增长。
    private static let ownPortsCap = 8

    /// 记录本次接管用的端口。必须在 readBackup() **之前**调用，
    /// 否则首次接管时名单为空，当前已经指向自己的值会被当成原值存档。
    private static func recordOwnPorts(socks: (host: String, port: Int)?,
                                       http: (host: String, port: Int)?) {
        let d = UserDefaults.standard
        var ports = d.array(forKey: ownPortsKey) as? [Int] ?? []
        for p in [socks?.port, http?.port].compactMap({ $0 }) where !ports.contains(p) {
            ports.append(p)
        }
        if ports.count > ownPortsCap {
            ports = Array(ports.suffix(ownPortsCap))
        }
        d.set(ports, forKey: ownPortsKey)
    }

    /// 还原完全成功（无任何告警）后清空名单：此刻系统代理已回到用户原值，
    /// 这些端口不再属于"可能在用的自家占用"。若有告警则保留，下一轮还原
    /// 还要靠它识别残留。
    private static func clearOwnPortsIfClean(_ warnings: [String]) {
        guard warnings.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: ownPortsKey)
    }

    private static func ownPorts() -> [Int] {
        UserDefaults.standard.array(forKey: ownPortsKey) as? [Int] ?? []
    }

    /// TUN 模式让位：把系统代理**清空**（全部关闭），而不是还原备份。
    ///
    /// TUN 在 IP 层接管全量流量的前提，是应用流量真的以直连方式发往网络栈。
    /// 若此刻系统代理还指向第三方代理（v2rayN 的 10808 等），浏览器流量会在
    /// 应用层被截走、根本不进 TUN——2026-11-13 21:45 实录：TUN 存活 77 秒只
    /// 拦到 3 条 TCP（全是系统推送），同期 461 条 DNS 证明劫持正常，浏览器的
    /// TCP 全部绕行；用户感知就是「TUN 开了网页打不开」。
    ///
    /// 之前「让位 = restore()」的写法等于把浏览器交还给备份里的第三方代理：
    /// 备份里的 10808 一还原，TUN 形同虚设。改为清空；备份原样保留，关 TUN
    /// 后 enable()（isActive 仍为 true 时不会重读备份）与最终 restore() 仍按
    /// 原始值处置。
    ///
    /// 若此刻没有备份（此前从未接管过），先备份当前值再清——否则清空会不可逆
    /// 地丢掉用户/第三方代理的原始设置。
    static func clearForTun() -> [String] {
        var warnings: [String] = []
        let hasBackup = UserDefaults.standard.data(forKey: backupKey) != nil
        if !hasBackup {
            do {
                let backup = try readBackup()
                if let data = try? JSONEncoder().encode(backup) {
                    UserDefaults.standard.set(data, forKey: backupKey)
                    UserDefaults.standard.synchronize()
                }
            } catch {
                warnings.append("TUN 让位前备份失败：\(error.localizedDescription)")
            }
        }
        // 备份从此受 isActive 保护：enable() 见「已接管 + 有备份」时不会重读
        // 覆盖（那是把清空态当原值的通路）；restore() 仍按备份原值还原。
        isActive = true
        let services: [String]
        do { services = try activeNetworkServices() } catch {
            return warnings + ["读取网络服务失败：\(error.localizedDescription)"]
        }
        for svc in services {
            for cmd in ["-setwebproxystate", "-setsecurewebproxystate",
                        "-setsocksfirewallproxystate", "-setautoproxystate"] {
                do { try run([cmd, svc, "off"]) } catch {
                    warnings.append("TUN 让位清空「\(svc)」失败：\(error.localizedDescription)")
                    break
                }
            }
        }
        // 读回验证：networksetup 可能「返回 0 却什么也没改」（enable 侧吃过
        // 这个亏）。清空没生效时浏览器流量会继续绕开 TUN——现象是「TUN 开了
        // 网页打不开」而日志一片正常（2026-11-14 00:04 实录：让位执行了、
        // 自检通过了、路由全对了，浏览器仍不通）。重试一次，仍失败必须留下
        // 醒目记录。
        if let svc = services.first, let residue = proxyResidue(svc) {
            warnings.append("清空后读回仍有残留：\(residue)，重试一次…")
            for cmd in ["-setwebproxystate", "-setsecurewebproxystate",
                        "-setsocksfirewallproxystate", "-setautoproxystate"] {
                try? run([cmd, svc, "off"])
            }
            if let residue2 = proxyResidue(svc) {
                warnings.append("重试后仍有残留：\(residue2)——浏览器可能仍绕开 TUN，请到「系统设置 → 网络 → 详细信息 → 代理」手动关闭")
            } else {
                warnings.append("重试后已清空")
            }
        }
        return warnings
    }

    /// 读回某网络服务的三类代理开关。全关返回 nil；有开的返回摘要（供日志）。
    private static func proxyResidue(_ svc: String) -> String? {
        let web = parseEntry((try? run(["-getwebproxy", svc])) ?? "")
        let sec = parseEntry((try? run(["-getsecurewebproxy", svc])) ?? "")
        let soc = parseEntry((try? run(["-getsocksfirewallproxy", svc])) ?? "")
        var parts: [String] = []
        if web.enabled { parts.append("HTTP \(web.server):\(web.port)") }
        if sec.enabled { parts.append("HTTPS \(sec.server):\(sec.port)") }
        if soc.enabled { parts.append("SOCKS \(soc.server):\(soc.port)") }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    /// 默认路由服务上是否仍开着任意代理（TUN 巡逻用）。返回（是否开启, 摘要）。
    static func anyProxyResidue() -> (Bool, String) {
        guard let svcs = try? activeNetworkServices(), let svc = svcs.first else { return (false, "") }
        if let desc = proxyResidue(svc) { return (true, desc) }
        return (false, "")
    }

    /// 备份/还原共用的"自家残留"清洗：指向回环地址 + 本机内核端口的代理
    /// 条目，是上一次异常退出留下的接管态，不是用户的原始配置。不清洗的话
    /// 接管会把污染态当"原值"存档，还原时如实还原回死端口 → 浏览器全断
    /// （2026-11-13 实录；与内核侧 DNS 遗留同构的病，解法也同构：存档时
    /// 识别为遗留，还原为「关闭」，历史污染随之自愈）。
    private static func washSelfLeftover(_ e: inout ProxyBackup.Entry) {
        let isLocalLoopback = ["127.0.0.1", "::1", "localhost"].contains(e.server.lowercased())
        guard e.enabled, isLocalLoopback, ownPorts().contains(e.port) else { return }
        e.enabled = false
        e.server = ""
        e.port = 0
    }

    private static func parseEntry(_ text: String) -> ProxyBackup.Entry {
        var e = ProxyBackup.Entry()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": e.enabled = (parts[1].lowercased() == "yes")
            case "Server":  e.server = parts[1]
            case "Port":    e.port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return e
    }

    private static func parsePac(_ text: String) -> ProxyBackup.PacEntry {
        var e = ProxyBackup.PacEntry()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": e.enabled = (parts[1].lowercased() == "yes")
            case "URL":     e.url = parts[1]
            default: break
            }
        }
        return e
    }

    static func readBackup() throws -> [ProxyBackup] {
        var result: [ProxyBackup] = []
        for svc in try activeNetworkServices() {
            var b = ProxyBackup(service: svc)
            b.web = parseEntry((try? run(["-getwebproxy", svc])) ?? "")
            b.secureWeb = parseEntry((try? run(["-getsecurewebproxy", svc])) ?? "")
            b.socks = parseEntry((try? run(["-getsocksfirewallproxy", svc])) ?? "")
            b.pac = parsePac((try? run(["-getautoproxyurl", svc])) ?? "")
            result.append(b)
        }
        return result
    }

    /// 接管系统代理。socks / http 任一为 nil 表示该类型不接管。
    /// 返回过程中的提示信息（例如某个网络服务设置失败）。
    static func enable(socks: (host: String, port: Int)?,
                       http: (host: String, port: Int)?) throws -> [String] {
        guard socks != nil || http != nil else {
            throw NSError(domain: "SystemProxy", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "监听地址里没有可用的 socks5/http 端口，无法接管系统代理"])
        }

        // 关键顺序：先记录本次要用的本机端口，再读备份/清洗。
        // 反过来的话，首次启用时清洗看到的是「上次」的端口（甚至 nil），
        // 而现在系统里躺着的正是本进程早先设进去的值 —— 一次都洗不掉。
        // 端口持久化在 UserDefaults，崩溃/强杀后的下次启动照样能识别。
        recordOwnPorts(socks: socks, http: http)

        // 只在尚未接管时备份，避免把我们自己设的值覆盖掉用户的原始设置。
        // 但如果标记说"已接管"而备份却不见了（配置被清过、换过机器），
        // 那就必须补一次备份，否则待会儿还原时无据可依。
        let hasBackup = UserDefaults.standard.data(forKey: backupKey) != nil
        if !isActive || !hasBackup {
            var backup = try readBackup()
            // 存档前先洗掉自家残留（见 washSelfLeftover 注释）。
            for i in backup.indices {
                washSelfLeftover(&backup[i].web)
                washSelfLeftover(&backup[i].secureWeb)
                washSelfLeftover(&backup[i].socks)
            }
            guard !backup.isEmpty else {
                throw NSError(domain: "SystemProxy", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "读不到当前网络设置，为安全起见没有接管系统代理"])
            }
            if let data = try? JSONEncoder().encode(backup) {
                UserDefaults.standard.set(data, forKey: backupKey)
                UserDefaults.standard.synchronize()
            }
        }

        var warnings: [String] = []
        let services = try activeNetworkServices()
        guard !services.isEmpty else {
            throw NSError(domain: "SystemProxy", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "没有可设置系统代理的网络服务（可能当前流量在 VPN/虚拟接口上，为不冲突已跳过接管）"])
        }

        for svc in services {
            do {
                if let s = socks {
                    try run(["-setsocksfirewallproxy", svc, s.host, String(s.port)])
                    try run(["-setsocksfirewallproxystate", svc, "on"])
                }
                if let h = http {
                    try run(["-setwebproxy", svc, h.host, String(h.port)])
                    try run(["-setwebproxystate", svc, "on"])
                    try run(["-setsecurewebproxy", svc, h.host, String(h.port)])
                    try run(["-setsecurewebproxystate", svc, "on"])
                }
                // 接管期间关闭 PAC 自动代理，避免它和 socks/http 抢浏览器流量
                // （v2rayN 的 PAC 在这里会被临时让位，还原时再恢复）。
                try run(["-setautoproxystate", svc, "off"])
            } catch {
                warnings.append("网络服务「\(svc)」设置失败：\(error.localizedDescription)")
            }
        }

        // 读回验证。networksetup 有可能返回成功却什么也没改（权限被拦、
        // 服务列表为空等），只信返回码的话，日志会报"已接管"而浏览器
        // 其实根本没走代理 —— 用户看到的就是"软件说好了但打不开网页"。
        let after = (try? readBackup()) ?? []
        let applied = after.contains { b in
            if let s = socks { return b.socks.enabled && b.socks.server == s.host && b.socks.port == s.port }
            if let h = http { return b.web.enabled && b.web.server == h.host && b.web.port == h.port }
            return false
        }
        guard applied else {
            isActive = false
            throw NSError(domain: "SystemProxy", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "系统代理设置没有生效（命令已执行但设置未改变）。请到「系统设置 → 网络 → 详细信息 → 代理」手动把 SOCKS 代理设为 \(socks.map { "\($0.host):\($0.port)" } ?? "本地端口")"])
        }

        isActive = true
        return warnings
    }

    /// 还原到接管之前的状态。
    ///
    /// 关键：没有备份时**什么都不做**。早先这里会退化成"把所有代理关掉"，
    /// 结果在标记与备份不一致的情况下（比如标记还在、备份已丢），
    /// 直接把用户自己配的代理给关了 —— 用户的感受就是莫名其妙断网。
    /// 宁可留着不动，也不能拿用户的网络设置去赌。
    @discardableResult
    static func restore() -> [String] {
        var warnings: [String] = []
        guard let data = UserDefaults.standard.data(forKey: backupKey),
              let backups = try? JSONDecoder().decode([ProxyBackup].self, from: data),
              !backups.isEmpty else {
            isActive = false
            return ["没有找到接管前的备份，为避免误改，本次没有改动任何系统代理设置。"]
        }

        for bi in backups.indices {
            var b = backups[bi]
            // 还原前再洗一遍自家残留：旧版本（无清洗逻辑时期）存下的污染
            // 备份里可能已经有指向内核端口的"原值"，只靠存档侧清洗防不住
            // 历史污染（2026-11-13 实录：还原回死端口 30001，浏览器全断）。
            washSelfLeftover(&b.socks)
            washSelfLeftover(&b.web)
            washSelfLeftover(&b.secureWeb)
            func apply(_ e: ProxyBackup.Entry, set: String, state: String) {
                do {
                    // 地址必须无条件写回：哪怕这项原本是关着的，也不能把我们的
                    // 30000/30001 留在里面 —— 否则用户哪天手动打开代理，
                    // 连的是一个早就没人监听的端口，排查起来毫无头绪。
                    if !e.server.isEmpty && e.port > 0 {
                        try run([set, b.service, e.server, String(e.port)])
                    }
                    // networksetup 设置地址时会顺手把开关打开，所以状态要放在后面收尾。
                    try run([state, b.service, e.enabled ? "on" : "off"])
                } catch {
                    warnings.append("还原「\(b.service)」失败：\(error.localizedDescription)")
                }
            }
            apply(b.socks, set: "-setsocksfirewallproxy", state: "-setsocksfirewallproxystate")
            apply(b.web, set: "-setwebproxy", state: "-setwebproxystate")
            apply(b.secureWeb, set: "-setsecurewebproxy", state: "-setsecurewebproxystate")

            // PAC 自动代理单独处理：只有 URL 和开关两样东西。
            do {
                if !b.pac.url.isEmpty {
                    try run(["-setautoproxyurl", b.service, b.pac.url])
                }
                try run(["-setautoproxystate", b.service, b.pac.enabled ? "on" : "off"])
            } catch {
                warnings.append("还原「\(b.service)」自动代理失败：\(error.localizedDescription)")
            }
        }
        isActive = false
        // 干净还原（无告警）后清空自家端口名单：此时系统代理已是用户原值，
        // 名单留着只会在下次接管时把用户真实的同端口配置误洗掉。
        clearOwnPortsIfClean(warnings)
        return warnings
    }

    /// 供界面展示：当前系统 SOCKS 代理指向哪里
    static func currentSummary() -> String {
        guard let svcs = try? activeNetworkServices(), let first = svcs.first else { return "未知" }
        let socks = parseEntry((try? run(["-getsocksfirewallproxy", first])) ?? "")
        let web = parseEntry((try? run(["-getwebproxy", first])) ?? "")
        var parts: [String] = []
        if socks.enabled { parts.append("SOCKS \(socks.server):\(socks.port)") }
        if web.enabled { parts.append("HTTP \(web.server):\(web.port)") }
        return parts.isEmpty ? "未启用" : parts.joined(separator: " / ")
    }

    /// 读回当前系统代理设置，判断是否仍指向预期端口（运行期巡逻用）。
    ///
    /// v2rayN/Clash 这类软件在启动或退出时会抢写/清除系统代理——2026-10-24
    /// 实锤案例：v2rayN 退出时执行它自己的"清除系统代理"，把本工具指向
    /// 30000/30001 的接管一并抹成直连；GUI 的"已接管"是内部标志，不读回
    /// 真实设置就永远不会知道，图标照蓝、页面照显示已接管，浏览器实际在
    /// 直连。socks 或 http 任意一类仍正确指向我们即视为完好。
    static func isTakenOver(socksExpect: (host: String, port: Int)?,
                            httpExpect: (host: String, port: Int)?) -> Bool {
        guard let svcs = try? activeNetworkServices(), let svc = svcs.first else {
            return true // 读不到网络服务（VPN 接管路由等）就不报警，交给下一轮巡逻
        }
        if let e = socksExpect {
            let cur = parseEntry((try? run(["-getsocksfirewallproxy", svc])) ?? "")
            if cur.enabled && cur.server == e.host && cur.port == e.port { return true }
        }
        if let e = httpExpect {
            let cur = parseEntry((try? run(["-getwebproxy", svc])) ?? "")
            if cur.enabled && cur.server == e.host && cur.port == e.port { return true }
        }
        return false
    }
}

/// 把 networksetup 的多次子进程调用串行化、丢到后台执行。
///
/// AppState（@MainActor）直接同步调 SystemProxy 时，接管/还原要一次跑几十个
/// 子进程（3 个网络服务 × 每服务 4~8 次），主线程被卡几秒 —— 用户看到的就是
/// 风火轮。actor 的 executor 天然串行，接管/还原不会交叉，也不会占主线程。
actor SystemProxyWorker {
    struct Endpoint: Sendable, Equatable {
        var host: String
        var port: Int
    }

    func enable(socks: Endpoint?, http: Endpoint?) throws -> [String] {
        try SystemProxy.enable(
            socks: socks.map { (host: $0.host, port: $0.port) },
            http: http.map { (host: $0.host, port: $0.port) })
    }

    func restore() -> [String] {
        SystemProxy.restore()
    }

    /// TUN 让位专用：清空系统代理（备份保留）。见 SystemProxy.clearForTun。
    func clearForTun() -> [String] {
        SystemProxy.clearForTun()
    }

    /// TUN 巡逻用：默认路由服务上是否仍开着任意代理。见 SystemProxy.anyProxyResidue。
    func anyProxyResidue() -> (Bool, String) {
        SystemProxy.anyProxyResidue()
    }

    func summary() -> String {
        SystemProxy.currentSummary()
    }

    /// 巡逻读回：与 enable/restore 走同一个 actor 串行，避免读写交错。
    func isTakenOver(socks: Endpoint?, http: Endpoint?) -> Bool {
        SystemProxy.isTakenOver(
            socksExpect: socks.map { (host: $0.host, port: $0.port) },
            httpExpect: http.map { (host: $0.host, port: $0.port) })
    }
}
