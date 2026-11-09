import AppKit
import Foundation
import Observation
import JingXingCore

/// 時長選項：預設值或自訂。
enum DurationChoice: Hashable {
    case preset(AwakeDuration)
    case custom

    var key: String {
        switch self {
        case .custom: return "custom"
        case .preset(.indefinite): return "indefinite"
        case .preset(.seconds(let s)): return "s\(Int(s))"
        }
    }

    init?(key: String) {
        if key == "custom" { self = .custom; return }
        if key == "indefinite" { self = .preset(.indefinite); return }
        guard key.hasPrefix("s"), let s = Int(key.dropFirst()) else { return nil }
        self = .preset(.seconds(TimeInterval(s)))
    }
}

/// 自動上鎖選項（分鐘；0 代表自訂）。
enum LockChoice: Hashable {
    case minutes(Int)
    case custom

    static let presets: [LockChoice] = [.minutes(5), .minutes(10), .minutes(15), .minutes(30), .minutes(60), .minutes(120)]

    var label: String {
        switch self {
        case .custom: return L("自訂…", "Custom…")
        case .minutes(let m): return TimeText.durationLabel(TimeInterval(m * 60))
        }
    }
}

/// 防止閒置自動上鎖的時長選項。
enum GuardChoice: Hashable {
    case seconds(Int)
    case custom

    static let presets: [GuardChoice] = IdleLockGuardController.presets.map { .seconds(Int($0)) }

    var key: String {
        switch self {
        case .custom: return "custom"
        case .seconds(let s): return "s\(s)"
        }
    }

    init?(key: String) {
        if key == "custom" { self = .custom; return }
        guard key.hasPrefix("s"), let s = Int(key.dropFirst()), s > 0 else { return nil }
        self = .seconds(s)
    }

    var label: String {
        switch self {
        case .custom: return L("自訂時數…", "Custom hours…")
        case .seconds(let s): return TimeText.durationLabel(TimeInterval(s))
        }
    }
}

/// App 層狀態：組合各控制器、偏好設定與計時。只保存偏好，不保存「是否啟用」，因此重新啟動一定是未啟用。
@MainActor
@Observable
final class AppModel {
    let awake: AwakeController
    let lock: LockTimerController
    let lid: LidSleepController
    let idleGuard: IdleLockGuardController
    let quitCoordinator: QuitCoordinator
    private let display: DisplaySleeping
    private let defaults: UserDefaults
    @ObservationIgnored private let sessionLocked: @MainActor () -> Bool

    var guardChoice: GuardChoice {
        didSet { defaults.set(guardChoice.key, forKey: "guardChoice"); applyGuardDurationIfActive() }
    }
    var customGuardHours: Double {
        didSet {
            defaults.set(customGuardHours, forKey: "customGuardHours")
            if guardChoice == .custom { applyGuardDurationIfActive() }
        }
    }

    var durationChoice: DurationChoice {
        didSet { defaults.set(durationChoice.key, forKey: "durationChoice"); applyDurationIfActive() }
    }
    var customHours: Double {
        didSet {
            defaults.set(customHours, forKey: "customHours")
            if durationChoice == .custom { applyDurationIfActive() }
        }
    }
    var lockChoice: LockChoice = .minutes(15) {
        didSet { defaults.set(lockChoiceKey, forKey: "lockChoice") }
    }
    var customLockMinutes: Int {
        didSet { defaults.set(customLockMinutes, forKey: "customLockMinutes") }
    }
    /// 使用者是否希望在保持清醒時也啟用合蓋模式（每次啟動都預設關閉，不保存）。
    private(set) var lidWanted = false
    var displayMessage: String?
    /// 每秒更新，讓 SwiftUI 重新計算剩餘時間（實際剩餘時間一律由截止時間計算）。
    private(set) var now = Date()

    @ObservationIgnored var onStatusChange: (@MainActor () -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lidTicks = 0
    @ObservationIgnored private var lidRanThisSession = false
    @ObservationIgnored private var activity: NSObjectProtocol?

    init(awake: AwakeController, lock: LockTimerController, lid: LidSleepController,
         idleGuard: IdleLockGuardController, clock: TimeSource,
         display: DisplaySleeping, sessionLocked: @escaping @MainActor () -> Bool,
         defaults: UserDefaults = .standard) {
        quitCoordinator = QuitCoordinator(lid: lid, awake: awake, lock: lock, clock: clock, idleGuard: idleGuard)
        self.awake = awake
        self.lock = lock
        self.lid = lid
        self.idleGuard = idleGuard
        self.display = display
        self.sessionLocked = sessionLocked
        self.defaults = defaults
        guardChoice = GuardChoice(key: defaults.string(forKey: "guardChoice") ?? "") ?? .seconds(3600)
        let guardHours = defaults.double(forKey: "customGuardHours")
        customGuardHours = guardHours > 0 ? guardHours : 3
        durationChoice = DurationChoice(key: defaults.string(forKey: "durationChoice") ?? "") ?? .preset(.seconds(3600))
        let hours = defaults.double(forKey: "customHours")
        customHours = hours > 0 ? hours : 3
        let lockMinutes = defaults.integer(forKey: "customLockMinutes")
        customLockMinutes = lockMinutes > 0 ? lockMinutes : 45
        if let saved = defaults.string(forKey: "lockChoice") {
            if saved == "custom" { lockChoice = .custom }
            else if let m = Int(saved), m > 0 { lockChoice = .minutes(m) }
        }
        if let raw = defaults.string(forKey: "mode"), let mode = AwakeMode(rawValue: raw) {
            awake.setMode(mode)
        }
        let notify: @MainActor () -> Void = { [weak self] in self?.statusChanged() }
        awake.onChange = notify
        lock.onChange = notify
        lid.onChange = notify
        idleGuard.onChange = notify
    }

    var selectedGuardSeconds: TimeInterval {
        switch guardChoice {
        case .seconds(let s): return TimeInterval(s)
        case .custom:
            return min(IdleLockGuardController.maxDuration, max(0.25, customGuardHours) * 3600)
        }
    }

    private var lockChoiceKey: String {
        switch lockChoice {
        case .custom: return "custom"
        case .minutes(let m): return String(m)
        }
    }

    var selectedDuration: AwakeDuration {
        switch durationChoice {
        case .preset(let d): return d
        case .custom: return .seconds(max(0.25, customHours) * 3600)
        }
    }

    var selectedLockSeconds: TimeInterval {
        switch lockChoice {
        case .minutes(let m): return TimeInterval(m * 60)
        case .custom: return TimeInterval(max(1, customLockMinutes) * 60)
        }
    }

    // MARK: 生命週期

    func launch() {
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        // 加入 common 模式：選單展開或對話框顯示時也要繼續計時與送心跳，否則看守程序會誤判 App 卡住。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lidTick() }
        }
        // 工作階段鎖定／解鎖時立即暫停或恢復防止閒置上鎖；每秒的 tick 也會以 CGSession 狀態再確認一次。
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let locked = note.name.rawValue == "com.apple.screenIsLocked"
                MainActor.assumeIsolated { self?.idleGuard.setSessionLocked(locked) }
            }
        }
        Task { await lid.recoverOnLaunch() }
    }

    func tick() {
        now = Date()
        let wasActive = awake.isActive
        awake.evaluate()
        if wasActive, !awake.isActive {
            // 保持清醒到時：合蓋模式也一起結束。
            lidWanted = false
            lidRanThisSession = false
            if lid.isEngaged { Task { await lid.stop(reason: .expired) } }
        }
        if lock.isScheduled { Task { await lock.evaluate() } }
        if idleGuard.isActive { idleGuard.setSessionLocked(sessionLocked()) }
        lidTicks += 1
        if lidTicks >= 3 { lidTicks = 0; lidTick() }
    }

    private func lidTick() {
        Task {
            await lid.tick()
            // 合蓋模式因到時／電量／溫度結束時，開關跟著關閉；保持清醒本身仍依自己的設定執行。
            if lidRanThisSession, !lid.isEngaged {
                lidRanThisSession = false
                lidWanted = false
            }
        }
    }

    private func statusChanged() {
        updateActivity()
        onStatusChange?()
    }

    /// 有計時在跑時避免 App Nap 延遲計時器。
    private func updateActivity() {
        let needed = awake.isActive || lock.isScheduled || lid.isEngaged || idleGuard.isActive
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: L("靜醒計時中", "Awaken timer running"))
        } else if !needed, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // MARK: 保持清醒

    func toggleAwake() {
        if awake.isActive { stopAwake() } else { startAwake() }
    }

    func startAwake() {
        guard awake.start(duration: selectedDuration) else { return }
        if lidWanted { Task { await startLidIfNeeded() } }
    }

    func stopAwake() {
        awake.stop(reason: .manual)
        // 每次合蓋模式都需要使用者重新明確開啟。
        lidWanted = false
        lidRanThisSession = false
        if lid.isEngaged { Task { await lid.stop() } }
    }

    private func applyDurationIfActive() {
        guard awake.isActive else { return }
        awake.changeDuration(selectedDuration)
    }

    func setMode(_ mode: AwakeMode) {
        if awake.setMode(mode) { defaults.set(mode.rawValue, forKey: "mode") }
    }

    func sleepDisplayNow() {
        switch display.sleepDisplayNow() {
        case .success: displayMessage = nil
        case .failure(let e): displayMessage = L("無法關閉螢幕：\(e.message)", "Could not turn off the display: \(e.message)")
        }
    }

    // MARK: 合蓋模式

    /// 使用者在確認對話框同意後呼叫。
    func enableLid() async {
        lidWanted = true
        if awake.isActive { await startLidIfNeeded() }
    }

    func disableLid() async {
        lidWanted = false
        lidRanThisSession = false
        if lid.isEngaged { await lid.stop() }
    }

    private func startLidIfNeeded() async {
        guard lidWanted, awake.isActive, !lid.isEngaged else { return }
        let until = awake.deadline ?? Date().addingTimeInterval(LidSleepController.maxDuration)
        let ok = await lid.start(until: until)
        if ok { lidRanThisSession = true } else { lidWanted = false }
        // 等待授權期間使用者可能已停止保持清醒；此時不能留下全系統變更。
        if ok, !lidWanted || !awake.isActive {
            lidRanThisSession = false
            await lid.stop()
        }
    }

    var lidPlannedEnd: Date {
        let cap = Date().addingTimeInterval(LidSleepController.maxDuration)
        guard let d = awake.deadline else { return cap }
        return min(d, cap)
    }

    var isLidWanted: Bool { lidWanted }

    // MARK: 防止閒置自動上鎖（與保持清醒互相獨立）

    func toggleGuard() {
        if idleGuard.isActive { idleGuard.stop(reason: .manual) } else { startGuard() }
    }

    func startGuard() {
        idleGuard.start(duration: selectedGuardSeconds, sessionLocked: sessionLocked())
    }

    private func applyGuardDurationIfActive() {
        guard idleGuard.isActive else { return }
        startGuard()
    }

    // MARK: 自動上鎖

    func scheduleLock() {
        lock.schedule(after: selectedLockSeconds)
    }

    func cancelLock() { lock.cancel() }
}
