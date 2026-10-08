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

    static func upload(_ data: Data, to url: URL, username: String, password: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(auth(username, password), forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
    }

    static func download(from url: URL, username: String, password: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(auth(username, password), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
        return data
    }

    /// 删除 WebDAV 服务器上的备份文件（HTTP DELETE）。
    /// 文件本来就不存在（404）视为已删除，不报错。
    static func delete(from url: URL, username: String, password: String) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(auth(username, password), forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return }
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
