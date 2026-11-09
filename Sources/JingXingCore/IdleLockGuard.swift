import Foundation
import Observation

/// 限時防止閒置自動上鎖。
///
/// macOS 的「閒置自動上鎖」是在螢幕保護程式啟動或顯示器因閒置關閉後，依「鎖定畫面」設定要求密碼。
/// 本功能只持有本程式自己的一個 `PreventUserIdleDisplaySleep` IOKit assertion，讓顯示器不因閒置關閉，
/// 因此不會走到那個上鎖時點；不更改密碼、「鎖定畫面」設定或任何系統安全政策。
///
/// - 一定有截止時間（最長 `maxDuration`），到期釋放 assertion，恢復系統原本的閒置行為。
/// - 與「保持清醒」完全獨立：各自持有、各自釋放自己的 assertion。
/// - 不阻擋手動上鎖（Control-Command-Q、選單、合蓋、靜醒的自動上鎖倒數）。工作階段被鎖定時會暫停並釋放
///   assertion，讓鎖定畫面依系統設定關閉顯示器；解鎖後若尚未到期才重新建立。
@MainActor
@Observable
public final class IdleLockGuardController {
    public enum State: Equatable, Sendable {
        case inactive
        /// paused = 工作階段目前已鎖定，暫時沒有持有 assertion。
        case active(startedAt: Date, deadline: Date, paused: Bool)
    }

    public enum EndReason: Equatable, Sendable {
        case manual
        case expired
        case quitting
        /// 解鎖後重新建立 assertion 失敗，已停止，不假裝仍在防止上鎖。
        case resumeFailed
    }

    /// 常用時長（秒）：30 分鐘、1、2、4、8 小時。
    nonisolated public static let presets: [TimeInterval] = [30 * 60, 3600, 2 * 3600, 4 * 3600, 8 * 3600]
    /// 自訂時長上限：避免變成實質上「永遠不上鎖」。
    nonisolated public static let maxDuration: TimeInterval = 24 * 3600
    /// 等同 kIOPMAssertionTypePreventUserIdleDisplaySleep。
    nonisolated public static let assertionType = "PreventUserIdleDisplaySleep"
    /// 會出現在 `pmset -g assertions`；依 App 語言顯示。
    nonisolated public static var assertionReason: String {
        L("靜醒：限時防止閒置自動上鎖", "Awaken: temporarily preventing idle lock")
    }

    public private(set) var state: State = .inactive
    public private(set) var lastError: String?
    public private(set) var lastEndReason: EndReason?

    @ObservationIgnored private var assertionID: AssertionID?
    @ObservationIgnored private let power: PowerAssertionService
    @ObservationIgnored private let clock: TimeSource
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(power: PowerAssertionService, clock: TimeSource) {
        self.power = power
        self.clock = clock
    }

    public var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    public var isPaused: Bool {
        if case .active(_, _, true) = state { return true }
        return false
    }

    /// 測試與狀態顯示用：目前是否真的持有 assertion。
    public var holdsAssertion: Bool { assertionID != nil }

    public var deadline: Date? {
        if case .active(_, let deadline, _) = state { return deadline }
        return nil
    }

    public func remaining() -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(clock.now())) }
    }

    /// 開始，或執行中以新時長從現在重新計時（先建立新 assertion 再釋放舊的，中間不留空檔）。
    /// `sessionLocked` 為 true 時只記錄截止時間，等解鎖後才持有 assertion。
    @discardableResult
    public func start(duration: TimeInterval, sessionLocked: Bool = false) -> Bool {
        guard duration >= 60 else {
            return fail(L("時長至少需要 1 分鐘。", "Duration must be at least one minute."))
        }
        guard duration <= Self.maxDuration else {
            let hours = Int(Self.maxDuration / 3600)
            return fail(L("時長最多 \(hours) 小時。", "Duration can be at most \(hours) hours."))
        }
        let now = clock.now()
        let deadline = now.addingTimeInterval(duration)
        var newID: AssertionID?
        if !sessionLocked {
            switch power.create(type: Self.assertionType, reason: Self.assertionReason, timeout: duration) {
            case .success(let id): newID = id
            case .failure(let error): return fail(error.message)
            }
        }
        if let old = assertionID { _ = power.release(old) }
        assertionID = newID
        let startedAt: Date
        if case .active(let s, _, _) = state { startedAt = s } else { startedAt = now }
        state = .active(startedAt: startedAt, deadline: deadline, paused: sessionLocked)
        lastError = nil
        lastEndReason = nil
        onChange?()
        return true
    }

    public func stop(reason: EndReason = .manual) {
        releaseAssertion(reportErrors: reason == .manual)
        let wasActive = isActive
        state = .inactive
        if wasActive { lastEndReason = reason }
        onChange?()
    }

    /// 依實際時間檢查是否到期（計時器、喚醒後、開啟選單時都可呼叫）。
    public func evaluate() {
        guard let deadline, clock.now() >= deadline else { return }
        stop(reason: .expired)
    }

    /// 工作階段鎖定／解鎖時呼叫（可重複呼叫，同一狀態不會重做）。
    public func setSessionLocked(_ locked: Bool) {
        evaluate()
        guard case .active(let startedAt, let deadline, let paused) = state, paused != locked else { return }
        if locked {
            releaseAssertion(reportErrors: false)
            state = .active(startedAt: startedAt, deadline: deadline, paused: true)
            onChange?()
            return
        }
        let left = deadline.timeIntervalSince(clock.now())
        switch power.create(type: Self.assertionType, reason: Self.assertionReason, timeout: left) {
        case .success(let id):
            assertionID = id
            state = .active(startedAt: startedAt, deadline: deadline, paused: false)
            onChange?()
        case .failure(let error):
            state = .inactive
            lastEndReason = .resumeFailed
            lastError = L("解鎖後無法重新防止閒置上鎖，已停止：\(error.message)。系統會依原本設定閒置上鎖。",
                          "Could not resume idle lock prevention after unlocking, so it was stopped: \(error.message). Idle locking now follows your system settings.")
            onChange?()
        }
    }

    public func clearError() { lastError = nil }

    private func releaseAssertion(reportErrors: Bool) {
        guard let id = assertionID else { return }
        if case .failure(let error) = power.release(id), reportErrors {
            lastError = L("停止時\(error.message)；系統可能已自行釋放。",
                          "While stopping: \(error.message). The system may have already released it.")
        }
        assertionID = nil
    }

    private func fail(_ message: String) -> Bool {
        lastError = message
        onChange?()
        return false
    }
}
