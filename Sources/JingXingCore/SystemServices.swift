import Foundation
import IOKit
import IOKit.ps

// MARK: - 讀取系統狀態（只讀，不需權限）

public final class SystemLidProbe: LidSystemProbe {
    public init() {}

    private func rootDomainProperty(_ key: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    public func sleepDisabled() -> Bool? {
        rootDomainProperty("SleepDisabled") as? Bool
    }

    public func clamshell() -> ClamshellInfo? {
        guard let closed = rootDomainProperty("AppleClamshellState") as? Bool else { return nil }
        return ClamshellInfo(closed: closed)
    }

    public func powerSource() -> PowerSourceInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var batteries: [[String: Any]] = []
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                if let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                   (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType {
                    batteries.append(desc)
                }
            }
        }
        return PowerSourceInfo.parse(providing: providing, batteries: batteries)
    }

    public func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    public func process(_ pid: Int32) -> ProcessSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        let start = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return ProcessSnapshot(pid: pid, startTime: start, command: command, uid: info.kp_eproc.e_ucred.cr_uid)
    }
}

// MARK: - 本程式的工作檔

public final class FileLidSessionFiles: LidSessionFiles {
    public let directory: URL
    private var recordURL: URL { directory.appendingPathComponent("lid-session.json") }

    public init(directory: URL) { self.directory = directory }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("JingXing", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func prepare(token: String) throws -> (stop: String, heartbeat: String) {
        try ensureDirectory()
        let stop = directory.appendingPathComponent("lid-\(token).stop")
        let heartbeat = directory.appendingPathComponent("lid-\(token).heartbeat")
        try? FileManager.default.removeItem(at: stop)
        try Data().write(to: heartbeat, options: .atomic)
        return (stop.path, heartbeat.path)
    }

    public func touch(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if (try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)) == nil {
            try? Data().write(to: url, options: .atomic)
        }
    }

    public func requestStop(_ path: String) throws {
        try ensureDirectory()
        try Data("stop".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func remove(_ record: LidSessionRecord) {
        try? FileManager.default.removeItem(atPath: record.stopFile)
        try? FileManager.default.removeItem(atPath: record.heartbeatFile)
    }

    public func loadRecord() -> LidSessionRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(LidSessionRecord.self, from: data)
    }

    public func saveRecord(_ record: LidSessionRecord) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    public func clearRecord() {
        try? FileManager.default.removeItem(at: recordURL)
    }
}

// MARK: - 管理員授權執行

/// 透過 /usr/bin/osascript 的 `do shell script … with administrator privileges` 取得一次性的管理員授權。
/// AppleScript 原始碼經由 stdin 傳入（不出現在命令列參數）。`useAdministratorPrivileges = false` 只用於測試整條跳脫流程。
public final class OsascriptRunner: PrivilegedRunner {
    private let useAdministratorPrivileges: Bool

    public init(useAdministratorPrivileges: Bool = true) {
        self.useAdministratorPrivileges = useAdministratorPrivileges
    }

    public func runAsAdministrator(_ command: String, prompt: String) async -> PrivilegedResult {
        let source = AppleScriptQuote.doShellScript(command, administrator: useAdministratorPrivileges, prompt: prompt)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.run(source: source))
            }
        }
    }

    nonisolated private static func run(source: String) -> PrivilegedResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = []
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return .failed(L("無法執行 osascript：\(error.localizedDescription)",
                             "Could not run osascript: \(error.localizedDescription)"))
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let errData = error.fileHandleForReading.readDataToEndOfFile()
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 { return .success(out) }
        // osascript 的錯誤文字依系統語言而定，與 App 語言無關，所以中英文都要判斷。
        if err.contains("-128") || err.localizedCaseInsensitiveContains("cancel") || err.contains("取消") {
            return .cancelled
        }
        return .failed(err.isEmpty ? L("osascript 結束代碼 \(process.terminationStatus)",
                                       "osascript exited with code \(process.terminationStatus)") : err)
    }
}

// MARK: - 立即關閉螢幕

public protocol DisplaySleeping: AnyObject {
    func sleepDisplayNow() -> Result<Void, DisplaySleepError>
}

public struct DisplaySleepError: Error, Equatable, Sendable {
    public let message: String
}

/// `pmset displaysleepnow` 不需要管理員權限，只關閉螢幕，不等於上鎖。
public final class PmsetDisplaySleeper: DisplaySleeping {
    public init() {}
    public func sleepDisplayNow() -> Result<Void, DisplaySleepError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return .failure(DisplaySleepError(message: L("無法執行 pmset：\(error.localizedDescription)",
                                                         "Could not run pmset: \(error.localizedDescription)")))
        }
        return p.terminationStatus == 0 ? .success(()) : .failure(DisplaySleepError(
            message: L("pmset 結束代碼 \(p.terminationStatus)", "pmset exited with code \(p.terminationStatus)")))
    }
}
