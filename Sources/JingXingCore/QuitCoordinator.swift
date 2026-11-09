import Foundation

/// 結束 App 前合蓋模式的處理結果。
public enum LidTerminationOutcome: Equatable, Sendable {
    /// 沒有合蓋工作階段，也沒有恢復記錄。
    case notInvolved
    /// 已確認還原。
    case restored
    /// 無法確認還原；恢復記錄會保留。
    case unresolved(reason: String, watchdogRunning: Bool, latestRestore: Date)
}

public struct LidQuitPrompt: Equatable, Sendable {
    public let title: String
    public let body: String
    public let cancelTitle: String
    public let quitTitle: String

    public init(reason: String, watchdogRunning: Bool, latestRestore: Date, now: Date) {
        title = L("系統睡眠設定尚未確認還原", "System sleep restoration could not be confirmed")
        let next: String
        if watchdogRunning {
            next = L("如果仍然結束，看守程序會繼續嘗試還原，但時間和結果無法保證。重新開啟靜醒後可以再次確認。", "If you quit, the watchdog will continue trying to restore sleep, but its timing and success cannot be guaranteed. Reopen Awaken to check again.")
        } else {
            next = L("看守程序已不在執行。如果仍然結束，系統睡眠可能持續停用，不會自動恢復。", "The watchdog is no longer running. If you quit, system sleep may remain disabled and will not be restored automatically.")
        }
        let advice = L("建議先取消結束，並在靜醒面板按「立即還原系統睡眠」。若仍然結束，重新開啟靜醒可以再次檢查並還原，也可以在「終端機」執行：",
                       "We recommend cancelling the quit and clicking “Restore System Sleep Now” in the Awaken panel. If you quit anyway, reopen Awaken to check and restore again, or run this in Terminal:")
        body = """
        \(reason)

        \(next)

        \(advice)
        sudo pmset -a disablesleep 0
        """
        cancelTitle = L("取消結束", "Cancel Quit")
        quitTitle = L("仍然結束", "Quit Anyway")
    }
}

/// 結束流程的決策：只有確定要結束時才釋放保持清醒與上鎖倒數；
/// 合蓋設定未確認還原時交由使用者決定，且無論選擇為何都保留恢復記錄。
@MainActor
public final class QuitCoordinator {
    public enum Decision: Equatable, Sendable {
        case cancelQuit
        case quitAnyway
    }

    private let lid: LidSleepController
    private let awake: AwakeController
    private let lock: LockTimerController
    private let clock: TimeSource
    private let idleGuard: IdleLockGuardController?

    public init(lid: LidSleepController, awake: AwakeController, lock: LockTimerController, clock: TimeSource,
                idleGuard: IdleLockGuardController? = nil) {
        self.lid = lid
        self.awake = awake
        self.lock = lock
        self.clock = clock
        self.idleGuard = idleGuard
    }

    /// 未使用合蓋模式時直接釋放資源並回傳 true，不需要對話框或等待。
    public func quitImmediatelyIfPossible() -> Bool {
        guard !lid.hasSessionToResolve else { return false }
        release()
        return true
    }

    /// 回傳是否應結束 App。
    public func run(ask: @MainActor (LidQuitPrompt) async -> Decision) async -> Bool {
        switch await lid.prepareForTermination() {
        case .notInvolved, .restored:
            release()
            return true
        case .unresolved(let reason, let watchdogRunning, let latestRestore):
            let prompt = LidQuitPrompt(reason: reason, watchdogRunning: watchdogRunning,
                                       latestRestore: latestRestore, now: clock.now())
            switch await ask(prompt) {
            case .cancelQuit:
                return false
            case .quitAnyway:
                release()
                return true
            }
        }
    }

    private func release() {
        awake.stop(reason: .quitting)
        idleGuard?.stop(reason: .quitting)
        lock.cancel()
    }
}
