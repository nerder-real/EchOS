import Foundation
import AppKit

/// 应用内更新，两个独立通道：
/// 1) App 版本更新 —— 读 GitHub Releases 最新版，发现新版则下载 DMG 到 ~/Downloads 并挂载，用户拖入替换
/// 2) 分流数据更新 —— geoip.dat / geosite.dat 下载到数据目录，内核启动优先加载数据目录里的新版
///
/// 两个通道都只在"有网络"时工作；任何一步失败都静默跳过、不阻塞启动，
/// 下次启动或手动点击会重试。
enum Updater {

    /// 更新源（形如 "owner/EchOS"）。
    /// 从 Info.plist 的 EchOSUpdateRepo 键读取，发布打包时注入 ——
    /// 源码和界面里都不写死真实仓库地址，反编译也看不到。
    static var repo: String {
        (Bundle.main.object(forInfoDictionaryKey: "EchOSUpdateRepo") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// 分流数据上游（Loyalsoldier/v2ray-rules-dat，release tag 是日期，如 20250801）
    static let geoRepo = "Loyalsoldier/v2ray-rules-dat"

    // MARK: - 数据目录

    /// ~/Library/Application Support/EchOS/data/
    static var dataDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("EchOS/data", isDirectory: true)
    }
    static var metaURL: URL   { dataDir.appendingPathComponent("meta.json") }
    static var geoipURL: URL  { dataDir.appendingPathComponent("geoip.dat") }
    static var geositeURL: URL{ dataDir.appendingPathComponent("geosite.dat") }

    /// 数据目录里存在的话返回路径，否则 nil（内核退回用 App 内置的）
    static func geoDataPath(for name: String) -> String? {
        let p = dataDir.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    // MARK: - 版本比较

    struct ReleaseInfo: Identifiable {
        var id: String { tag }
        var tag: String          // 例如 "v1.0.2"
        var version: String      // 例如 "1.0.2"
        var dmgName: String?
        var dmgURL: URL?
        var htmlURL: URL
    }

    /// 当前 App 版本（Info.plist CFBundleShortVersionString）
    static var localVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func parseVersion(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    /// a 是否比 b 新
    static func version(_ a: [Int], isNewerThan b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func githubRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("EchOS/\(localVersion)", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// 降级直连专用 Session：绕过系统代理（connectionProxyDictionary 空 = 不代理）。
    /// 策略是"隧道优先、失败降级"——所有 GitHub 请求先走系统代理（URLSession.shared，
    /// 隧道通常更快）；拿不到结果（含隧道出口被 GitHub 限流 403、代理节点故障）时，
    /// 再用本 Session 直连重试一次。直连对 api.github.com 是独立家庭 IP，能避开
    /// 共享机房 IP 的 API 限流；对 DMG/geoip 大文件则是无奈兜底（慢但可能通）。
    private static let directSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // 空字典 = 不走系统代理，直连
        return URLSession(configuration: cfg)
    }()

    // MARK: - App 版本检查

    /// 拉取最新 Release。completion 在主线程回调。
    /// 网络策略：先走系统代理（隧道，通常更快）；若失败（含隧道出口被
    /// GitHub 限流 403、直连被墙等）自动降级为直连再试一次。
    static func fetchLatestRelease(completion: @escaping (ReleaseInfo?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(nil); return
        }
        func attempt(useDirect: Bool) {
            let session = useDirect ? directSession : URLSession.shared
            session.dataTask(with: githubRequest(url)) { data, _, _ in
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    if !useDirect { attempt(useDirect: true); return }   // 降级直连重试一次
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                var info = ReleaseInfo(
                    tag: tag,
                    version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")),
                    dmgName: nil,
                    dmgURL: nil,
                    htmlURL: URL(string: obj["html_url"] as? String ?? "https://github.com/\(repo)")!
                )
                if let assets = obj["assets"] as? [[String: Any]] {
                    for a in assets {
                        guard let name = a["name"] as? String,
                              name.hasSuffix(".dmg"),
                              let u = a["browser_download_url"] as? String else { continue }
                        info.dmgName = name
                        info.dmgURL = URL(string: u)
                        break
                    }
                }
                DispatchQueue.main.async { completion(info) }
            }.resume()
        }
        attempt(useDirect: false)
    }

    /// 下载 DMG 到 ~/Downloads。progress 0~1、finish(destURL) 都在主线程回调。
    /// 返回下载器，调用方可 cancel() 中断下载（isCancelled 置位）。
    @discardableResult
    static func downloadDMG(_ info: ReleaseInfo,
                            progress: @escaping (Double) -> Void,
                            finish: @escaping (URL?) -> Void) -> DMGDownloader {
        let downloader = DMGDownloader()
        guard let dmgURL = info.dmgURL else { finish(nil); return downloader }
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent(info.dmgName ?? "EchOS-mac-\(info.version)-universal-x64.dmg")
        // 先走系统代理（隧道，通常更快）；失败且非用户取消时，降级直连重试一次
        var retried = false
        func startDirect() {
            downloader.start(from: dmgURL, to: dest, direct: true,
                             progress: progress) { url in
                if url == nil, downloader.isCancelled == false, !retried {
                    retried = true
                    startDirect()
                } else {
                    finish(url)
                }
            }
        }
        downloader.start(from: dmgURL, to: dest, direct: false,
                         progress: progress) { url in
            if url == nil, downloader.isCancelled == false, !retried {
                retried = true
                startDirect()
            } else {
                finish(url)
            }
        }
        return downloader
    }

    /// 挂载 DMG（nobrowse，不弹出 Finder 窗口），返回挂载点；失败返回 nil。
    static func mountDMG(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", url.path, "-nobrowse", "-plist"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for e in entities {
            if let mp = e["mount-point"] as? String, !mp.isEmpty { return mp }
        }
        return nil
    }

    // MARK: - 分流数据更新

    struct GeoMeta: Codable {
        var source = "loyalsoldier"
        var version = ""
        var updatedAt = ""
    }

    static func localGeoVersion() -> String {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(GeoMeta.self, from: data) else { return "" }
        return meta.version
    }

    static func hasLocalGeoData() -> Bool {
        FileManager.default.fileExists(atPath: geoipURL.path)
            && FileManager.default.fileExists(atPath: geositeURL.path)
    }

    /// 检查并更新分流数据。
    /// - Parameters:
    ///   - force: true = 强制重新下载；false = 版本相同且文件在则跳过
    ///   - log: 进度输出（AppState.log，主线程）
    ///   - completion: (ok, message) 主线程回调
    static func updateGeoData(force: Bool,
                              log: @escaping (String) -> Void,
                              completion: @escaping (Bool, String) -> Void) {
        log("[更新] 正在检查分流数据版本…")
        guard let url = URL(string: "https://api.github.com/repos/\(geoRepo)/releases/latest") else {
            completion(false, "地址无效"); return
        }
        func attempt(useDirect: Bool) {
            let session = useDirect ? directSession : URLSession.shared
            session.dataTask(with: githubRequest(url)) { data, _, _ in
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    if !useDirect { attempt(useDirect: true); return }   // 降级直连重试一次
                    DispatchQueue.main.async { completion(false, "检查失败（网络不通或 GitHub 不可达）") }
                    return
                }
                let current = localGeoVersion()
                if !force, current == tag, hasLocalGeoData() {
                    DispatchQueue.main.async { completion(true, "已是最新（\(tag)）") }
                    return
                }
                log("[更新] 上游最新 \(tag)（本地 \(current.isEmpty ? "无" : current)），开始下载…")
                downloadGeoFiles(tag: tag, log: log) { ok in
                    if ok {
                        let meta = GeoMeta(version: tag, updatedAt: ISO8601DateFormatter().string(from: Date()))
                        if let data = try? JSONEncoder().encode(meta) {
                            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
                            try? data.write(to: metaURL, options: .atomic)
                        }
                        DispatchQueue.main.async { completion(true, "分流数据已更新到 \(tag)") }
                    } else {
                        DispatchQueue.main.async { completion(false, "下载失败，已保留原有数据") }
                    }
                }
            }.resume()
        }
        attempt(useDirect: false)
    }

    private static func downloadGeoFiles(tag: String,
                                         log: @escaping (String) -> Void,
                                         done: @escaping (Bool) -> Void) {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let base = "https://github.com/\(geoRepo)/releases/download/\(tag)"
        let group = DispatchGroup()
        var allOK = true
        let barrier = NSLock()
        for name in ["geoip.dat", "geosite.dat"] {
            group.enter()
            let dest = dataDir.appendingPathComponent(name)
            let tmp = dataDir.appendingPathComponent(".\(name).tmp")
            guard let url = URL(string: "\(base)/\(name)") else { group.leave(); continue }
            func attempt(useDirect: Bool) {
                let session = useDirect ? directSession : URLSession.shared
                var req = URLRequest(url: url)
                req.timeoutInterval = 120
                session.downloadTask(with: req) { location, _, error in
                    var moved = false
                    if let location, error == nil {
                        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? Int ?? 0
                        if size > 100_000 {   // 拦截空文件/错误页
                            try? FileManager.default.removeItem(at: tmp)
                            do {
                                try FileManager.default.moveItem(at: location, to: tmp)
                                if FileManager.default.fileExists(atPath: dest.path) {
                                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
                                } else {
                                    try FileManager.default.moveItem(at: tmp, to: dest)
                                }
                                moved = true
                            } catch {}
                        }
                    }
                    if moved {
                        group.leave()
                    } else if !useDirect {
                        attempt(useDirect: true)   // 隧道失败，降级直连重试一次（重试成功后由它 leave）
                    } else {
                        barrier.lock(); allOK = false; barrier.unlock()
                        group.leave()
                    }
                }.resume()
            }
            attempt(useDirect: false)
        }
        group.notify(queue: .main) {
            log("[更新] geoip/geosite 下载完成（\(allOK ? "成功" : "失败")）")
            done(allOK)
        }
    }
}

/// DMG 下载器（URLSessionDownloadDelegate，带进度回调）
final class DMGDownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var dest: URL?
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((URL?) -> Void)?
    /// 用户主动取消置位，供 finish 回调区分"取消"和"失败"。
    private(set) var isCancelled = false

    /// 中断下载：会话取消后 didCompleteWithError 会回调 finish(nil)。
    func cancel() {
        isCancelled = true
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func start(from url: URL,
               to dest: URL,
               direct: Bool,
               progress: @escaping (Double) -> Void,
               finish: @escaping (URL?) -> Void) {
        self.dest = dest
        self.onProgress = progress
        self.onFinish = finish
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        if direct { cfg.connectionProxyDictionary = [:] }   // 降级直连时绕过系统代理
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        self.session = session
        self.task = session.downloadTask(with: url)
        task?.resume()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        onProgress?(min(1, max(0, p)))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let dest else { onFinish?(nil); return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            onFinish?(dest)
        } catch {
            onFinish?(nil)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        if error != nil { onFinish?(nil) }
    }
}
