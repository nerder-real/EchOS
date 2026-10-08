import Foundation

/// 开机自启动：写一个 LaunchAgent 描述文件到 ~/Library/LaunchAgents。
///
/// 为什么不用别的方案（在本项目 ad-hoc 签名下都实测不可用）：
/// - SMAppService.mainApp：要正式开发者签名，ad-hoc 直接报错（Code 22），
///   只能出现在「开机打开」，用不了。
/// - LSSharedFileList：老 API 在新 macOS 上已名存实亡，插入会静默失败，
///   kLSSharedFileListItemLast 常量访问即崩溃，也走不通。
/// - LaunchAgent：不挑签名，能真正开机启动；缺点是系统里显示在
///   「登录项 → 允许在后台运行」而不是「开机打开」——这是 macOS 对
///   无签名 App 的唯一途径，属于系统限制。
///
/// 「关闭」用 bootout + 删文件双管齐下，保证取消勾选后真的不再启动，
/// 不会出现"关了还在"的情况。
enum LoginItem {
    static let label = "com.echos.mac"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// App 自身的路径。
    private static var appPath: String {
        Bundle.main.bundleURL.path
    }

    static func set(_ enabled: Bool) throws {
        let fm = FileManager.default
        let dir = plistURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard enabled else {
            // 先尝试从 launchd 卸载（bootout 目标可能没加载，unload 文件路径兜底），
            // 无论成败都删掉 plist —— 文件是唯一持久依据，删了登录项就彻底关闭。
            // 最后再 disable 一次：launchd 在 bootstrap 时会往
            // /var/db/com.apple.xpc.launchd/disabled.<uid>.plist 写一条
            // "已启用"记录，系统设置「允许在后台运行」的开关就是读它显示的；
            // 只删 plist 不翻这条记录，开关就会一直卡在"开"。
            _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
            _ = try? runLaunchctl(["unload", plistURL.path])
            if fm.fileExists(atPath: plistURL.path) {
                try fm.removeItem(at: plistURL)
            }
            _ = try? runLaunchctl(["disable", "gui/\(getuid())/\(label)"])
            return
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        guard fm.fileExists(atPath: plistURL.path) else {
            throw NSError(domain: "LoginItem", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "登录项文件写入失败"])
        }
        // 上次关闭时记录可能被 disable 翻成了"禁用"，开启前先 enable 翻回来，
        // 再 bootstrap 立即注册（已注册时报错可忽略）
        _ = try? runLaunchctl(["enable", "gui/\(getuid())/\(label)"])
        _ = try? runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
