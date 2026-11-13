// 实时推送通道：管理端操作（吊销/恢复/换码）后服务端经 /ws 广播一句 resync，
// 客户端收到即刻 force 复核 —— 吊销感知从分钟级压到秒级。
//
// 与 Windows 端（license_service.dart _connectPush/_startPing）同一套语义：
//   · 通道只是「催一下」的信号，不含任何授权语义；收到后走与手动校验完全
//     相同的 verify()，服务端的答复才是权威。
//   · 心跳是**文本帧** "ping"/"pong"（不是 WebSocket 协议层 ping），30 秒一发；
//     发出后 10 秒内没等到 pong 视同半开连接，主动断开走重连 —— 静默死掉的
//     连接若无此探活，可能长时间不报错。
//   · pushLive 判定含 pong 新鲜度：90 秒（3 个心跳周期）没 pong 就当不在线，
//     客户端自动切回轮询兜底。半开连接「readyState==open 只是还没发现断」，
//     这段假在线期间若仍按在线处理，吊销感知会恶化成无限期。
//   · 断线按指数退避重连：5s→10s→20s→40s，封顶 60s。轮询节奏原样兜底，
//     通道掉线不影响任何判定。
//   · 重连成功立即补一课（0.5~5 秒随机延迟）：resync 广播不持久化，掉线窗口
//     里管理端做过的操作永远不会再推来，掉线前的旧状态要靠这次主动校验对齐。
//     随机延迟把「全量客户端同时重连→同时 verify」的部署瞬间尖峰摊开
//    （CF 部署必断连）。

import Foundation

@MainActor
final class LicensePush {
    var onResync: (() -> Void)?
    var onLivenessChanged: (() -> Void)?
    var onCatchup: (() -> Void)?
    /// 返回授权服务 http(s) 基址；空串 = 未配置。
    var baseURLProvider: (() -> String)?
    /// 通道事件日志（连接/断线/重连），接授权日志 —— 排查「吊销没反应」时
    /// 第一件事就是看推送通道当时在不在线。
    var onEventLog: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var auxTimer: Timer?
    private var connecting = false
    private var backoff = 0
    private var lastPongAt = Date()
    private var outageStart: Date?
    private var reconnectTimer: Timer?

    /// 推送是否在线。readyState==open 只是「还没发现断」，还要 pong 够新鲜
    /// （90 秒内有过 pong）才算真在线。
    var isLive: Bool {
        guard let task, task.state == .running else { return false }
        return Date().timeIntervalSince(lastPongAt) < 90
    }

    /// 推送通道已连续掉线多少分钟（在线时为 0）。运行期轮询与空闲兜底
    /// 共用这一个起点判定降档档位。
    var outageMinutes: Int {
        if isLive { outageStart = nil; return 0 }
        guard let outageStart else { return 0 }
        return Int(Date().timeIntervalSince(outageStart) / 60)
    }

    func start() {
        connect()
    }

    private func wsURL() -> URL? {
        guard let provider = baseURLProvider else { return nil }
        let base = provider()
        guard !base.isEmpty else { return nil }
        let ws = base.replacingOccurrences(of: "^http", with: "ws",
                                           options: .regularExpression, range: nil)
        return URL(string: ws + "/ws")
    }

    private func connect() {
        guard task == nil, !connecting, let url = wsURL() else { return }
        connecting = true
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        connecting = false
        backoff = 0
        // pong 窗口从「连上」这一刻起算：沿用上一条连接的旧值会把一条刚建好、
        // 健康的连接误判成半开而断掉 —— 30+10 秒自杀、5 秒后重连，循环往复。
        lastPongAt = Date()
        receiveLoop(on: t)
        startPing(t)
        onEventLog?("推送通道已连接")
        onLivenessChanged?()
        // 重连补课：0.5~5 秒随机延迟（首次连接也补，无害幂等）
        let delay = 0.5 + Double(Int.random(in: 0..<4500)) / 1000.0
        auxTimer?.invalidate()
        auxTimer = scheduledTimer(delay) { [weak self] in
            guard let self, self.isLive else { return }
            self.onCatchup?()
        }
    }

    private func receiveLoop(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t, t.state == .running else { return }
                switch result {
                case .success(.string(let text)):
                    if text == "pong" {
                        self.lastPongAt = Date()
                    } else if text == "resync" {
                        // resync = 服务端主动说「状态变了」——这就是事件，
                        // force 击穿立即问。
                        self.onResync?()
                    }
                    self.receiveLoop(on: t)
                case .success:
                    // 二进制帧 / 非约定文本：忽略，继续收
                    self.receiveLoop(on: t)
                case .failure:
                    self.handleDisconnect(t, reason: "接收出错（连接被关闭或网络异常）")
                }
            }
        }
    }

    private func startPing(_ t: URLSessionWebSocketTask) {
        pingTimer?.invalidate()
        pingTimer = scheduledTimer(30, repeats: true) { [weak self] in
            guard let self, self.task === t, t.state == .running else { return }
            let sentAt = Date()
            t.send(.string("ping")) { _ in }
            // 10 秒内没等到 pong：视同半开连接，主动断开走重连
            self.auxTimer?.invalidate()
            self.auxTimer = self.scheduledTimer(10) { [weak self] in
                guard let self, self.task === t, t.state == .running else { return }
                if self.lastPongAt < sentAt {
                    self.handleDisconnect(t, reason: "10 秒内未收到 pong（疑似半开连接）")
                }
            }
        }
    }

    private func handleDisconnect(_ t: URLSessionWebSocketTask, reason: String) {
        guard task === t else { return }
        task = nil
        pingTimer?.invalidate()
        // 半开连接主动关掉，别留一个挂着的 socket
        t.cancel(with: .goingAway, reason: nil)
        if outageStart == nil { outageStart = Date() }
        onEventLog?("推送通道断线：\(reason)")
        onLivenessChanged?()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        // 指数退避：5s、10s、20s、40s，封顶 60s
        let delay = backoff < 4 ? Double(5 << backoff) : 60.0
        backoff += 1
        reconnectTimer?.invalidate()
        reconnectTimer = scheduledTimer(delay) { [weak self] in
            self?.connect()
        }
        onEventLog?("推送通道 \(Int(delay)) 秒后重连（第 \(backoff) 次退避）")
    }

    /// Timer 便捷封装：block 回到 MainActor（scheduledTimer 的 block 不是
    /// @MainActor，但从主线程调度时 assumeIsolated 是安全的）。
    @discardableResult
    private func scheduledTimer(_ interval: TimeInterval, repeats: Bool = false,
                                _ handler: @escaping @MainActor () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
