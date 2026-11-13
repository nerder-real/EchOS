import Foundation
import Darwin
import AppKit

// TUN 内核启动器：root 内核经 sudoers 免密白名单拉起（GUI 保持普通权限）。
//
// 提权链：macOS 26 起 `do shell script … with administrator privileges` 提权
// 失效（弹框、收下密码，命令仍以普通用户执行，whoami 实测），所以：
//   · 首次开 TUN：GUI 自己弹一次密码框，密码经管道交给 `sudo -S`，装好 sudoers
//     白名单（只授权固定路径的启动脚本，不开放任意 root 命令）；
//   · 此后每次：`sudo -n <启动脚本>` 免密执行，不再有任何弹窗、不用终端。
//
// 与普通内核（GUI 直接 Process 拉起、持有管道）的差别：
//   · GUI 拿不到 root 进程的 stdin/stdout —— 停内核靠「停止标记文件」
//     （内核 watchStopFile 轮询），日志由内核自己写 tun-kernel.log 供 GUI tail；
//   · PID 记录在同一个 kernel.pid 文件里（tun-run.sh `echo $!` 写入），
//     GUI 用 kill(pid, 0) 探活 —— 对 root 进程会返回 EPERM，EPERM 即「存在」。
@MainActor
enum TunLauncher {
    /// 提权/启动的结果。取消（用户关掉密码框）与失败分开：前者只记日志，
    /// 后者要把原因弹给用户。
    enum Outcome: Equatable {
        case ok
        case cancelled
        case failed(String)
    }

    private static var exitMonitor: Timer?

    private static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchOS", isDirectory: true)
    }
    /// 启动脚本目录：放在无空格路径（~/Library/Application Support 带空格，
    /// sudoers 白名单对带空格路径要么转义要么整条解析失败——2026-10-27 实录，
    /// 用户终端装的白名单 96 字节内容正确却完全不生效，根因就是空格）。
    private static var scriptDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".echos", isDirectory: true)
    }
    /// 白名单授权的固定路径启动器（内容通用，见 launcherScript）
    static var launcherURL: URL { scriptDir.appendingPathComponent("tun-launch.sh") }
    /// 本次内核启动命令（路径/参数会变，每次启动前重写，由启动器 source）
    static var runScriptURL: URL { scriptDir.appendingPathComponent("tun-run.sh") }
    static var stopMarkerURL: URL { appSupportDir.appendingPathComponent("tun.stop") }
    static var kernelLogURL: URL { appSupportDir.appendingPathComponent("logs/tun-kernel.log") }
    private static let sudoersFile = "/private/etc/sudoers.d/echos-tun"

    /// sudoers 规则：只写脚本路径，不带参数、不带 /bin/sh 前缀。sudoers 里命令
    /// 一旦写了参数就只匹配完全相同的参数（`/bin/sh <脚本>` 会让 `<脚本> probe`
    /// 不命中）；只写路径则任意参数都放行。
    static var sudoersRule: String { "\(NSUserName()) ALL=(root) NOPASSWD: \(launcherURL.path)" }

    /// 启动器内容：
    ///   probe 模式 → 回显 uid（供探测免密 root 是否可用；sudoers 文件是
    ///                root-only，GUI 读不了，第一版就栽在这里）
    ///   无参/其他  → source tun-run.sh 启动内核
    static var launcherScript: String {
        "#!/bin/sh\nif [ \"$1\" = \"probe\" ]; then /bin/echo \"uid=$(id -u)\"; exit 0; fi\n. \(shellQuote(runScriptURL.path))\n"
    }

    /// 一次性的 sudoers 白名单安装（首次开 TUN 时完成）。
    /// 已生效（sudo -n 探针通过）则静默返回 .ok；否则弹一次密码框，经 sudo -S
    /// 装规则——密码错可重输，关掉密码框返回 .cancelled。
    static func installSudoersOnce() -> Outcome {
        // 探测前必须先把启动器写回标准内容：白名单让这个路径以 root 执行，
        // 现场若被诊断脚本之类覆盖过，`probe` 会把那份内容以 root 跑一遍。
        guard writeLauncher() else {
            return .failed("无法写入启动脚本 \(launcherURL.path)")
        }
        if probeSudoNOPASSWD() { return .ok }

        var retry = false
        while let password = askAdminPassword(retry: retry) {
            switch installRule(password: password) {
            case .installed:
                return probeSudoNOPASSWD()
                    ? .ok
                    : .failed("白名单已写入 \(sudoersFile)，但免密探测仍未通过")
            case .wrongPassword:
                retry = true
            case .error(let reason):
                return .failed(reason)
            }
        }
        return .cancelled
    }

    /// sudo -n 探针：白名单命中（免密 root 可用）返回 true。
    /// -n 不命中时立即失败、不挂起等密码，适合做探测。
    static func probeSudoNOPASSWD() -> Bool {
        let r = run("/usr/bin/sudo", ["-n", launcherURL.path, "probe"])
        return r.status == 0 && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "uid=0"
    }

    /// 以 root 启动内核：先确保白名单可用（首次弹一次密码框，此后静默），
    /// 再 `sudo -n` 执行固定路径启动器，内核真正以 root 运行。
    static func launchRootKernel(executable: String, arguments: [String]) -> Outcome {
        let prep = installSudoersOnce()
        guard prep == .ok else { return prep }
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: kernelLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 清掉残留停止标记（内核启动时自己也会删，双保险）
        try? fm.removeItem(at: stopMarkerURL)

        // 内核经 perl setsid 脱离 sudo/GUI 的会话与进程组后再 exec：启动器、sudo
        // 退出后发往原进程组的信号波及不到内核；exec 不换 PID，`$!` 即内核 PID。
        let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let pidPath = appSupportDir.appendingPathComponent("kernel.pid").path
        let runScript = "#!/bin/sh\n"
            + "/usr/bin/perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV or die \"exec: $!\"' -- "
            + "\(command) </dev/null >>\(shellQuote(kernelLogURL.path)) 2>&1 &\n"
            + "echo $! > \(shellQuote(pidPath))\n"
        do {
            try runScript.write(to: runScriptURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed("无法写入内核启动脚本 \(runScriptURL.path)")
        }

        let r = run("/usr/bin/sudo", ["-n", launcherURL.path])
        guard r.status == 0 else {
            let detail = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("root 内核启动失败" + (detail.isEmpty ? "（sudo 退出码 \(r.status)）" : "：\(detail)"))
        }
        return .ok
    }

    /// 创建停止标记：root 内核轮询到后清理（路由/DNS/网卡）并退出。
    static func requestStop() {
        try? "stop".write(to: stopMarkerURL, atomically: true, encoding: .utf8)
    }

    /// root 内核是否存活。kill(pid, 0) 对 root 进程返回 EPERM —— EPERM 也是「存在」。
    static func kernelAlive() -> Bool {
        let pidPath = appSupportDir.appendingPathComponent("kernel.pid")
        guard let s = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// 启动 root 内核退出监控：轮询 PID，内核消失（主动停/崩溃/被清）后
    /// 在主线程做与普通 terminationHandler 相同的状态收尾。
    static func startExitMonitor(onExit: @escaping () -> Void) {
        exitMonitor?.invalidate()
        exitMonitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                if !kernelAlive() {
                    timer.invalidate()
                    exitMonitor = nil
                    onExit()
                }
            }
        }
    }

    static func stopExitMonitor() {
        exitMonitor?.invalidate()
        exitMonitor = nil
    }

    // MARK: - 私有

    private enum InstallResult { case installed, wrongPassword, error(String) }

    /// 把启动器写回标准内容（0755）。
    private static func writeLauncher() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: scriptDir, withIntermediateDirectories: true)
            try launcherScript.write(to: launcherURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
            return true
        } catch {
            return false
        }
    }

    /// 密码框（NSAlert + 安全输入框）。返回 nil = 用户取消。
    private static func askAdminPassword(retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? "密码不正确，请重试" : "EchOS 需要管理员权限启用 TUN 模式"
        alert.informativeText = "请输入「\(NSUserName())」的登录密码完成一次性配置，之后开启 TUN 不再询问。"
        alert.alertStyle = retry ? .warning : .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "密码"
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// 用管理员密码装白名单。规则由 root 先写进临时文件、visudo 校验通过才换入
    /// sudoers.d——那里任何一个文件语法错，sudo 会整体拒绝工作（连终端 sudo 都
    /// 用不了），绝不能直接写目标文件。临时文件名带点，sudo 的 includedir 会
    /// 跳过它，校验前后都不会被当成规则读入。
    private static func installRule(password: String) -> InstallResult {
        let script = """
            /bin/echo echos-auth-ok
            umask 077
            /bin/mkdir -p /private/etc/sudoers.d
            t=$(/usr/bin/mktemp /private/etc/sudoers.d/.echos-tun.XXXXXX) || exit 1
            trap '/bin/rm -f "$t"' EXIT
            /usr/bin/printf '%s\\n' "$1" > "$t" &&
            /usr/sbin/visudo -cf "$t" &&
            /usr/sbin/chown root:wheel "$t" &&
            /bin/chmod 0440 "$t" &&
            /bin/mv -f "$t" "$2"
            """
        // -S 从 stdin 读密码；-k 不用也不留凭据缓存（否则之后 5 分钟内 GUI
        // 发起的任何 sudo 都免密）；-p '' 不往 stderr 打提示语。
        let r = run("/usr/bin/sudo",
                    ["-S", "-k", "-p", "", "/bin/sh", "-c", script, "sh", sudoersRule, sudoersFile],
                    input: password + "\n")
        if r.status == 0 { return .installed }
        // 脚本第一行都没跑到 = sudo 认证这关没过
        if !r.out.contains("echos-auth-ok") {
            if r.err.contains("not in the sudoers") || r.err.contains("not allowed to execute") {
                return .error("当前用户「\(NSUserName())」没有管理员权限，无法启用 TUN 模式")
            }
            return .wrongPassword
        }
        let detail = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return .error("写入 sudoers 白名单失败" + (detail.isEmpty ? "" : "：\(detail)"))
    }

    /// 跑一个短命令并收集输出（输出都很小，顺序读两根管道不会撑满缓冲）。
    private static func run(_ path: String, _ args: [String], input: String? = nil)
        -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        if input != nil {
            p.standardInput = inPipe
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        if let input {
            let w = inPipe.fileHandleForWriting
            // 对端（sudo）若已退出，写管道不能拿 SIGPIPE 把整个 GUI 带走
            _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? w.write(contentsOf: Data(input.utf8))
            try? w.close()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    /// sh 单引号转义
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
