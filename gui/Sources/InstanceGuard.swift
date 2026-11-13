// 单实例守卫：同一时刻只允许一个 EchOS 实例持有菜单栏。
//
// Win 端 instance_guard.dart 的 macOS 对应物。没有这道闸时，重复启动
// （DMG 挂载目录与 /Applications 各开一份、双击两次等）会叠出多个菜单栏
// 图标，各自控制各自的内核 —— 用户看到的是「好几个 EchOS」，实际是多个
// 进程在抢端口与系统代理。约定与 Win 相同：第二个实例把已运行实例的
// 主窗口唤醒，然后自己退出。
//
// 机制：App Support/EchOS/instance.lock 文件锁（flock）。进程死亡（含
// 强杀、断电）时内核自动释放锁，不存在「锁文件残留导致再也起不来」的
// 问题 —— 这是选 flock 而不是「锁文件存在即视为在跑」的原因。

import AppKit
import Darwin

enum InstanceGuard {
    private static let wakeName = "com.echos.mac.wake"
    /// 进程存续期间持有，锁随进程生死
    private static var lockFD: Int32 = -1

    /// 尝试成为唯一实例。返回 true = 已取得锁，本实例继续启动；
    /// 返回 false = 已有实例在跑（已向其发送唤醒通知），调用方应立即退出进程。
    @discardableResult
    static func claimOrWake() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // 打不开锁文件（目录权限异常等）：宁可放行双实例，也别让 App 起不来
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            return true
        }
        close(fd)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(wakeName), object: nil, userInfo: nil, deliverImmediately: true)
        return false
    }

    /// 主实例监听唤醒通知：把主窗口拉到前台（与菜单栏「显示应用」同款动作）。
    static func observeWake(_ handler: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(wakeName), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
