import Foundation
import Observation

/// 管理「保持清醒」：持有至多一個本程式自己的 IOKit assertion，依截止時間到期釋放。
@MainActor
@Observable
public final class AwakeController {
    public enum State: Equatable, Sendable {
        case inactive
        case active(startedAt: Date, deadline: Date?)
    }

    public enum EndReason: Equatable, Sendable {
        case manual
        case expired
        case quitting
    }

    public private(set) var state: State = .inactive
    public private(set) var mode: AwakeMode
    public private(set) var lastError: String?
    public private(set) var lastEndReason: EndReason?

    @ObservationIgnored private var assertionID: AssertionID?
    @ObservationIgnored private let power: PowerAssertionService
    @ObservationIgnored private let clock: TimeSource
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    /// 會出現在 `pmset -g assertions`；依 App 語言顯示。
    nonisolated public static var assertionReason: String {
        L("靜醒：使用者要求保持清醒", "Awaken: Keep Awake requested by user")
    }

    public init(power: PowerAssertionService, clock: TimeSource, mode: AwakeMode = .systemAndDisplay) {
        self.power = power
        self.clock = clock
        self.mode = mode
    }

    public var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    public var deadline: Date? {
        if case .active(_, let deadline) = state { return deadline }
        return nil
    }

    public func remaining() -> TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(clock.now()))
    }

    /// 開始保持清醒；若已在執行，等同以新時長從現在重新計時。
    @discardableResult
    public func start(duration: AwakeDuration) -> Bool {
        let now = clock.now()
        let deadline = duration.interval.map { now.addingTimeInterval($0) }
        guard let newID = makeAssertion(mode: mode, deadline: deadline, now: now) else { return false }
        if let old = assertionID { _ = power.release(old) }
        assertionID = newID
        let startedAt: Date
        if case .active(let s, _) = state { startedAt = s } else { startedAt = now }
        state = .active(startedAt: startedAt, deadline: deadline)
        lastError = nil
        lastEndReason = nil
        onChange?()
        return true
    }

    /// 執行中調整時長：從現在起重新計算截止時間。未執行時不做事。
    @discardableResult
    public func changeDuration(_ duration: AwakeDuration) -> Bool {
        guard isActive else { return true }
        return start(duration: duration)
    }

    /// 切換模式。執行中時先建立新 assertion 再釋放舊的，中間不會有空檔；失敗時保留原模式。
    @discardableResult
    public func setMode(_ newMode: AwakeMode) -> Bool {
        guard newMode != mode else { return true }
        guard case .active(let startedAt, let deadline) = state else {
            mode = newMode
            onChange?()
            return true
        }
        guard let newID = makeAssertion(mode: newMode, deadline: deadline, now: clock.now()) else { return false }
        if let old = assertionID { _ = power.release(old) }
        assertionID = newID
        mode = newMode
        state = .active(startedAt: startedAt, deadline: deadline)
        lastError = nil
        onChange?()
        return true
    }

    public func stop(reason: EndReason = .manual) {
        if let id = assertionID {
            if case .failure(let error) = power.release(id), reason == .manual {
                // assertion 可能已因系統端逾時被釋放；只記錄，不影響結果。
                lastError = L("停止時\(error.message)；系統可能已自行釋放。",
                              "While stopping: \(error.message). The system may have already released it.")
            }
        }
        assertionID = nil
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

    public func clearError() { lastError = nil }

    private func makeAssertion(mode: AwakeMode, deadline: Date?, now: Date) -> AssertionID? {
        if let deadline, deadline <= now {
            lastError = L("時長必須大於 0。", "Duration must be greater than zero.")
            return nil
        }
        let timeout = deadline.map { $0.timeIntervalSince(now) }
        switch power.create(type: mode.assertionType, reason: Self.assertionReason, timeout: timeout) {
        case .success(let id):
            return id
        case .failure(let error):
            lastError = error.message
            onChange?()
            return nil
        }
    }
}
