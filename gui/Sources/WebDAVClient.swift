import Foundation

enum WebDAVError: LocalizedError {
    case badURL
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badURL:      return "WebDAV 地址无效"
        case .badStatus(let code): return "服务器返回 \(code)"
        }
    }
}

/// 极简 WebDAV 客户端：只做整文件上传/下载，Basic Auth。
enum WebDAVClient {
    /// 备份文件名。目录留空时用这个默认目录。
    static let defaultDirectory = "EchOS_Backup"
    static let fileName = "EchOS-config.json"

    /// 把用户填的地址归一化成可直接 PUT 的 URL：
    /// 以 .json 结尾就当是完整文件路径；否则拼上「目录/EchOS-config.json」，
    /// 目录留空则用默认目录 EchOS_Backup。
    static func endpoint(_ raw: String, directory: String = "") -> URL? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: s) else { return nil }
        if s.lowercased().hasSuffix(".json") { return base }
        let dir = directory.trimmingCharacters(in: .whitespaces)
        return base
            .appendingPathComponent(dir.isEmpty ? defaultDirectory : dir)
            .appendingPathComponent(fileName)
    }

    /// 降级直连专用 Session（与「检查更新」同一套降级策略）：绕过系统代理。
    /// 系统代理被本 App 或其他代理工具接管时，WebDAV 流量跟着走隧道；隧道
    /// 半死/出口异常时会出现「浏览器正常（走了别的路径）、App 失败」——
    /// 第一次走系统代理（隧道通常更快），任何传输层失败（连接/超时/TLS
    /// 校验失败）都用直连再试一次：对家庭独立 IP 的 WebDAV 是更短更干净
    /// 的路径。服务端已应答的状态错误不重试。
    private static let directSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // 空字典 = 不走系统代理，直连
        return URLSession(configuration: cfg)
    }()

    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw WebDAVError.badURL }
            return (data, http)
        } catch {
            let (data, resp) = try await directSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw WebDAVError.badURL }
            return (data, http)
        }
    }

    static func upload(_ data: Data, to url: URL, username: String, password: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(auth(username, password), forHTTPHeaderField: "Authorization")
        let (_, resp) = try await send(req)
        try check(resp)
    }

    static func download(from url: URL, username: String, password: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(auth(username, password), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await send(req)
        try check(resp)
        return data
    }

    /// 删除 WebDAV 服务器上的备份文件（HTTP DELETE）。
    /// 文件本来就不存在（404）视为已删除，不报错。
    static func delete(from url: URL, username: String, password: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(auth(username, password), forHTTPHeaderField: "Authorization")
        let (_, http) = try await send(req)
        if http.statusCode == 404 { return }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.badStatus(http.statusCode) }
    }

    private static func auth(_ u: String, _ p: String) -> String {
        "Basic " + Data("\(u):\(p)".utf8).base64EncodedString()
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.badStatus(http.statusCode) }
    }
}
