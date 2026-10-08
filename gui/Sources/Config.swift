import Foundation

/// 日志详细程度
enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case off, error, warning, info
    /// 只看自检结论。它不是"更详细/更简略"的一档，而是换了个数据源 ——
    /// 放进同一个下拉是因为用户要的就是"日志区现在给我看什么"。
    case checkOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off:       return "关闭"
        case .error:     return "仅错误"
        case .warning:   return "警告以上"
        case .info:      return "全部"
        case .checkOnly: return "自检记录"
        }
    }
    /// 数值越大越详细
    var rank: Int {
        switch self {
        case .off: return 0
        case .error: return 1
        case .warning: return 2
        case .info, .checkOnly: return 3
        }
    }

    /// 判断一行日志属于哪个级别
    static func classify(_ line: String) -> LogLevel {
        let lower = line.lowercased()
        for k in ["失败", "错误", "无应答", "timeout", "error", "拒绝", "超时"] where lower.contains(k) {
            return .error
        }
        for k in ["提示", "警告", "断开", "重连", "warn"] where lower.contains(k) {
            return .warning
        }
        return .info
    }
}

/// 规则的目标类型。分成三类是为了让界面能对症下药：
/// 选"网站分类"时给下拉，选域名/IP 时才需要手输 —— 没人该去记 geosite: 这种前缀。
enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case domain    // 域名（含子域名）
    case ip        // IP 或 IP 段
    case category  // 预置的网站/地区分类

    var id: String { rawValue }
    var title: String {
        switch self {
        case .domain:   return "域名"
        case .ip:       return "IP / 网段"
        case .category: return "网站分类"
        }
    }
    var placeholder: String {
        switch self {
        case .domain:   return "claude.ai"
        case .ip:       return "192.168.50.0/24"
        case .category: return ""
        }
    }
}

/// 可选的网站/地区分类。取自 geosite / geoip 数据里最常用的那些，
/// 用中文标签呈现 —— 用户想的是"中国大陆网站"，不是 "geosite:cn"。
struct RuleCategory: Identifiable, Hashable {
    let value: String   // 内核认的写法
    let label: String   // 界面上显示的中文
    var id: String { value }

    static let all: [RuleCategory] = [
        .init(value: "geosite:cn",              label: "中国大陆网站"),
        .init(value: "geoip:cn",                label: "中国大陆 IP"),
        .init(value: "geosite:geolocation-!cn", label: "境外网站"),
        .init(value: "geosite:google",          label: "Google 系"),
        .init(value: "geosite:youtube",         label: "YouTube"),
        .init(value: "geosite:telegram",        label: "Telegram"),
        .init(value: "geosite:netflix",         label: "Netflix"),
        .init(value: "geosite:openai",          label: "OpenAI / ChatGPT"),
        .init(value: "geosite:github",          label: "GitHub"),
        .init(value: "geosite:apple",           label: "Apple"),
        .init(value: "geosite:microsoft",       label: "Microsoft"),
        .init(value: "geoip:private",           label: "局域网"),
        .init(value: "geoip:jp",                label: "日本 IP"),
        .init(value: "geoip:us",                label: "美国 IP"),
        .init(value: "geoip:hk",                label: "香港 IP"),
        .init(value: "geoip:tw",                label: "台湾 IP"),
        .init(value: "geoip:sg",                label: "新加坡 IP"),
    ]
}

/// 一条自定义分流规则。
struct CustomRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// 目标类型
    var kind: RuleKind = .domain
    /// 目标：域名、IP、IP 段，或分类的内核写法
    var target: String = ""
    /// 动作：direct / proxy / block
    var action: String = "direct"

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        target = ((try? c.decodeIfPresent(String.self, forKey: .target)) ?? nil) ?? ""
        action = ((try? c.decodeIfPresent(String.self, forKey: .action)) ?? nil) ?? "direct"
        // 老配置没有 kind 字段，按 target 的样子猜一个，不至于全变成"域名"
        if let k = ((try? c.decodeIfPresent(RuleKind.self, forKey: .kind)) ?? nil) {
            kind = k
        } else {
            let lower = target.lowercased()
            if lower.hasPrefix("geosite:") || lower.hasPrefix("geoip:") {
                kind = .category
            } else if target.contains("/") || target.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) {
                kind = .ip
            } else {
                kind = .domain
            }
        }
    }

    /// 转成内核认识的条件写法。
    /// 内核不接受裸域名，必须写成 domain:xxx —— 用户不该被要求知道这件事，
    /// 这里按内容自动判断该加什么前缀。
    var kernelCondition: String? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        switch kind {
        case .category:
            return t   // 下拉选出来的本来就是内核写法
        case .ip:
            return t   // IP 和 IP 段内核直接认
        case .domain:
            // 内核不认裸域名，必须是 domain:xxx。
            // *. 前缀去掉：domain 本身就匹配子域名，写 *.a.com 和 a.com 一回事。
            var d = t
            if d.lowercased().hasPrefix("domain:") { return d }
            if d.hasPrefix("*.") { d = String(d.dropFirst(2)) }
            return "domain:" + d
        }
    }
}

/// 一个可选项：内核认的值 + 界面上显示的说明。
struct PresetOption: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }

    /// 表示"手动输入"的哨兵值。用一个不可能与真实取值冲突的字符串，
    /// 免得用户真填了个同名的东西时被误判成自定义。
    static let customSentinel = "__custom__"
}

/// EchConfig DNS 服务预设。
/// 这些是社区在用的公共 DoH/UDP DNS —— 让用户从列表里挑，
/// 比要求他自己找一个能查 HTTPS 记录的服务器现实得多。
enum EchPresets {
    static let dnsServers: [PresetOption] = [
        .init(value: "dns.alidns.com/dns-query",       label: "阿里 DoH（国内推荐）"),
        .init(value: "sm2.doh.pub/dns-query",          label: "腾讯国密 DoH（国内）"),
        .init(value: "doh.360.cn/dns-query",           label: "360 DoH（国内）"),
        .init(value: "doh.onedns.net/dns-query",       label: "OneDNS DoH（国内）"),
        .init(value: "udp://208.67.220.220:443",               label: "OpenDNS（境外）"),
        .init(value: "udp://149.112.112.112:9953",             label: "Quad9（境外）"),
        .init(value: "udp://45.90.28.0:5353",                  label: "NextDNS（境外）"),
        .init(value: "udp://188.166.206.224:5003",             label: "Tiarap（境外）"),
        .init(value: "doh.applied-privacy.net/query",  label: "Applied Privacy DoH（境外）"),
        .init(value: "odvr.nic.cz/doh",                label: "CZ.NIC DoH（境外）"),
    ]

    /// EchConfig 解析域名。注意这是"去哪儿查 ECH 公钥"，
    /// 不是伪装域名 —— Cloudflare 的 ECH 域名固定是 cloudflare-ech.com。
    static let echDomains: [PresetOption] = [
        .init(value: "cloudflare-ech.com",     label: "cloudflare-ech.com（推荐）"),
        .init(value: "crypto.cloudflare.com",  label: "crypto.cloudflare.com"),
        .init(value: "encryptedsni.com",       label: "encryptedsni.com"),
        .init(value: "icook.hk",               label: "icook.hk"),
        .init(value: "cm.edu.kg",              label: "cm.edu.kg"),
        .init(value: "godotengine.org",        label: "godotengine.org"),
        .init(value: "www.britannica.com",     label: "www.britannica.com"),
        .init(value: "www.prometheus.io",      label: "www.prometheus.io"),
        .init(value: "www.kyocera.com",        label: "www.kyocera.com"),
        .init(value: "celestia.org",           label: "celestia.org"),
        .init(value: "lido.fi",                label: "lido.fi"),
    ]
}

/// 分流模式，对齐 v2rayN 的三档。
///
/// 「绕过中国大陆」和「黑名单」看着像，方向其实相反：
///   绕过大陆 = 默认走代理，认出是国内的才直连（白名单直连）
///   黑名单   = 默认直连，只有名单里的才走代理（更省流量，但漏网的站点会直连）
enum RouteMode: String, Codable, CaseIterable, Identifiable {
    case bypassCN   // 绕过中国大陆
    case blacklist  // 黑名单模式
    case global     // 全局模式

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bypassCN:  return "绕过中国大陆"
        case .blacklist: return "黑名单模式"
        case .global:    return "全局模式"
        }
    }

    var detail: String {
        switch self {
        case .bypassCN:  return "国内网站直连，其余走代理（推荐）"
        case .blacklist: return "只有名单内的网站走代理，其余全部直连"
        case .global:    return "所有流量都走代理"
        }
    }

    /// 三种模式都要 geo 数据：全局模式也得靠它认出内网地址
    var needsGeoData: Bool { true }

    /// 规则没命中时的默认走向
    var defaultRoute: String {
        switch self {
        // 注意不能用 all：那会跳过所有规则，连 192.168.x.x、10.x.x.x 这些
        // 内网地址也一并塞进隧道 —— 路由器后台、NAS、打印机全都会失效。
        // 全局的意思是"外网流量全走代理"，不包括局域网。
        case .global, .bypassCN: return "proxy"
        case .blacklist:         return "direct"
        }
    }

    /// 该模式自带的规则串。自定义规则会拼在它前面，因此优先级更高。
    var baseRoute: String {
        switch self {
        case .global:
            return "direct,geoip:private;direct,geosite:private"
        case .bypassCN:
            return "proxy,geosite:google;proxy,geosite:geolocation-!cn;direct,geoip:private;direct,geosite:private;direct,geosite:cn;direct,geoip:cn"
        case .blacklist:
            return "direct,geoip:private;direct,geosite:private;direct,geosite:cn;direct,geoip:cn;proxy,geosite:google;proxy,geosite:geolocation-!cn"
        }
    }
}

extension Array where Element == CustomRule {
    /// 找出被前面同目标规则盖住的那些规则的 id。
    ///
    /// 内核按顺序匹配、先命中先生效，所以同一个目标写两条时后一条永远不会执行。
    /// 这种规则不报错、不生效，用户只会觉得"我明明配了怎么没用" ——
    /// 与其等他自己发现，不如建的时候就标出来。
    var shadowedIDs: Set<UUID> {
        var seen = Set<String>()
        var shadowed = Set<UUID>()
        for r in self {
            guard let key = r.kernelCondition else { continue }
            if seen.contains(key) {
                shadowed.insert(r.id)
            } else {
                seen.insert(key)
            }
        }
        return shadowed
    }
}

// ServerConfig 与 Windows 版 ech-win-gui 的 ServerConfig 字段一一对应，
// 保证两边配置可以互相照抄（字段含义、默认值都保持一致）。
struct ServerConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "新服务器"

    /// -f  服务地址的主机名部分，例如 xxx.workers.dev（不含端口）
    var server: String = ""
    /// 服务端口，界面上单独一个输入框 —— 和主机名拆开填，
    /// 用户就不会因为打成中文冒号"："而连不上，还省得自己检查格式。
    var serverPort: Int = 443
    /// 本地监听地址的主机部分，通常就是 127.0.0.1
    var listen: String = "127.0.0.1"
    /// 本地监听端口。SOCKS5 用它，HTTP 代理自动用它 +1。
    var listenPort: Int = 30000
    /// -ip 优选 IP / 优选域名，多个用逗号分隔。
    /// 默认 cdns.doon.eu.org —— 客户端预设的默认优选域名，新服务器直接可用。
    var ip: String = "cdns.doon.eu.org"
    /// -ech ECH 域名，固定 cloudflare-ech.com
    var ech: String = "cloudflare-ech.com"
    /// -dns 查询 ECH 公钥用的 DoH 服务器
    var dns: String = "dns.alidns.com/dns-query"
    /// -token 身份令牌
    var token: String = ""

    /// -n 每个 IP 建立的 WebSocket 连接数
    var connections: Int = 3
    /// -block 客户端拦截的 UDP 端口
    var block: String = "443"
    /// -ips IP 访问策略："" / "4" / "6" / "4,6" / "6,4"
    var ips: String = ""
    /// -fallback 禁用 ECH 回落普通 TLS1.3
    var fallback: Bool = false
    /// -insecure 忽略证书校验
    var insecure: Bool = false

    /// 自定义分流规则，优先级高于分流模式自带的规则
    var customRules: [CustomRule] = []

    init() {}

    // 手写解码：Swift 自动合成的版本遇到 JSON 里缺字段会整个失败，
    // 那样以后每加一个新选项，用户已经填好的配置就会被当成损坏而清空。
    // 这里逐项 decodeIfPresent，缺的用默认值补，保证老配置永远读得进来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ d: String) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? d }
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? d }

        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        name = s(.name, "新服务器")
        // 老配置把端口写在主机名里（xxx.workers.dev:443），拆成两个字段
        let rawServer = s(.server, "")
        if let p = ((try? c.decodeIfPresent(Int.self, forKey: .serverPort)) ?? nil) {
            server = rawServer
            serverPort = p
        } else {
            let (h, prt) = Self.splitHostPort(rawServer, defaultPort: 443)
            server = h
            serverPort = prt
        }
        // 老版本可能存的是完整串（socks5://…）或 host:port，都收成 host + port
        let rawListen = Self.simplifyListen(s(.listen, "127.0.0.1:30000"))
        if let p = ((try? c.decodeIfPresent(Int.self, forKey: .listenPort)) ?? nil) {
            listen = rawListen
            listenPort = p
        } else {
            let (h, prt) = Self.splitHostPort(rawListen, defaultPort: 30000)
            listen = h.isEmpty ? "127.0.0.1" : h
            listenPort = prt
        }
        ip = s(.ip, "cdns.doon.eu.org")
        ech = s(.ech, "cloudflare-ech.com")
        dns = s(.dns, "dns.alidns.com/dns-query")
        token = s(.token, "")
        connections = ((try? c.decodeIfPresent(Int.self, forKey: .connections)) ?? nil) ?? 3
        block = s(.block, "443")
        ips = s(.ips, "")
        fallback = b(.fallback, false)
        insecure = b(.insecure, false)
        customRules = ((try? c.decodeIfPresent([CustomRule].self, forKey: .customRules)) ?? nil) ?? []
    }

    /// 从 "host:port" 里拆出主机和端口。中文冒号也认，顺手救一下手滑。
    static func splitHostPort(_ raw: String, defaultPort: Int) -> (String, Int) {
        var t = raw.trimmingCharacters(in: .whitespaces)
        // 去掉可能带的协议头
        for scheme in ["wss://", "ws://", "https://", "http://", "socks5://"] {
            if t.lowercased().hasPrefix(scheme) { t = String(t.dropFirst(scheme.count)) }
        }
        t = t.replacingOccurrences(of: "：", with: ":")   // 全角冒号
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        guard let colon = t.lastIndex(of: ":"),
              let p = Int(t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)),
              p > 0, p < 65536 else {
            return (t, defaultPort)
        }
        return (String(t[..<colon]), p)
    }

    /// 主机名清洗：去掉协议头、路径、空白和用户可能误输入的全角符号
    static func cleanHost(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        for scheme in ["wss://", "ws://", "https://", "http://", "socks5://"] {
            if t.lowercased().hasPrefix(scheme) { t = String(t.dropFirst(scheme.count)) }
        }
        t = t.replacingOccurrences(of: "：", with: ":")
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        // 端口有独立输入框，主机名里带的端口一律丢掉
        if let colon = t.lastIndex(of: ":"), Int(t[t.index(after: colon)...]) != nil {
            t = String(t[..<colon])
        }
        return t
    }

    /// 把界面上填的监听地址展开成内核认识的 -l 串。
    /// - `127.0.0.1:30000`  → `socks5://127.0.0.1:30000,http://127.0.0.1:30001`
    /// - `30000`            → 同上
    /// - `socks5://...`     → 原样使用
    /// - 留空                → 返回 nil，由调用方自动挑端口
    static func expandListen(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.contains("://") { return s }

        var host = "127.0.0.1"
        var portPart = s
        if let colon = s.lastIndex(of: ":") {
            host = String(s[..<colon])
            portPart = String(s[s.index(after: colon)...])
            if host.isEmpty { host = "127.0.0.1" }
        }
        guard let port = Int(portPart), port > 0, port < 65535 else { return nil }
        return "socks5://\(host):\(port),http://\(host):\(port + 1)"
    }

    /// expandListen 的逆操作：把 `socks5://H:P,http://H:P+1` 收回成 `H:P`。
    /// 只有正好是自动生成的那种组合才简化，用户手写的特殊监听保持原样。
    static func simplifyListen(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.contains("://") else { return s }
        let parts = s.split(separator: ",")
        guard parts.count <= 2, let socks = socksEndpoint(in: s) else { return s }
        if parts.count == 2 {
            guard let http = httpEndpoint(in: s),
                  http.host == socks.host, http.port == socks.port + 1 else { return s }
        }
        return "\(socks.host):\(socks.port)"
    }

    static func socksEndpoint(in listen: String) -> (host: String, port: Int)? {
        endpoint(in: listen, scheme: "socks5")
    }
    static func httpEndpoint(in listen: String) -> (host: String, port: Int)? {
        endpoint(in: listen, scheme: "http")
    }

    private static func endpoint(in listen: String, scheme: String) -> (String, Int)? {
        for raw in listen.split(separator: ",") {
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard item.lowercased().hasPrefix(scheme + "://") else { continue }
            var rest = String(item.dropFirst(scheme.count + 3))
            // 去掉可能存在的 user:pass@ 和路径
            if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
            guard let colon = rest.lastIndex(of: ":"),
                  let port = Int(rest[rest.index(after: colon)...]) else { continue }
            let host = String(rest[..<colon])
            return (host.isEmpty ? "127.0.0.1" : host, port)
        }
        return nil
    }

    /// 组装内核命令行参数。逻辑对齐 Windows 版 StartProcess()，
    /// 额外补上 Mac 版特有的分流参数（Windows 上这部分由 v2rayN 负责）。
    /// 拼内核启动参数。分流模式是全局参数（AppConfig.routeMode），由调用方传入。
    func arguments(listen: String? = nil, geoip: String? = nil, geosite: String? = nil, mode: RouteMode) -> [String] {
        var args: [String] = []
        func add(_ flag: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { args += [flag, v] }
        }

        add("-f", normalizedServer)
        add("-l", listen ?? expandedListen)

        // 分流规则：自定义的排在最前面，内核按顺序匹配，先命中先生效
        let custom = customRules.compactMap { r -> String? in
            guard let cond = r.kernelCondition else { return nil }
            return "\(r.action),\(cond)"
        }.joined(separator: ";")
        let base = mode.baseRoute
        let route = custom.isEmpty ? base : (base.isEmpty ? custom : custom + ";" + base)
        args += ["-default", mode.defaultRoute, "-route", route]

        if mode.needsGeoData {
            if let geoip { add("-geoip", geoip) }
            if let geosite { add("-geosite", geosite) }
        }
        add("-token", token)
        add("-ip", ip)

        if fallback {
            args.append("-fallback")
        } else {
            // Windows 版界面里 DOH 填的是 dns.alidns.com/dns-query（不带协议头），
            // 但内核只有识别到 http:// 或 https:// 前缀时才会走 DoH，
            // 否则会当成 UDP DNS 服务器去解析，必然失败。这里替用户补全。
            add("-dns", Self.normalizedDoH(dns))
            add("-ech", ech)
        }

        if connections != 3 { args += ["-n", String(connections)] }
        if insecure { args.append("-insecure") }
        add("-block", block)
        add("-ips", ips)
        return args
    }

    /// 内核要求 -f 带协议头，这里由主机名 + 端口拼出完整地址
    var normalizedServer: String {
        let h = Self.cleanHost(server)
        if h.isEmpty { return "" }
        return "wss://\(h):\(serverPort)"
    }

    /// 内核要求的 -l：SOCKS5 用监听端口，HTTP 用它 +1
    var expandedListen: String {
        let h = Self.cleanHost(listen)
        let host = h.isEmpty ? "127.0.0.1" : h
        return "socks5://\(host):\(listenPort),http://\(host):\(listenPort + 1)"
    }

    /// 把 dns.alidns.com/dns-query 这类写法补成 https://dns.alidns.com/dns-query。
    /// 纯 IP 或纯域名（不含路径）视为 UDP DNS，保持原样。
    static func normalizedDoH(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return s }
        let lower = s.lowercased()

        // 已经写了 http(s):// 的原样传，内核靠这个前缀判定走 DoH
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return s }

        // udp:// 是界面上用来标注"这是 UDP DNS"的，内核不认这个 scheme，
        // 得剥掉再传，否则它会拿整串去解析主机名，必然失败。
        if lower.hasPrefix("udp://") {
            s = String(s.dropFirst(6))
            return s
        }

        // 带路径的当 DoH，补上 https://；纯主机名/IP 当 UDP DNS
        if s.contains("/") { return "https://" + s }
        return s
    }

    /// 配置是否完整到可以启动。token 为可选，其余字段必须填写。
    func validate() -> String? {
        if Self.cleanHost(server).isEmpty { return "请填写「服务地址」" }
        if serverPort <= 0 || serverPort > 65535 { return "「服务端口」应在 1–65535 之间" }
        if URL(string: normalizedServer)?.host == nil {
            return "「服务地址」格式不对，应形如 xxx.workers.dev"
        }
        if Self.cleanHost(listen).isEmpty { return "请填写「监听地址」" }
        if listenPort <= 0 || listenPort >= 65535 { return "「监听端口」应在 1–65534 之间" }
        if ip.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写「优选IP/域名」" }
        return nil
    }
}

/// WebDAV 备份目标。密码不落盘，存系统钥匙串。
struct WebDAVConfig: Codable, Equatable {
    var url: String = ""
    var username: String = ""
    /// 远端备份目录。留空时按默认目录（EchOS_Backup）处理。
    var directory: String = ""

    /// 老配置里没有 directory 字段，缺键时用默认值，别把整个 WebDAV 设置作废。
    init() {}
    init(url: String, username: String, directory: String) {
        self.url = url
        self.username = username
        self.directory = directory
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ d: String) -> String {
            ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? d
        }
        url = s(.url, "")
        username = s(.username, "")
        directory = s(.directory, "")
    }
}

/// 整个 App 的持久化配置
struct AppConfig: Codable {
    var servers: [ServerConfig] = []
    var selectedID: UUID?
    /// 启动内核时是否自动接管系统代理
    var autoSystemProxy: Bool = true
    /// 日志里是否显示 [DNS-DIAG] 这类诊断行
    var showDiagnosticLogs: Bool = false
    /// 界面日志显示级别
    var logLevel: LogLevel = .info
    /// 是否在程序坞显示图标。关掉就只剩菜单栏图标，适合常驻后台。
    /// 默认关闭 —— 菜单栏已有完整功能，不需要在程序坞再占一个位置。
    var showDockIcon: Bool = false
    /// 全局分流模式：无论选中哪台服务器都遵从此设置（v1.1.12 起从
    /// 服务器级参数迁到 App 级，切换立即生效并落盘）。
    var routeMode: RouteMode = .bypassCN
    /// 底部日志面板是否展开
    var logVisible: Bool = true
    /// WebDAV 备份目标（密码在钥匙串里）
    var webdav: WebDAVConfig?

    init() {}

    /// 同 ServerConfig：缺字段时用默认值，不让老配置作废。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? d }
        servers = ((try? c.decodeIfPresent([ServerConfig].self, forKey: .servers)) ?? nil) ?? []
        selectedID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedID)) ?? nil
        autoSystemProxy = b(.autoSystemProxy, true)
        showDiagnosticLogs = b(.showDiagnosticLogs, false)
        logLevel = ((try? c.decodeIfPresent(LogLevel.self, forKey: .logLevel)) ?? nil) ?? .info
        showDockIcon = b(.showDockIcon, false)
        routeMode = ((try? c.decodeIfPresent(RouteMode.self, forKey: .routeMode)) ?? nil) ?? .bypassCN
        logVisible = b(.logVisible, true)
        webdav = (try? c.decodeIfPresent(WebDAVConfig.self, forKey: .webdav)) ?? nil
    }

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("config.json")
    }()

    static func load() -> AppConfig {
        var cfg = AppConfig()
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            cfg = loaded
        }
        // 不自动补一个空的「服务器 1」：全新安装不该预置任何服务器，
        // 否则用户导入配置时会混进一台新机器自带的空白配置。
        if cfg.selectedID == nil || !cfg.servers.contains(where: { $0.id == cfg.selectedID }) {
            cfg.selectedID = cfg.servers.first?.id
        }
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

// MARK: - 名字显示宽度

extension String {
    /// 显示宽度：汉字/全角算 2，英文数字符号算 1。
    /// 服务器名上限 16 宽度 = 8 个汉字 或 16 个英文/符号，混搭按宽度累计。
    var displayWidth: Int {
        unicodeScalars.reduce(0) { w, u in u.value >= 0x1100 ? w + 2 : w + 1 }
    }

    /// 从尾部截断，使显示宽度不超过 max。用于输入框实时限长。
    func truncated(toWidth max: Int) -> String {
        var out = ""
        var w = 0
        for ch in self {
            let cw = ch.unicodeScalars.first.map { $0.value >= 0x1100 ? 2 : 1 } ?? 1
            if w + cw > max { break }
            out.append(ch)
            w += cw
        }
        return out
    }
}
