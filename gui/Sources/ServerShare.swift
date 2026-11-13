import Foundation

enum ShareError: LocalizedError {
    case notShareFile
    var errorDescription: String? { "不是有效的服务器分享文件" }
}

/// 服务器列表分享文件格式。带 format/version 是为了导入时能识别
/// "这是服务器分享文件"，跟整份配置备份区分开。
struct ServerShareFile: Codable {
    var format: String = "echos-servers"
    var version: Int = 1
    var servers: [ServerConfig]
}
