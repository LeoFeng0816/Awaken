import Foundation
import Observation
import CoreGraphics
import ApplicationServices

public enum LockReadiness: Equatable, Sendable {
    /// 可以上鎖；method 為將使用的方式說明。
    case ready(method: String)
    /// 需要「輔助使用」授權才能模擬 Control-Command-Q。
    case needsAccessibility
    case unavailable(String)
}

public enum LockOutcome: Equatable, Sendable {
    case locked(method: String)
    case failed(String)
}

/// 上鎖的抽象，測試時以替身取代，開發期間不會真的鎖定電腦。
@MainActor
public protocol ScreenLocking: AnyObject {
    func readiness() -> LockReadiness
    /// 只在使用者主動設定自動上鎖時呼叫；可能顯示系統授權提示。
    func requestAccess()
    func lockNow() async -> LockOutcome
}

/// 自動上鎖倒數。與保持清醒互相獨立：上鎖不會停止保持清醒，保持清醒也不會延後上鎖。
@MainActor
@Observable
public final class LockTimerController {
    public enum State: Equatable, Sendable {
        case idle
        case scheduled(deadline: Date, duration: TimeInterval)
        case locking
        case locked(at: Date, method: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    @ObservationIgnored private let locker: ScreenLocking
    @ObservationIgnored private let clock: TimeSource
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(locker: ScreenLocking, clock: TimeSource) {
        self.locker = locker
        self.clock = clock
    }

    public var deadline: Date? {
        if case .scheduled(let d, _) = state { return d }
        return nil
    }

    public var isScheduled: Bool { deadline != nil }

    public func remaining() -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(clock.now())) }
    }

    /// 設定或調整倒數：一律從現在起算。權限不足時不排程，並回報原因。
    @discardableResult
    public func schedule(after seconds: TimeInterval) -> Bool {
        guard seconds >= 1 else {
            state = .failed(L("上鎖時間必須大於 0。", "Lock delay must be greater than zero."))
            onChange?()
            return false
        }
        if state == .locking { return false }
        switch locker.readiness() {
        case .ready:
            state = .scheduled(deadline: clock.now().addingTimeInterval(seconds), duration: seconds)
            onChange?()
            return true
        case .needsAccessibility:
            locker.requestAccess()
            state = .failed(L("需要在「系統設定 › 隱私權與安全性 › 輔助使用」允許「靜醒」，才能送出 Control-Command-Q 上鎖。授權後請再設定一次。", "To send Control-Command-Q, allow Awaken in System Settings › Privacy & Security › Accessibility. After granting access, schedule the lock again."))
            onChange?()
            return false
        case .unavailable(let reason):
            state = .failed(reason)
            onChange?()
            return false
        }
    }

    public func cancel() {
        guard state != .locking else { return }
        state = .idle
        onChange?()
    }

    /// 清除已完成或失敗的訊息。
    public func dismiss() {
        switch state {
        case .locked, .failed: state = .idle; onChange?()
        default: break
        }
    }

    /// 到期就上鎖；結果依系統實際回報，不假裝成功。
    public func evaluate() async {
        guard case .scheduled(let deadline, _) = state, clock.now() >= deadline else { return }
        state = .locking
        onChange?()
        let outcome = await locker.lockNow()
        switch outcome {
        case .locked(let method):
            state = .locked(at: clock.now(), method: method)
        case .failed(let reason):
            state = .failed(L("自動上鎖失敗：\(reason)", "Scheduled lock failed: \(reason)"))
        }
        onChange?()
    }
}

/// 真正的上鎖實作：
/// 1. 優先呼叫系統 login.framework 的 SACLockScreenImmediate（與控制中心「鎖定螢幕」相同的機制；為未公開 API，以 dlsym 動態取得，找不到就不使用）。
/// 2. 退而使用 Apple 文件列出的 Control-Command-Q 快捷鍵（需要「輔助使用」授權，且快捷鍵可能被使用者停用或改掉）。
/// 每次都以 CGSessionCopyCurrentDictionary 的 CGSSessionScreenIsLocked 確認確實鎖定。
@MainActor
public final class SystemScreenLocker: ScreenLocking {
    private typealias LockFunction = @convention(c) () -> Int32
    private let sacLock: LockFunction?
    private let sleeper: Sleeper

    public init(sleeper: Sleeper = TaskSleeper()) {
        self.sleeper = sleeper
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "SACLockScreenImmediate") {
            sacLock = unsafeBitCast(symbol, to: LockFunction.self)
        } else {
            sacLock = nil
        }
    }

    public static func isSessionLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Int { return locked != 0 }
        return false
    }

    public var hasSystemLockFunction: Bool { sacLock != nil }

    public func readiness() -> LockReadiness {
        if sacLock != nil { return .ready(method: L("系統鎖定螢幕", "System screen lock")) }
        if CGPreflightPostEventAccess() { return .ready(method: "Control-Command-Q") }
        return .needsAccessibility
    }

    public func requestAccess() {
        if sacLock == nil { _ = CGRequestPostEventAccess() }
    }

    public func lockNow() async -> LockOutcome {
        if Self.isSessionLocked() { return .locked(method: L("已在鎖定狀態", "Already locked")) }
        var notes: [String] = []
        if let sacLock {
            _ = sacLock()
            if await waitForLock() { return .locked(method: L("系統鎖定螢幕", "System screen lock")) }
            notes.append(L("系統鎖定函式沒有讓工作階段進入鎖定", "The system lock function did not lock the session"))
        }
        if CGPreflightPostEventAccess() {
            if postLockShortcut(), await waitForLock() {
                return .locked(method: "Control-Command-Q")
            }
            notes.append(L("已送出 Control-Command-Q，但系統未鎖定（快捷鍵可能被停用或改掉）", "Control-Command-Q was sent, but the session did not lock; the shortcut may be disabled or changed"))
        } else {
            notes.append(L("未取得「輔助使用」授權，無法送出 Control-Command-Q", "Accessibility permission was not granted; cannot send Control-Command-Q"))
        }
        return .failed(notes.joined(separator: L("；", "; ")))
    }

    private func waitForLock() async -> Bool {
        for _ in 0..<15 {
            await sleeper.sleep(seconds: 0.2)
            if Self.isSessionLocked() { return true }
        }
        return false
    }

    private func postLockShortcut() -> Bool {
        let qKey: CGKeyCode = 12
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: false) else {
            return false
        }
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
