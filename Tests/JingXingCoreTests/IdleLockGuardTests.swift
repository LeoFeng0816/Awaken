import Foundation
import IOKit.pwr_mgt
import Testing
@testable import JingXingCore

@MainActor @Suite(.language(.traditionalChinese))
struct IdleLockGuardTests {
    @Test func presetsInclude8Hours() {
        #expect(IdleLockGuardController.presets.contains(8 * 3600))
        #expect(IdleLockGuardController.presets.allSatisfy { $0 <= IdleLockGuardController.maxDuration })
    }

    @Test func startsInactiveAndHoldsNothing() {
        let power = FakePower()
        let g = IdleLockGuardController(power: power, clock: FakeClock())
        #expect(g.state == .inactive)
        #expect(power.held.isEmpty)
    }

    @Test func eightHoursHoldsDisplayAssertionAndExpiresByDeadline() {
        let clock = FakeClock(), power = FakePower()
        let g = IdleLockGuardController(power: power, clock: clock)
        #expect(g.start(duration: 8 * 3600))
        #expect(power.held.count == 1)
        #expect(power.held[0].type == "PreventUserIdleDisplaySleep")
        #expect(power.held[0].timeout == TimeInterval(8 * 3600))
        #expect(g.deadline == clock.now().addingTimeInterval(8 * 3600))
        clock.advance(8 * 3600 - 1)
        g.evaluate()
        #expect(g.isActive)
        #expect(g.remaining() == 1)
        clock.advance(1)
        g.evaluate()
        #expect(g.state == .inactive)
        #expect(g.lastEndReason == .expired)
        #expect(power.held.isEmpty)
    }

    @Test func manualStopReleasesOnlyOwnAssertion() {
        let clock = FakeClock(), power = FakePower()
        let awake = AwakeController(power: power, clock: clock)
        let g = IdleLockGuardController(power: power, clock: clock)
        awake.start(duration: .indefinite)
        g.start(duration: 3600)
        #expect(power.held.count == 2)
        g.stop()
        #expect(g.lastEndReason == .manual)
        #expect(power.held.count == 1)
        #expect(awake.isActive)
    }

    @Test func independentOfAwake() {
        let clock = FakeClock(), power = FakePower()
        let awake = AwakeController(power: power, clock: clock)
        let g = IdleLockGuardController(power: power, clock: clock)
        g.start(duration: 2 * 3600)
        awake.start(duration: .seconds(600))
        clock.advance(600)
        awake.evaluate()
        g.evaluate()
        #expect(!awake.isActive)
        #expect(g.isActive)
        #expect(power.held.count == 1)
        #expect(power.held[0].type == IdleLockGuardController.assertionType)
        // 停止保持清醒或切換模式不影響防止上鎖。
        awake.setMode(.systemOnly)
        #expect(g.holdsAssertion)
    }

    @Test func doesNotPreventScheduledOrManualLock() async {
        let clock = FakeClock(), power = FakePower(), locker = FakeLocker()
        let g = IdleLockGuardController(power: power, clock: clock)
        let t = LockTimerController(locker: locker, clock: clock)
        g.start(duration: 8 * 3600)
        #expect(t.schedule(after: 60))
        clock.advance(60)
        await t.evaluate()
        #expect(locker.lockCalls == 1)
        // 上鎖後暫停並釋放 assertion，讓鎖定畫面依系統設定關閉顯示器。
        g.setSessionLocked(true)
        #expect(g.isPaused)
        #expect(power.held.isEmpty)
        #expect(g.isActive)
    }

    @Test func resumesAfterUnlockWithRemainingTimeout() {
        let clock = FakeClock(), power = FakePower()
        let g = IdleLockGuardController(power: power, clock: clock)
        g.start(duration: 3600)
        let deadline = g.deadline
        g.setSessionLocked(true)
        g.setSessionLocked(true) // 重複呼叫不重做
        clock.advance(600)
        g.setSessionLocked(false)
        #expect(!g.isPaused)
        #expect(g.deadline == deadline)
        #expect(power.held.count == 1)
        #expect(power.held[0].timeout == 3000)
        g.setSessionLocked(false)
        #expect(power.held.count == 1)
    }

    @Test func expiresWhileLockedDoesNotReacquire() {
        let clock = FakeClock(), power = FakePower()
        let g = IdleLockGuardController(power: power, clock: clock)
        g.start(duration: 1800)
        g.setSessionLocked(true)
        clock.advance(1800)
        g.setSessionLocked(false)
        #expect(g.state == .inactive)
        #expect(g.lastEndReason == .expired)
        #expect(power.held.isEmpty)
    }

    @Test func resumeFailureStopsHonestly() {
        let clock = FakeClock(), power = FakePower()
        let g = IdleLockGuardController(power: power, clock: clock)
        g.start(duration: 3600)
        g.setSessionLocked(true)
        power.failCreate = true
        g.setSessionLocked(false)
        #expect(g.state == .inactive)
        #expect(g.lastEndReason == .resumeFailed)
        #expect(g.lastError?.contains("IOReturn") == true)
    }

    @Test func startWhileLockedWaitsForUnlock() {
        let clock = FakeClock(), power = FakePower()
        let g = IdleLockGuardController(power: power, clock: clock)
        #expect(g.start(duration: 3600, sessionLocked: true))
        #expect(g.isPaused)
        #expect(power.held.isEmpty)
        g.setSessionLocked(false)
        #expect(power.held.count == 1)
    }

    @Test func createFailureDoesNotPretendActive() {
        let power = FakePower()
        power.failCreate = true
        let g = IdleLockGuardController(power: power, clock: FakeClock())
        #expect(!g.start(duration: 3600))
        #expect(g.state == .inactive)
        #expect(g.lastError != nil)
    }

    @Test func rejectsOutOfRangeDurations() {
        let power = FakePower()
        let g = IdleLockGuardController(power: power, clock: FakeClock())
        #expect(!g.start(duration: 0))
        #expect(!g.start(duration: IdleLockGuardController.maxDuration + 1))
        #expect(power.createCount == 0)
        #expect(g.state == .inactive)
    }

    @Test func restartSwapsWithoutGapAndKeepsOldOnFailure() {
        let clock = FakeClock(), power = FakePower()
        let g = IdleLockGuardController(power: power, clock: clock)
        g.start(duration: 3600)
        clock.advance(1000)
        #expect(g.start(duration: 8 * 3600))
        #expect(power.held.count == 1)
        #expect(g.remaining() == TimeInterval(8 * 3600))
        let deadline = g.deadline
        power.failCreate = true
        #expect(!g.start(duration: 3600))
        #expect(g.deadline == deadline)
        #expect(power.held.count == 1)
        #expect(g.isActive)
    }

    @Test func quitReleasesGuard() async {
        let clock = FakeClock(), power = FakePower()
        let awake = AwakeController(power: power, clock: clock)
        let lock = LockTimerController(locker: FakeLocker(), clock: clock)
        let lid = LidSleepController(probe: FakeProbe(), files: MemoryFiles(), runner: FakeRunner(), clock: clock)
        let g = IdleLockGuardController(power: power, clock: clock)
        let quit = QuitCoordinator(lid: lid, awake: awake, lock: lock, clock: clock, idleGuard: g)
        g.start(duration: 3600)
        #expect(quit.quitImmediatelyIfPossible())
        #expect(g.lastEndReason == .quitting)
        #expect(power.held.isEmpty)
    }
}

/// 真正的 IOKit：只建立並立刻釋放本測試程序自己的 assertion，不改任何永久設定。
@MainActor @Suite(.language(.traditionalChinese))
struct IdleLockGuardIOKitTests {
    private func ownGuardAssertions() -> [String] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let map = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let mine = map[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.filter { ($0["AssertName"] as? String) == IdleLockGuardController.assertionReason }
            .compactMap { $0["AssertType"] as? String }
    }

    @Test func realAssertionCreatedAndReleased() {
        let g = IdleLockGuardController(power: IOKitPowerAssertionService(), clock: SystemTimeSource())
        #expect(g.start(duration: 120))
        #expect(ownGuardAssertions() == ["PreventUserIdleDisplaySleep"])
        g.setSessionLocked(true)
        #expect(ownGuardAssertions().isEmpty)
        g.setSessionLocked(false)
        #expect(ownGuardAssertions() == ["PreventUserIdleDisplaySleep"])
        g.stop()
        #expect(ownGuardAssertions().isEmpty)
    }
}
