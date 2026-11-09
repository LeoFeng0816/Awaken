import Foundation
import Observation

// MARK: - 系統介面（可注入假物件）

public struct ClamshellInfo: Equatable, Sendable {
    public var closed: Bool
    public init(closed: Bool) { self.closed = closed }
}

public enum PowerSourceKind: Equatable, Sendable {
    case ac, battery, unknown
}

/// 對目前供電狀態的判斷。未知不等於接電，一律不視為安全。
public enum PowerAssessment: Equatable, Sendable {
    case safe
    case low(Int)
    case unknown
}

public struct PowerSourceInfo: Equatable, Sendable {
    public var source: PowerSourceKind
    public var batteryPercent: Int?
    public init(source: PowerSourceKind, batteryPercent: Int?) {
        self.source = source
        self.batteryPercent = batteryPercent
    }

    public static let unknown = PowerSourceInfo(source: .unknown, batteryPercent: nil)

    /// 只有「確認接電」或「確認使用電池且讀得到電量」才可能是安全的。
    public func assess(minimumBattery: Int) -> PowerAssessment {
        switch source {
        case .ac:
            return .safe
        case .unknown:
            return .unknown
        case .battery:
            guard let batteryPercent else { return .unknown }
            return batteryPercent < minimumBattery ? .low(batteryPercent) : .safe
        }
    }

    /// 解析 IOPowerSources 的結果。providing 為 nil 或無法辨識時回報未知，電量不合理時回報 nil。
    public static func parse(providing: String?, batteries: [[String: Any]]) -> PowerSourceInfo {
        let source: PowerSourceKind
        switch providing {
        case "AC Power": source = .ac
        case "Battery Power": source = .battery
        default: source = .unknown
        }
        var percent: Int?
        for battery in batteries {
            guard let current = battery["Current Capacity"] as? Int,
                  let max = battery["Max Capacity"] as? Int, max > 0, current >= 0 else { continue }
            let value = Int((Double(current) / Double(max) * 100).rounded())
            if (0...100).contains(value) { percent = value }
        }
        return PowerSourceInfo(source: source, batteryPercent: percent)
    }
}

public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .nominal: return L("正常", "Normal")
        case .fair: return L("略高", "Warm")
        case .serious: return L("偏高", "High")
        case .critical: return L("過熱", "Critical")
        }
    }
}

public struct ProcessSnapshot: Equatable, Sendable {
    public var pid: Int32
    public var startTime: Date
    public var command: String
    public var uid: UInt32
    public init(pid: Int32, startTime: Date, command: String, uid: UInt32) {
        self.pid = pid
        self.startTime = startTime
        self.command = command
        self.uid = uid
    }
}

public protocol LidSystemProbe: AnyObject {
    /// IOPMrootDomain 的 SleepDisabled；nil 代表讀不到（視為不支援）。
    func sleepDisabled() -> Bool?
    /// nil 代表這台 Mac 沒有上蓋（桌上型）。
    func clamshell() -> ClamshellInfo?
    func powerSource() -> PowerSourceInfo
    func thermal() -> ThermalLevel
    func process(_ pid: Int32) -> ProcessSnapshot?
}

/// 本程式自己的工作檔（位於使用者的 Application Support），看守程序只讀取。
public protocol LidSessionFiles: AnyObject {
    func prepare(token: String) throws -> (stop: String, heartbeat: String)
    func touch(_ path: String)
    func requestStop(_ path: String) throws
    func remove(_ record: LidSessionRecord)
    func loadRecord() -> LidSessionRecord?
    func saveRecord(_ record: LidSessionRecord) throws
    func clearRecord()
}

public enum PrivilegedResult: Equatable, Sendable {
    case success(String)
    case cancelled
    case failed(String)
}

@MainActor
public protocol PrivilegedRunner: AnyObject {
    /// 以 macOS 管理員授權執行一段 shell 命令。只在使用者主動操作時呼叫。
    func runAsAdministrator(_ command: String, prompt: String) async -> PrivilegedResult
}

/// 啟用合蓋模式前寫入的日誌，讓異常結束後的下一次啟動能判斷要不要還原。
public struct LidSessionRecord: Codable, Equatable, Sendable {
    public var token: String
    public var appPID: Int32
    public var originalSleepDisabled: Bool
    public var requestedAt: Date
    public var deadline: Date
    public var stopFile: String
    public var heartbeatFile: String
    public var watchdogPID: Int32?
    public var watchdogStart: Date?

    public init(token: String, appPID: Int32, originalSleepDisabled: Bool, requestedAt: Date, deadline: Date,
                stopFile: String, heartbeatFile: String, watchdogPID: Int32? = nil, watchdogStart: Date? = nil) {
        self.token = token
        self.appPID = appPID
        self.originalSleepDisabled = originalSleepDisabled
        self.requestedAt = requestedAt
        self.deadline = deadline
        self.stopFile = stopFile
        self.heartbeatFile = heartbeatFile
        self.watchdogPID = watchdogPID
        self.watchdogStart = watchdogStart
    }
}

// MARK: - 控制器

/// 合蓋後繼續運作（`pmset disablesleep`）。這是全系統設定，會阻止所有睡眠（不只合蓋），需要管理員授權。
/// 一般的 IOKit assertion 無法阻止合蓋睡眠，因此本功能只透過有限時的特權看守程序實作，並盡力還原原本狀態；
/// 看守程序被強制終止或突然斷電時設定可能殘留，由恢復記錄在下次啟動時提示。
@MainActor
@Observable
public final class LidSleepController {
    public enum State: Equatable, Sendable {
        case off
        case unavailable(String)
        case starting
        case active(deadline: Date)
        /// 啟動前 SleepDisabled 已經是 1，且沒有本程式的記錄。無法判斷是誰設定的，本程式不變更也不還原。
        case externallyDisabled
        case stopping
        /// 本程式造成的變更可能仍在；需要使用者授權還原。
        case needsRecovery(String)
    }

    public enum StopReason: Equatable, Sendable {
        case manual, expired, lowBattery, thermal, powerUnknown, quitting

        /// 停止但沒能確認還原時，讓使用者知道為什麼會嘗試停止。
        var attemptMessage: String? {
            switch self {
            case .manual, .quitting, .expired: return nil
            case .lowBattery: return L("電池電量過低，已嘗試停止合蓋模式。", "Battery is low; attempted to stop lid-closed mode.")
            case .thermal: return L("系統溫度偏高，已嘗試停止合蓋模式。", "System temperature is high; attempted to stop lid-closed mode.")
            case .powerUnknown: return L("持續無法確認供電與電量，已嘗試停止合蓋模式。", "Power and battery status remained unavailable; attempted to stop lid-closed mode.")
            }
        }

        var message: String? {
            switch self {
            case .manual, .quitting: return nil
            case .powerUnknown:
                return L("持續讀不到供電或電池電量，無法監測低電量，已停止合蓋模式並還原系統睡眠設定。", "Power or battery status remained unavailable. Lid-closed mode stopped and system sleep was restored.")
            case .expired: return L("合蓋模式已到時，系統睡眠設定已還原。", "Lid-closed mode expired and system sleep was restored.")
            case .lowBattery: return L("電池電量過低，已停止合蓋模式並還原系統睡眠設定。", "Battery is low. Lid-closed mode stopped and system sleep was restored.")
            case .thermal: return L("系統溫度偏高，已停止合蓋模式並還原系統睡眠設定。", "System temperature is high. Lid-closed mode stopped and system sleep was restored.")
            }
        }
    }

    public static let maxDuration: TimeInterval = 12 * 3600
    public static let minimumDuration: TimeInterval = 60
    public static let minimumStartBattery = 20
    public static let stopBattery = 15
    public static let watchdogBattery = 10
    public static let heartbeatInterval: TimeInterval = 10
    /// 使用中供電或電量持續讀不到多久後停止（App 端）；暫時讀取失敗不會中斷合蓋模式。
    public static let powerUnknownGrace: TimeInterval = 30
    public static let watchdogPollInterval: Double = 2
    /// 看守程序容許連續幾次讀不到（約等於 powerUnknownGrace）。
    public static var watchdogPowerReadMaxFailures: Int { Int(powerUnknownGrace / watchdogPollInterval) }
    /// 顯示在 macOS 管理員授權對話框中。
    public static var adminPrompt: String {
        L("靜醒要暫時停用系統睡眠（pmset disablesleep），讓 Mac 合上螢幕後繼續運作。到時、停止或結束靜醒時會嘗試自動還原。",
          "Awaken wants to temporarily disable system sleep (pmset disablesleep) so your Mac keeps running with the lid closed. It will try to restore the setting automatically when time is up, when you stop, or when you quit Awaken.")
    }

    /// 開啟合蓋模式前確認對話框的完整風險說明（全系統影響、時限、電量與溫度監測的限制、可能殘留、替代方案）。
    public static var confirmationText: String {
        if AppLanguage.current.isEnglish {
            return """
            This uses macOS “pmset disablesleep” to temporarily disable sleep for the entire Mac, not just when the lid is closed: neither manual sleep nor idle sleep will happen. An administrator password is required.

            • Active only while Keep Awake is on, for up to 12 hours. When time is up, when you stop, when you quit Awaken, or if Awaken ends unexpectedly, the watchdog will try to restore the original setting.
            • Awaken does its best to monitor battery and system temperature (it tries to restore sleep when the battery drops below \(stopBattery)%, the temperature is high, or the power status cannot be read), but this depends on Awaken and its watchdog running correctly. It cannot guarantee that macOS low-battery or overheating safeguards will intervene. Keep your Mac ventilated and connected to power, and do not put it in a bag.
            • If the watchdog is force-terminated, power is suddenly lost, or another failure occurs, the setting may remain. Reopen Awaken to check and restore it manually.
            • With an external display, power, and a keyboard and mouse, you can instead use Apple’s closed-display mode, which does not change system settings.
            """
        }
        return """
        這會用 macOS 的「pmset disablesleep」暫時停用整台電腦的睡眠，不只合蓋：手動選擇睡眠、閒置睡眠都不會發生。需要輸入管理員密碼。

        • 只在保持清醒期間生效，最長 12 小時；到時、停止、結束靜醒或靜醒異常結束時，看守程序會嘗試還原成原本的設定。
        • 靜醒會盡力監測電量與系統溫度（電量低於 \(stopBattery)%、溫度偏高或讀不到供電狀態時會嘗試還原），但這依賴靜醒與看守程序正常運作，不能保證 macOS 的低電量或過熱防護一定會介入。請保持通風與供電，不要放進包包。
        • 如果看守程序被強制終止、突然斷電或發生其他例外，設定可能殘留。重新開啟靜醒可以檢查並手動還原。
        • 若有外接螢幕、電源與鍵盤滑鼠，也可以改用 Apple 的外接螢幕合蓋模式，不需要更改系統設定。
        """
    }

    public private(set) var state: State = .off
    public private(set) var message: String?
    public private(set) var clamshell: ClamshellInfo?
    public private(set) var power = PowerSourceInfo.unknown
    public private(set) var thermal: ThermalLevel = .nominal

    @ObservationIgnored private let probe: LidSystemProbe
    @ObservationIgnored private let files: LidSessionFiles
    @ObservationIgnored private let runner: PrivilegedRunner
    @ObservationIgnored private let clock: TimeSource
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let appPID: Int32
    @ObservationIgnored private let script: LidWatchdogScript
    @ObservationIgnored private let confirmTimeout: Double
    @ObservationIgnored private let stopTimeout: Double
    @ObservationIgnored private let watchdogTiming: LidWatchdogScript.Timing
    @ObservationIgnored private let pollInterval: Double
    @ObservationIgnored private var record: LidSessionRecord?
    @ObservationIgnored private var lastHeartbeat: Date?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var powerUnknownSince: Date?
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(probe: LidSystemProbe, files: LidSessionFiles, runner: PrivilegedRunner, clock: TimeSource,
                sleeper: Sleeper = TaskSleeper(), appPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                script: LidWatchdogScript = LidWatchdogScript(), confirmTimeout: Double = 8, stopTimeout: Double = 15,
                watchdogTiming: LidWatchdogScript.Timing = .production,
                pollInterval: Double = LidSleepController.watchdogPollInterval) {
        self.probe = probe
        self.files = files
        self.runner = runner
        self.clock = clock
        self.sleeper = sleeper
        self.appPID = appPID
        self.script = script
        self.confirmTimeout = confirmTimeout
        self.stopTimeout = stopTimeout
        self.watchdogTiming = watchdogTiming
        self.pollInterval = pollInterval
    }

    public var isEngaged: Bool {
        switch state {
        case .starting, .active, .stopping: return true
        default: return false
        }
    }

    public var deadline: Date? {
        if case .active(let d) = state { return d }
        return nil
    }

    public func clearMessage() { message = nil; onChange?() }

    /// 目前有無本程式的合蓋工作階段或恢復記錄；沒有時結束 App 不需要任何合蓋處理。
    public var hasSessionToResolve: Bool {
        isEngaged || record != nil || files.loadRecord() != nil
    }

    /// 重新讀取硬體與系統狀態（只讀取，不變更）。
    public func refresh() {
        clamshell = probe.clamshell()
        power = probe.powerSource()
        thermal = probe.thermal()
        switch state {
        case .off, .unavailable, .externallyDisabled:
            state = idleState()
        default:
            break
        }
        onChange?()
    }

    private func idleState() -> State {
        guard clamshell != nil else {
            return .unavailable(L("這台 Mac 沒有可合上的螢幕上蓋。", "This Mac has no closable display lid."))
        }
        guard let disabled = probe.sleepDisabled() else {
            return .unavailable(L("無法讀取系統的 SleepDisabled 狀態，這個 macOS 版本可能不支援，為安全起見停用此功能。", "Cannot read SleepDisabled. This macOS version may not support it; the feature is disabled for safety."))
        }
        return disabled ? .externallyDisabled : .off
    }

    /// 開始前的檢查；回傳 nil 代表可以開始，否則為不能開始的原因。
    public func preflight() -> String? {
        refresh()
        switch state {
        case .off: break
        case .unavailable(let reason): return reason
        case .externallyDisabled:
            return L("系統睡眠目前已是停用狀態（SleepDisabled = 1），靜醒無法判斷是誰設定的，因此不會更動它。", "System sleep is already disabled (SleepDisabled = 1). Awaken cannot determine who changed it and will not modify it.")
        case .needsRecovery(let reason): return reason
        case .starting, .active, .stopping: return L("合蓋模式已在執行。", "Lid-closed mode is already running.")
        }
        switch power.assess(minimumBattery: Self.minimumStartBattery) {
        case .safe:
            break
        case .low(let pct):
            return L("電池只剩 \(pct)%，低於 \(Self.minimumStartBattery)% 時不啟用合蓋模式，請先接上電源。",
                     "Battery is at \(pct)%. Lid-closed mode will not start below \(Self.minimumStartBattery)%. Connect power first.")
        case .unknown:
            return L("無法確認是否接上電源，也讀不到可用的電池電量，因此無法監測低電量，不啟用合蓋模式。請確認電源連接後再試一次。", "Cannot determine power or battery status, so low battery cannot be monitored. Connect power and try again.")
        }
        if thermal >= .serious {
            return L("系統溫度\(thermal.title)，暫時不啟用合蓋模式。",
                     "System temperature is \(thermal.title.lowercased()). Lid-closed mode will not start for now.")
        }
        return nil
    }

    /// 啟用合蓋模式直到指定時間（最長 12 小時）。會要求管理員授權。
    @discardableResult
    public func start(until requested: Date) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }

        if let reason = preflight() {
            message = reason
            onChange?()
            return false
        }
        let now = clock.now()
        let deadline = min(requested, now.addingTimeInterval(Self.maxDuration))
        guard deadline.timeIntervalSince(now) >= Self.minimumDuration else {
            message = L("合蓋模式至少需要 1 分鐘。", "Lid-closed mode requires at least one minute.")
            onChange?()
            return false
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let paths: (stop: String, heartbeat: String)
        do {
            paths = try files.prepare(token: token)
            var rec = LidSessionRecord(token: token, appPID: appPID, originalSleepDisabled: false,
                                       requestedAt: now, deadline: deadline,
                                       stopFile: paths.stop, heartbeatFile: paths.heartbeat)
            // 先寫日誌再做特權操作，任何時間點異常結束都能在下次啟動時判斷。
            try files.saveRecord(rec)
            record = rec
            files.touch(paths.heartbeat)
            lastHeartbeat = now
            state = .starting
            message = nil
            onChange?()

            let params = LidWatchdogScript.Parameters(
                appPID: appPID, deadline: deadline, duration: deadline.timeIntervalSince(now),
                stopFile: paths.stop, heartbeatFile: paths.heartbeat,
                heartbeatMaxAge: 120, pollInterval: pollInterval, minimumBatteryPercent: Self.watchdogBattery,
                powerReadMaxFailures: Self.watchdogPowerReadMaxFailures, timing: watchdogTiming)
            let result = await runner.runAsAdministrator(script.launchCommand(params), prompt: Self.adminPrompt)
            let returnedAt = clock.now()

            switch result {
            case .cancelled:
                discardRecord()
                state = idleState()
                message = L("已取消管理員授權，沒有變更任何系統設定。", "Administrator authorization was cancelled; no system settings were changed.")
                onChange?()
                return false
            case .failed(let error):
                await settleAfterFailure(reason: L("無法啟動合蓋看守程序：\(error)",
                                                   "Could not start the lid-closed watchdog: \(error)"))
                return false
            case .success(let output):
                guard let pid = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
                    await settleAfterFailure(reason: L("看守程序沒有回報 PID（輸出：\(output.prefix(80))）。",
                                                       "The watchdog did not report a PID (output: \(output.prefix(80)))."))
                    return false
                }
                rec.watchdogPID = pid
                record = rec
                try? files.saveRecord(rec)

                // 確認：看守程序存在且 SleepDisabled 已變成 1，才顯示啟用。
                var waited = 0.0
                while waited <= confirmTimeout {
                    if let snap = probe.process(pid), isWatchdog(snap, requestedAt: now, returnedAt: returnedAt),
                       probe.sleepDisabled() == true {
                        rec.watchdogStart = snap.startTime
                        record = rec
                        try? files.saveRecord(rec)
                        state = .active(deadline: deadline)
                        powerUnknownSince = nil
                        onChange?()
                        return true
                    }
                    await sleeper.sleep(seconds: 0.5)
                    waited += 0.5
                }
                await settleAfterFailure(reason: L("看守程序沒有在時限內成功停用系統睡眠。", "The watchdog did not disable system sleep within the time limit."))
                return false
            }
        } catch {
            discardRecord()
            state = idleState()
            message = L("無法建立工作檔：\(error.localizedDescription)",
                        "Could not create session files: \(error.localizedDescription)")
            onChange?()
            return false
        }
    }

    /// 請看守程序結束並確認 SleepDisabled 已還原。
    public func stop(reason: StopReason = .manual) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await performStop(reason: reason)
    }

    private func performStop(reason: StopReason) async {
        guard let rec = record ?? files.loadRecord() else {
            state = idleState()
            onChange?()
            return
        }
        record = rec
        state = .stopping
        onChange?()
        do {
            try files.requestStop(rec.stopFile)
        } catch {
            state = .needsRecovery(L("無法建立停止檔（\(error.localizedDescription)）。看守程序會嘗試到時還原，但結果仍需確認；也可以立即手動還原。",
                                     "Could not create the stop file (\(error.localizedDescription)). The watchdog will try to restore sleep when time is up, but the result still needs to be confirmed. You can also restore it manually now."))
            if let m = reason.attemptMessage { message = m }
            onChange?()
            return
        }
        if await waitUntilRestored(rec) {
            discardRecord()
            state = idleState()
            message = reason.message
        } else {
            state = recoveryState(for: rec)
            if let m = reason.attemptMessage { message = m }
        }
        onChange?()
    }

    /// 每隔數秒呼叫：送心跳、檢查看守程序、截止時間、電量與溫度。
    public func tick() async {
        guard !busy, !terminating else { return }
        let now = clock.now()
        switch state {
        case .active(let deadline):
            guard let rec = record else { return }
            if lastHeartbeat.map({ now.timeIntervalSince($0) >= Self.heartbeatInterval }) ?? true {
                files.touch(rec.heartbeatFile)
                lastHeartbeat = now
            }
            power = probe.powerSource()
            thermal = probe.thermal()
            clamshell = probe.clamshell()
            if !watchdogAlive(rec) {
                if probe.sleepDisabled() == false {
                    discardRecord()
                    state = idleState()
                    message = now >= deadline ? StopReason.expired.message
                        : L("合蓋看守程序已結束（可能因電量過低、讀不到供電狀態、App 心跳中斷或設定被改變），系統睡眠設定已還原。",
                            "The lid-closed watchdog exited (possibly due to low battery, unavailable power status, a missed app heartbeat, or a changed setting). System sleep was restored.")
                } else {
                    state = .needsRecovery(L("合蓋看守程序意外結束，但系統睡眠仍是停用狀態。", "The watchdog exited unexpectedly, but system sleep is still disabled."))
                }
                onChange?()
                return
            }
            let assessment = power.assess(minimumBattery: Self.stopBattery)
            if assessment == .unknown {
                if powerUnknownSince == nil { powerUnknownSince = now }
            } else {
                powerUnknownSince = nil
            }
            if now >= deadline {
                await stop(reason: .expired)
            } else if case .low = assessment {
                await stop(reason: .lowBattery)
            } else if thermal >= .serious {
                await stop(reason: .thermal)
            } else if let since = powerUnknownSince, now.timeIntervalSince(since) >= Self.powerUnknownGrace {
                await stop(reason: .powerUnknown)
            } else {
                onChange?()
            }
        case .needsRecovery:
            // 若看守程序已在稍後完成還原，自動解除警告。
            if let rec = record ?? files.loadRecord(), !watchdogAlive(rec), probe.sleepDisabled() == false {
                discardRecord()
                state = idleState()
                message = L("系統睡眠設定已還原。", "System sleep settings were restored.")
                onChange?()
            }
        default:
            break
        }
    }

    /// App 啟動時呼叫：處理上次未正常結束的合蓋工作階段。不會自動要求密碼。
    public func recoverOnLaunch() async {
        refresh()
        guard let rec = files.loadRecord() else { return }
        record = rec
        if watchdogAlive(rec) {
            // 舊的看守程序發現原 App 已不在就會自行結束；這裡也送出停止要求並等候。
            busy = true
            await performStop(reason: .manual)
            busy = false
            if case .off = state { message = L("已清理上次未結束的合蓋模式，系統睡眠設定已還原。", "The previous unfinished lid-closed session was cleaned up and system sleep was restored.") }
            onChange?()
            return
        }
        switch probe.sleepDisabled() {
        case .some(false):
            discardRecord()
            state = idleState()
        case .some(true) where rec.originalSleepDisabled:
            discardRecord()
            state = idleState()
        case .some(true):
            state = .needsRecovery(L("上次的合蓋模式沒有正常結束，系統睡眠可能仍被停用。", "The previous lid-closed session did not end normally; system sleep may still be disabled."))
        case .none:
            // 讀不到就不能確認已還原，保留記錄。
            state = .needsRecovery(L("上次的合蓋模式沒有正常結束，而且目前讀不到系統睡眠狀態，無法確認是否已還原。", "The previous lid-closed session did not end normally. System sleep status is unavailable, so restoration cannot be confirmed."))
        }
        onChange?()
    }

    /// 使用者按下「立即還原」：要求管理員授權，把 SleepDisabled 設回本程式啟用前的 0。
    public func forceRestore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let rec = record ?? files.loadRecord()
        if let rec { try? files.requestStop(rec.stopFile) }
        guard rec?.originalSleepDisabled == false else {
            // 沒有本程式的變更紀錄，不擅自改動系統設定。
            discardRecord()
            state = idleState()
            message = L("找不到靜醒造成的變更紀錄，沒有更動系統設定。", "No record of an Awaken change was found; system settings were not changed.")
            onChange?()
            return
        }
        let result = await runner.runAsAdministrator("/usr/bin/pmset -a disablesleep 0",
                                                     prompt: L("靜醒要把系統睡眠設定還原為啟用合蓋模式前的狀態（disablesleep 0）。", "Awaken wants to restore the system sleep setting to its state before lid-closed mode (disablesleep 0)."))
        switch result {
        case .cancelled:
            message = L("已取消授權，系統睡眠仍是停用狀態。", "Authorization was cancelled; system sleep is still disabled.")
        case .failed(let error):
            message = L("還原失敗：\(error)", "Restore failed: \(error)")
        case .success:
            if probe.sleepDisabled() == false {
                discardRecord()
                state = idleState()
                message = L("系統睡眠設定已還原。", "System sleep settings were restored.")
            } else {
                message = L("已執行還原命令，但系統仍回報睡眠停用。請在「終端機」執行 sudo pmset -a disablesleep 0。", "The restore command ran, but system sleep is still reported as disabled. Run sudo pmset -a disablesleep 0 in Terminal.")
            }
        }
        onChange?()
    }

    /// 結束 App 前呼叫，回報是否確認已還原。未確認時保留恢復記錄，由呼叫端詢問使用者。
    public func prepareForTermination() async -> LidTerminationOutcome {
        guard hasSessionToResolve else { return .notInvolved }
        terminating = true
        defer { terminating = false }
        let rec = record ?? files.loadRecord()
        // 看守程序已不在且仍是停用狀態時，等待也不會改變結果。
        let hopeless = state != .starting && rec.map { !watchdogAlive($0) && probe.sleepDisabled() != false } ?? false
        if let rec, hopeless {
            record = rec
            if case .needsRecovery = state {} else { state = recoveryState(for: rec) }
            onChange?()
        } else {
            await performStop(reason: .quitting)
        }
        guard case .needsRecovery(let reason) = state else { return .restored }
        let running = (record ?? files.loadRecord()).map(watchdogAlive) ?? false
        let latest = (record ?? files.loadRecord())?.deadline ?? clock.now()
        return .unresolved(reason: reason, watchdogRunning: running, latestRestore: latest)
    }

    // MARK: - 內部

    private func isWatchdog(_ snap: ProcessSnapshot, requestedAt: Date, returnedAt: Date) -> Bool {
        snap.uid == 0 && snap.command == "bash" &&
            snap.startTime >= requestedAt.addingTimeInterval(-2) &&
            snap.startTime <= returnedAt.addingTimeInterval(2)
    }

    /// 以 PID + 啟動時間確認仍是同一個看守程序，避免 PID 被其他程序重複使用而誤判。
    private func watchdogAlive(_ rec: LidSessionRecord) -> Bool {
        guard let pid = rec.watchdogPID, let snap = probe.process(pid) else { return false }
        guard snap.uid == 0, snap.command == "bash" else { return false }
        if let start = rec.watchdogStart {
            return abs(snap.startTime.timeIntervalSince(start)) < 1.5
        }
        return snap.startTime >= rec.requestedAt.addingTimeInterval(-2)
    }

    private func waitUntilRestored(_ rec: LidSessionRecord) async -> Bool {
        var waited = 0.0
        while waited <= stopTimeout {
            if !watchdogAlive(rec), rec.originalSleepDisabled || probe.sleepDisabled() == false {
                return true
            }
            await sleeper.sleep(seconds: 0.5)
            waited += 0.5
        }
        return false
    }

    private func settleAfterFailure(reason: String) async {
        guard let rec = record else {
            state = idleState()
            message = reason
            onChange?()
            return
        }
        try? files.requestStop(rec.stopFile)
        if await waitUntilRestored(rec) {
            discardRecord()
            state = idleState()
            message = L("\(reason)系統睡眠設定維持原狀。", "\(reason) System sleep settings were left unchanged.")
        } else {
            state = recoveryState(for: rec)
            message = reason
        }
        onChange?()
    }

    private func recoveryState(for rec: LidSessionRecord) -> State {
        if watchdogAlive(rec) {
            return .needsRecovery(L("看守程序尚未結束，會繼續嘗試還原，但時間和結果無法保證；也可以立即手動還原。", "The watchdog is still running and will keep trying to restore sleep, but timing and success are not guaranteed. You can also restore it manually now."))
        }
        return .needsRecovery(L("無法確認系統睡眠已還原，可能仍是停用狀態，需要還原。", "System sleep restoration cannot be confirmed; it may still be disabled and needs to be restored."))
    }

    private func discardRecord() {
        if let rec = record ?? files.loadRecord() { files.remove(rec) }
        files.clearRecord()
        record = nil
        lastHeartbeat = nil
        powerUnknownSince = nil
    }
}
