// 设备码：这台机器的「身份证」，授权流程的起点。
//
// 与 Windows 端（EchOS-Flutter-ZCode lib/services/device_identity.dart）同一套格式：
//   ECHC-XXXX-XXXX-XXXX-XXXX = sha256(拼接串) 前 16 字节 → 每字节 mod 32
//   映到 32 字符字母表（去 I/O/0/1），4 位一组。
// 80 bit 熵；传输上送带连字符的原串，服务端 normalize 兼容。
//
// ## macOS 三级取信（对应 Windows 的 UUID / MachineGuid / 卷序列号）
//   1. IOPlatformUUID          ——「这块主板就是这台机器」的权威标识，
//                                 重装系统不变（微软 SMBIOS UUID 的同源物）。
//   2. IOPlatformSerialNumber  ——整机序列号，克隆系统时与 UUID 互为区分。
//   3. 随机持久标识（device.id）—— 前两级都读不到时（理论情况）落一个
//                                 随机 UUID 到 Application Support。
//
// 与 Windows 的已知语义差异（方案 §2.12 决策点 1）：Windows 拼 MachineGuid
// 使「重装系统即换码」；macOS 无对应物，硬件标识跨重装稳定 —— Mac 设备码
// 跨重装不变，用户重装系统免重新登记。这是有意接受的差异。
//
// ## 占位值必须当没读到
// 厂商没填标识时会写占位串（最常见全 F 的 UUID、"To Be Filled By O.E.M."）。
// 这些若当真，同一批机器会算出同一个设备码 —— 全 F / 全 0 与文本占位一律拦掉，
// 降级到下一级（与 Windows 同一规则、同一份占位清单）。
//
// ## 为什么哈希而不是直接用
// UUID 与序列号都能定位到一台机器，没有理由明文发出去；哈希后发出的是摘要。

import Foundation
import CryptoKit
import IOKit

// ---- 码格式常量（与 Windows 端、服务端 License.js 三方一致）----
enum DeviceCodeFormat {
    static let deviceCodePrefix = "ECHC-"
    static let activationCodePrefix = "ECHS-"
    /// 去 I / O / 0 / 1 的人工友好字母表
    static let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    static let groups = 4
    static let groupLen = 4
    static let bodyLen = groups * groupLen   // 16 字符 = 80 bit
}

/// 激活码严格格式门：ECHS-XXXX-XXXX-XXXX-XXXX（大写、含连字符、字母表内字符）。
/// 客户端不做任何静默归一（大小写/连字符原样上送），服务端 normalize 才是宽容的。
enum ActivationCodeValidator {
    private static let re = try! NSRegularExpression(
        pattern: "^" + NSRegularExpression.escapedPattern(for: DeviceCodeFormat.activationCodePrefix)
            + "[\(DeviceCodeFormat.alphabet)]{4}(-[\(DeviceCodeFormat.alphabet)]{4}){3}$")

    static func isValid(_ raw: String) -> Bool {
        let range = NSRange(raw.startIndex..., in: raw)
        return re.firstMatch(in: raw, range: range) != nil
    }
}

@MainActor
enum DeviceIdentity {
    private static var cached: String?
    private static var source = ""

    /// 设备码。整进程只算一次。
    static var current: String {
        if let c = cached { return c }
        let c = compute()
        cached = c
        return c
    }

    /// 指纹来源说明，界面上如实告诉用户「这台机器的标识是怎么来的」。
    /// 走了回退分支时是弱口径，管理员签发前能一眼看出强弱。
    static var sourceLabel: String {
        _ = current
        return source
    }

    // MARK: - 拼接与渲染

    private static func compute() -> String {
        var parts: [String] = []
        source = ""

        // 一级：IOPlatformUUID（主板平台 UUID）
        if let uuid = readPlatformValue("IOPlatformUUID", isUUID: true) {
            parts.append("uuid:\(uuid)")
            source = "IOPlatformUUID"
        }
        // 二级：整机序列号（有它就加，多一道区分）
        if let sn = readPlatformValue("IOPlatformSerialNumber", isUUID: false) {
            parts.append("sn:\(sn)")
        }

        // 三级：前两级都读不到时，落一个随机持久标识兜底（重装/删目录会变）
        if parts.isEmpty, let rnd = persistedRandomID() {
            parts.append("rnd:\(rnd)")
            source = "随机持久标识（弱指纹）"
        }

        // 彻底空档：退回「系统版本 + 主机名」摘要（与 Windows 同款兜底）
        if parts.isEmpty {
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let host = Host.current().localizedName ?? ""
            parts.append(contentsOf: ["fallback", "macOS", os, host])
            source = "系统版本 + 主机名（弱指纹）"
        } else if source.isEmpty {
            source = "IOPlatformSerialNumber"
        } else if parts.count >= 2 {
            source = "IOPlatformUUID + 序列号"
        }

        let joined = parts.joined(separator: "|")
        let digest = Array(SHA256.hash(data: Data(joined.utf8)))
        return render(digest)
    }

    private static func render(_ digest: [UInt8]) -> String {
        let alphabet = DeviceCodeFormat.alphabet
        var out = DeviceCodeFormat.deviceCodePrefix
        for i in 0..<DeviceCodeFormat.bodyLen {
            if i > 0, i % DeviceCodeFormat.groupLen == 0 { out.append("-") }
            let idx = Int(digest[i]) % alphabet.count
            out.append(alphabet[alphabet.index(alphabet.startIndex, offsetBy: idx)])
        }
        return out
    }

    // MARK: - 平台标识读取

    /// 读 IOPlatformExpertDevice 注册表项。先走 IOKit 原生 API（微秒级），
    /// 读不到再退 ioreg 子进程（约几十毫秒）。取不到或值无效返回 nil。
    private static func readPlatformValue(_ key: String, isUUID: Bool) -> String? {
        if let v = readViaIOKit(key) ?? readViaIOReg(key) {
            return sanitized(v, isUUID: isUUID)
        }
        return nil
    }

    private static func readViaIOKit(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { _ = IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service,
                                                         key as CFString,
                                                         kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else { return nil }
        if let s = prop as? String { return s }
        if let d = prop as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }

    private static func readViaIOReg(_ key: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let head = text.range(of: "\"\(key)\" = \"") else { return nil }
        let rest = text[head.upperBound...]
        guard let tail = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<tail])
    }

    /// 占位串：厂商没填标识时写的内容。比较前原文已剔除所有非字母数字字符
    /// 并转大写，所以条目本身只含字母数字（与 Windows 同一份清单）。
    private static let placeholders: Set<String> = [
        "TOBEFILLEDBYOEM", "DEFAULTSTRING", "DEFAULTSERIALNUMBER",
        "NOTSPECIFIED", "UNKNOWN", "NONE", "NA",
        "SYSTEMSERIALNUMBER", "BASEBOARDSERIALNUMBER", "CHASSISSERIALNUMBER",
        "SYSTEMSERIALNUMBERFORIOS", "MACBOOKAIR", "MACMINI", "IMAC",
    ]

    /// 无效标识当没读到：空串、占位串、UUID 的全 F / 全 0 一律拦掉。
    private static func sanitized(_ raw: String, isUUID: Bool) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let squashed = trimmed.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        guard !squashed.isEmpty, !placeholders.contains(squashed) else { return nil }
        if isUUID {
            let hex = squashed.filter { $0.isHexDigit }
            guard hex.count == 32 else { return nil }
            if hex.allSatisfy({ $0 == "F" }) || hex.allSatisfy({ $0 == "0" }) { return nil }
        }
        return trimmed
    }

    /// 弱指纹兜底：随机 UUID 持久化到 Application Support/EchOS/device.id。
    /// 删掉该文件（或重置系统）会换码 —— 换机器依然换码，稳定性退化为
    /// 「不动这个文件就一直是同一个码」。
    private static func persistedRandomID() -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchOS", isDirectory: true)
        let file = dir.appendingPathComponent("device.id")
        if let s = try? String(contentsOf: file, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        let id = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try id.write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: file.path)
            return id
        } catch {
            return nil
        }
    }
}
