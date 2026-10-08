import Foundation
import Network

/// 启动后的连通性自检。
///
/// "不能上网"这四个字底下可能藏着完全不同的原因：ECH 公钥没拿到、隧道没建起来、
/// 分流数据没加载、系统代理没生效……光看一屏滚动的日志很难分辨。
/// 这里主动打几个探针，把每一环单独判定，直接告诉用户卡在哪一步。
enum SelfCheck {

    struct Result {
        var title: String
        var ok: Bool
        var note: String
        /// 是否"必须经隧道才通"的探针（国外站点）。本地端口、国内直连
        /// 探针失败可能是别的网络问题，不该拿它来决定回滚系统代理。
        var dependsOnTunnel = false
    }

    /// 通过本地 SOCKS5 访问一个地址，返回是否成功和耗时
    private static func probe(via socks: (host: String, port: Int),
                              url: String, timeout: TimeInterval) async -> (Bool, TimeInterval, String) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        // 让这次请求走我们自己的 SOCKS5，而不是系统代理
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": socks.host,
            "SOCKSPort": socks.port,
            kCFProxyTypeKey as String: kCFProxyTypeSOCKS,
        ]
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "HEAD"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = Date()
        do {
            let (_, resp) = try await session.data(for: req)
            let cost = Date().timeIntervalSince(start)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code > 0, cost, "HTTP \(code)")
        } catch {
            return (false, Date().timeIntervalSince(start), error.localizedDescription)
        }
    }

    /// 探测几次，失败就隔一段重试。
    /// 网络抖一下就亮红灯比不检还糟 —— 用户会以为真断了，跑去改配置。
    /// 实测远程出口（共享机房 IP）对个别站点会瞬时封禁几十秒再恢复，
    /// 所以间隔要拉开（1s、3s），给恢复留出窗口，别被一次抖动骗到。
    private static func probeRobust(via socks: (host: String, port: Int),
                                    url: String, timeout: TimeInterval) async -> (Bool, TimeInterval, String) {
        var last = await probe(via: socks, url: url, timeout: timeout)
        if last.0 { return last }
        for gap in [1.0, 3.0] {
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            let again = await probe(via: socks, url: url, timeout: timeout)
            if again.0 { return again }
            last = again
        }
        return (false, last.1, last.2 + "（多次重试仍失败，可能出口被目标站点临时拦截）")
    }

    /// 依次探测多个站点，任一成功即算通过，并记下是哪个站点通的。
    /// 单一站点探针会误杀"出口被 Google 系屏蔽、但其他国际站点正常"的服务器
    /// （例如某些 CF 分片对 google/gstatic 超时，bing/apple 却通畅）。
    private static func probeAny(via socks: (host: String, port: Int),
                                 urls: [String], timeout: TimeInterval) async -> (Bool, TimeInterval, String) {
        var failures: [String] = []
        var lastCost: TimeInterval = 0
        for url in urls {
            let (ok, cost, note) = await probe(via: socks, url: url, timeout: timeout)
            if ok {
                return (true, cost, "\(hostOf(url)) · \(Int(cost * 1000)) 毫秒")
            }
            failures.append("\(hostOf(url))：\(shortError(note))")
            lastCost = cost
        }
        return (false, lastCost, failures.joined(separator: "；"))
    }

    /// 多站点探测 + 失败重试：第一遍全挂就隔 1s、3s 再各来一轮，
    /// 给瞬时抖动的站点留出恢复窗口，别被一次抖动骗到。
    private static func probeAnyRobust(via socks: (host: String, port: Int),
                                       urls: [String], timeout: TimeInterval) async -> (Bool, TimeInterval, String) {
        var last = await probeAny(via: socks, urls: urls, timeout: timeout)
        if last.0 { return last }
        for gap in [1.0, 3.0] {
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            let again = await probeAny(via: socks, urls: urls, timeout: timeout)
            if again.0 { return again }
            last = again
        }
        return (false, last.1, last.2 + "（多次重试仍失败，可能出口被目标站点临时拦截）")
    }

    /// 从 URL 里取出 host，探针结果里直接点名是哪个站点。
    private static func hostOf(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// 错误信息只留前面一段，多个站点的失败原因并排放在一行里不至于太长。
    private static func shortError(_ s: String) -> String {
        let text = s.replacingOccurrences(of: "\n", with: " ")
        return text.count > 48 ? String(text.prefix(48)) + "…" : text
    }

    /// 跑一轮完整自检
    static func run(socks: (host: String, port: Int), mode: RouteMode) async -> [Result] {
        var results: [Result] = []

        // 1) 本地端口通不通 —— 不通说明内核没起来
        let portOK = !PortPicker.isFree(socks.port)
        results.append(Result(
            title: "本地代理端口 \(socks.port)",
            ok: portOK,
            note: portOK ? "正在监听" : "没有监听，内核可能没启动成功"))
        guard portOK else { return results }

        // 2) 国内站点：规则模式下应该直连，全局模式下走隧道
        let (cnOK, cnCost, cnNote) = await probeRobust(via: socks, url: "https://www.baidu.com", timeout: 8)
        results.append(Result(
            title: "国内网站（百度）",
            ok: cnOK,
            note: cnOK ? String(format: "%.0f 毫秒", cnCost * 1000)
                       : "失败：\(cnNote)"))

        // 3) 国外站点：最能反映隧道是否真的通。用"零字节 204 连通性端点"
        // （专为测网络设计，返回 204 空页、无业务内容/CDN 缓存干扰，比产品
        // 首页可靠）：gstatic 优先，被屏蔽就退而测 Cloudflare，任一 204 即
        // 隧道正常。多站点避免"Google 系出口被拦但其他正常"的服务器被误杀，
        // 系统代理也不会被误还原。
        do {
            let foreignProbes = [
                "https://www.gstatic.com/generate_204",     // Google 连通性端点
                "https://cp.cloudflare.com/generate_204",   // Cloudflare 连通性端点
            ]
            let (foreignOK, _, fNote) = await probeAnyRobust(via: socks,
                                                             urls: foreignProbes,
                                                             timeout: 8)
            results.append(Result(
                title: "国外网站（经隧道）",
                ok: foreignOK,
                note: foreignOK ? "\(fNote) · 隧道正常" : "失败：\(fNote)",
                dependsOnTunnel: true))
        }

        return results
    }

    /// 预检（代理未启动时手动触发）：不依赖本地 SOCKS 端口，直接测配置里的
    /// 服务端 / DoH 是否可达，人工确认这套配置在启动前"能不能用"。
    static func runPreflight(config: ServerConfig) async -> [Result] {
        var results: [Result] = []

        // 服务器地址以配置里的 server 为准（如 ech-cf.xxk.dpdns.org）：
        // 根路径 banner 和 Token 握手都必须连它才有意义；
        // 优选 IP 只是加速用的出口，不是被测对象。
        let serverHost = ServerConfig.cleanHost(config.server)
        if serverHost.isEmpty {
            results.append(Result(title: "服务器地址", ok: false, note: "未填写服务地址或优选IP/域名"))
            return results
        }

        // 1) 服务器地址：根路径应回 "WebSocket Proxy Server"。
        let (bannerOK, bannerNote) = await serverBannerCheck(
            host: serverHost, port: config.serverPort, timeout: 4)
        results.append(Result(title: "服务器地址", ok: bannerOK, note: bannerNote))

        // 2) Token 鉴权：真实带 token 发一次 WebSocket 升级请求。
        //    服务端回 101/200 = token 正确；401 = 客户端与服务端不一致。
        if bannerOK {
            let (wsOK, wsNote) = await tokenHandshakeCheck(
                host: serverHost, port: config.serverPort, token: config.token, timeout: 4)
            results.append(Result(title: "Token鉴权", ok: wsOK, note: wsNote))
        }

        return results
    }

    /// 请求服务端根路径，验证返回的是标准 Worker 标识 "WebSocket Proxy Server"。
    /// 用 URLSession 发普通 HTTP GET（不带 Upgrade），系统代理不参与本次探测。
    private static func serverBannerCheck(
        host: String, port: Int, timeout: TimeInterval
    ) async -> (Bool, String) {
        guard let url = URL(string: "https://\(host):\(port)/") else {
            return (false, "地址无效")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.connectionProxyDictionary = [:]   // 空字典 = 不走系统代理，直连
        let session = URLSession(configuration: cfg)
        do {
            let (data, resp) = try await session.data(from: url)
            let body = String(decoding: data, as: UTF8.self)
            if body.contains("WebSocket Proxy Server") {
                return (true, "WebSocket Proxy Server")
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (false, "返回异常内容（HTTP \(code)）")
        } catch {
            return (false, "连接失败：请检查服务地址/优选IP/域名")
        }
    }

    /// 做一次最小 WebSocket 升级握手，验证客户端与服务端 Token 是否一致。
    /// 客户端没配 Token 也照样握手（不带 Sec-WebSocket-Protocol 头）：
    /// 服务端同样为空则返回 101/200 = 一致；服务端配了 Token 则返回 401 = 不一致。
    /// 绝不能"没配就跳过" —— 跳过就漏掉了"服务端有 Token 而客户端为空"的不一致。
    /// 返回 (是否一致, 说明)。用 Network 框架（NWConnection）而非 URLSession，
    /// 因为 URLSession 没有暴露升级握手后的状态码；手写 HTTP 升级请求可控性最好。
    private static func tokenHandshakeCheck(
        host: String, port: Int, token: String, timeout: TimeInterval
    ) async -> (Bool, String) {
        let protocolHeader = token.isEmpty ? "" : "Sec-WebSocket-Protocol: \(token)\r\n"
        let request =
            "GET / HTTP/1.1\r\n" +
            "Host: \(host)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            protocolHeader +
            "\r\n"

        return await withCheckedContinuation { cont in
            // 防重复 resume：超时回调、状态失败、响应回调可能并发到达，
            // withCheckedContinuation 只能 resume 一次，多 resume 会崩溃。
            final class Done: @unchecked Sendable {
                let lock = NSLock()
                var fired = false
                func once(_ action: () -> Void) -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if fired { return false }
                    fired = true
                    action()
                    return true
                }
            }
            let done = Done()
            // 必须走 TLS：443 端口是 HTTPS，裸 TCP 发明文 HTTP 会被 TLS 层拒掉，
            // 握手永远拿不到状态行（表现为"无论 token 如何都判不一致"）。
            // 服务端域名做 SNI，避免证书校验时主机名不匹配。
            let tlsOptions = NWProtocolTLS.Options()
            host.withCString {
                sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, $0)
            }
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port))!,
                using: NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options()))
            let receivedLock = NSLock()
            var received = Data()
            let readHead: (Data) -> (Bool, String)? = { chunk in
                receivedLock.lock()
                received.append(chunk)
                let head = String(decoding: received, as: UTF8.self)
                receivedLock.unlock()
                // 兼容 HTTP/1.x 与 HTTP/2 两种状态行格式，提取三位状态码。
                // 状态行如 "HTTP/1.1 101 Switching Protocols" / "HTTP/2 401 Unauthorized"。
                let parts = head.split(separator: " ")
                guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
                    if head.contains("\r\n\r\n") || head.contains("\n\n") {
                        return (false, "客户端与服务端不一致")
                    }
                    return nil
                }
                if code == 401 || code == 403 {
                    return (false, "与服务端TOKEN不一致")
                }
                if code == 200 || code == 101 {
                    return (true, "服务端验证通过")
                }
                if head.contains("\r\n\r\n") || head.contains("\n\n") {
                    return (false, "客户端与服务端不一致")
                }
                return nil
            }
            let deadline = DispatchTime.now() + timeout

            conn.stateUpdateHandler = { state in
                switch state {
                case .failed(let err):
                    _ = done.once { cont.resume(returning: (false, "连接失败：\(err.localizedDescription)")) }
                    conn.cancel()
                case .ready:
                    conn.send(content: request.data(using: .utf8), completion: .contentProcessed { _ in })
                default:
                    break
                }
            }

            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                if let data, !data.isEmpty {
                    if let verdict = readHead(data) {
                        _ = done.once {
                            conn.cancel()
                            cont.resume(returning: verdict)
                        }
                    } else {
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { d2, _, _, e2 in
                            if let d2, !d2.isEmpty {
                                if let verdict = readHead(d2) {
                                    _ = done.once {
                                        conn.cancel()
                                        cont.resume(returning: verdict)
                                    }
                                    return
                                }
                            }
                            _ = done.once {
                                conn.cancel()
                                cont.resume(returning: (false, "客户端与服务端不一致"))
                            }
                        }
                    }
                } else if let err {
                    _ = done.once {
                        conn.cancel()
                        cont.resume(returning: (false, "读取响应失败：\(err.localizedDescription)"))
                    }
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                _ = done.once {
                    conn.cancel()
                    cont.resume(returning: (false, "握手超时"))
                }
            }
        }
    }
}
