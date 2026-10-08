import Foundation
import Darwin

/// 记录内核进程的 PID，用于 App 被强杀后清理残留进程。
///
/// 早先用 `pgrep -f <内核路径>` 找残留，结果误杀了命令行里恰好包含该路径的
/// 无关进程（比如一条引用了这个路径的终端命令）。所以改成：
/// 只认自己写下的 PID，并且在动手前用 proc_pidpath 核对该 PID 的可执行文件
/// 确实就是我们的内核 —— PID 会被系统复用，不核对就可能杀错人。
enum KernelPID {
    private static var fileURL: URL {
        AppConfig.fileURL.deletingLastPathComponent().appendingPathComponent("kernel.pid")
    }

    static func record(_ pid: pid_t) {
        try? String(pid).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 查询某个进程的可执行文件真实路径
    static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// 清理上次残留的内核进程。只有 PID 存在、且其可执行文件正是我们的内核时才下手。
    /// 返回是否真的杀掉了东西。
    @discardableResult
    static func killLeftover(expecting kernelPath: String?) -> Bool {
        defer { clear() }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, pid != ProcessInfo.processInfo.processIdentifier
        else { return false }

        // 进程还在吗？
        guard kill(pid, 0) == 0 else { return false }

        // 是我们的内核吗？PID 复用的情况下这一步能挡住误杀。
        guard let actual = executablePath(of: pid) else { return false }
        if let expected = kernelPath, actual != expected { return false }
        if kernelPath == nil, !actual.hasSuffix("/x-tunnel") { return false }

        return kill(pid, SIGTERM) == 0
    }
}
