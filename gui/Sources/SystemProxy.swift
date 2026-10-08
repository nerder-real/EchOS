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

        // 只在尚未接管时备份，避免把我们自己设的值覆盖掉用户的原始设置。
        // 但如果标记说"已接管"而备份却不见了（配置被清过、换过机器），
        // 那就必须补一次备份，否则待会儿还原时无据可依。
        let hasBackup = UserDefaults.standard.data(forKey: backupKey) != nil
        if !isActive || !hasBackup {
            let backup = try readBackup()
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

        for b in backups {
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

    func summary() -> String {
        SystemProxy.currentSummary()
    }
}
