import Foundation

/// 日志落盘。界面上的日志框只留最近 2000 行，出问题要回溯就得看文件。
///
/// 位置：~/Library/Application Support/EchOS/logs/
///   - latest.log    本次运行
///   - previous.log  上次运行（崩溃后回溯用）
enum LogFile {
    private static var handle: FileHandle?
    private static let queue = DispatchQueue(label: "com.echos.logfile")

    static var directory: URL {
        let dir = AppConfig.fileURL.deletingLastPathComponent()
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var currentURL: URL { directory.appendingPathComponent("latest.log") }
    private static var previousURL: URL { directory.appendingPathComponent("previous.log") }

    /// 自检记录单独一个文件。它和运行日志的性质不同 ——
    /// 运行日志是连续流水，自检是一次次的结论；混在一起想回看某次自检
    /// 得在几千行里翻，分开存一目了然。
    static var checkURL: URL { directory.appendingPathComponent("selfcheck.log") }
    private static var checkHandle: FileHandle?

    /// App 启动时调用：把上次的日志挪成 previous.log，开一份新的
    static func startNewSession() {
        let fm = FileManager.default
        if fm.fileExists(atPath: currentURL.path) {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: currentURL, to: previousURL)
        }
        fm.createFile(atPath: currentURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentURL)
        written = 0

        // 自检文件累积保留，不随每次启动清空 —— 回看历史几次自检结果才有意义
        if !fm.fileExists(atPath: checkURL.path) {
            fm.createFile(atPath: checkURL.path, contents: nil)
        }
        checkHandle = try? FileHandle(forWritingTo: checkURL)
        _ = try? checkHandle?.seekToEnd()

        let stamp = ISO8601DateFormatter().string(from: Date())
        write("=== EchOS 启动 \(stamp) ===")
    }

    /// 单个日志文件的大小上限。超过就地轮转，避免一次长时间运行把磁盘写满 ——
    /// 代理软件的日志是按连接数增长的，重度使用一天几百 MB 很正常。
    private static let maxFileSize = 8 * 1024 * 1024   // 8 MB
    private static var written = 0

    static func write(_ line: String) {
        guard handle != nil else { return }
        // 落盘放到后台队列，别拖慢界面刷新
        queue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
            written += data.count
            if written >= maxFileSize {
                rotateLocked()
            }
        }
    }

    /// 在队列内部调用：当前文件写满了，转成 previous.log 重新开一个
    private static func rotateLocked() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        try? fm.moveItem(at: currentURL, to: previousURL)
        fm.createFile(atPath: currentURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentURL)
        written = 0
        if let h = handle,
           let d = "=== 日志已轮转（上一段保存在 previous.log）===\n".data(using: .utf8) {
            try? h.write(contentsOf: d)
        }
    }

    /// 写一行自检记录（带时间戳，方便回看是哪次的结果）
    static func writeCheck(_ line: String) {
        guard checkHandle != nil else { return }
        queue.async {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm:ss"
            let stamped = "[\(f.string(from: Date()))] " + line + "\n"
            guard let d = stamped.data(using: .utf8) else { return }
            try? checkHandle?.write(contentsOf: d)
            // 自检记录增长很慢，超过 1MB 才截断，够存几千次结果
            if let size = try? FileManager.default
                .attributesOfItem(atPath: checkURL.path)[.size] as? Int, size > 1024 * 1024 {
                try? checkHandle?.close()
                try? FileManager.default.removeItem(at: checkURL)
                FileManager.default.createFile(atPath: checkURL.path, contents: nil)
                checkHandle = try? FileHandle(forWritingTo: checkURL)
            }
        }
    }

    /// 清空当前日志文件（连带上一段一起删），用于界面上的"清空"
    static func clear() {
        queue.sync {
            try? handle?.close()
            handle = nil
            let fm = FileManager.default
            try? fm.removeItem(at: previousURL)
            try? fm.removeItem(at: currentURL)
            fm.createFile(atPath: currentURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: currentURL)
            written = 0

            try? checkHandle?.close()
            try? fm.removeItem(at: checkURL)
            fm.createFile(atPath: checkURL.path, contents: nil)
            checkHandle = try? FileHandle(forWritingTo: checkURL)
        }
    }

    static func close() {
        queue.sync {
            try? handle?.close()
            try? checkHandle?.close()
        }
        handle = nil
        checkHandle = nil
    }

    /// 日志文件大小，界面上显示用
    static var currentSize: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: currentURL.path)
        let b = (attrs?[.size] as? Int) ?? 0
        guard b > 0 else { return "0 KB" }
        return b < 1024 * 1024
            ? String(format: "%.0f KB", Double(b) / 1024)
            : String(format: "%.1f MB", Double(b) / 1024 / 1024)
    }
}
