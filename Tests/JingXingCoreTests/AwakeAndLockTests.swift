import Foundation
import Testing
@testable import JingXingCore

@MainActor @Suite(.language(.traditionalChinese))
struct AwakeControllerTests {
    @Test func startsInactiveAndHoldsNothing() {
        let power = FakePower()
        let c = AwakeController(power: power, clock: FakeClock())
        #expect(c.state == .inactive)
        #expect(power.held.isEmpty)
    }

    @Test func expiresByDeadlineNotTimerCount() {
        let clock = FakeClock(), power = FakePower()
        let c = AwakeController(power: power, clock: clock)
        #expect(c.start(duration: .seconds(3600)))
        #expect(power.held.count == 1)
        #expect(power.held[0].type == "PreventUserIdleDisplaySleep")
        #expect(power.held[0].timeout == 3600)
        clock.advance(3599)
        c.evaluate()
        #expect(c.isActive)
        #expect(c.remaining() == 1)
        // 不管中間呼叫幾次，只看實際時間。
        clock.advance(10)
        c.evaluate()
        #expect(c.state == .inactive)
        #expect(c.lastEndReason == .expired)
        #expect(power.held.isEmpty)
    }

    @Test func manualStopReleasesOwnAssertion() {
        let power = FakePower()
        let c = AwakeController(power: power, clock: FakeClock())
        c.start(duration: .indefinite)
        #expect(c.deadline == nil)
        #expect(power.held[0].timeout == nil)
        c.stop()
        #expect(power.held.isEmpty)
        #expect(c.lastEndReason == .manual)
    }

    @Test func switchingModeSwapsWithoutGap() {
        let clock = FakeClock(), power = FakePower()
        let c = AwakeController(power: power, clock: clock)
        c.start(duration: .seconds(7200))
        let deadline = c.deadline
        #expect(c.setMode(.systemOnly))
        #expect(power.held.count == 1)
        #expect(power.held[0].type == "PreventUserIdleSystemSleep")
        #expect(c.deadline == deadline)
        #expect(c.mode == .systemOnly)
    }

    @Test func modeSwitchFailureKeepsOldAssertion() {
        let power = FakePower()
        let c = AwakeController(power: power, clock: FakeClock())
        c.start(duration: .seconds(600))
        power.failCreate = true
        #expect(!c.setMode(.systemOnly))
        #expect(c.mode == .systemAndDisplay)
        #expect(power.held.count == 1)
        #expect(power.held[0].type == "PreventUserIdleDisplaySleep")
        #expect(c.lastError != nil)
        #expect(c.isActive)
    }

    @Test func createFailureDoesNotPretendActive() {
        let power = FakePower()
        power.failCreate = true
        let c = AwakeController(power: power, clock: FakeClock())
        #expect(!c.start(duration: .seconds(600)))
        #expect(c.state == .inactive)
        #expect(c.lastError?.contains("IOReturn") == true)
    }

    @Test func changingDurationRestartsFromNow() {
        let clock = FakeClock(), power = FakePower()
        let c = AwakeController(power: power, clock: clock)
        c.start(duration: .seconds(1800))
        clock.advance(1000)
        c.changeDuration(.seconds(3600))
        #expect(c.remaining() == 3600)
        #expect(power.held.count == 1)
        c.changeDuration(.indefinite)
        #expect(c.deadline == nil)
        #expect(power.held.count == 1)
    }

    @Test func changingDurationWhileInactiveDoesNothing() {
        let power = FakePower()
        let c = AwakeController(power: power, clock: FakeClock())
        c.changeDuration(.seconds(60))
        #expect(c.state == .inactive)
        #expect(power.createCount == 0)
    }
}

@MainActor @Suite(.language(.traditionalChinese))
struct LockTimerTests {
    @Test func locksOnlyAfterDeadline() async {
        let clock = FakeClock(), locker = FakeLocker()
        let t = LockTimerController(locker: locker, clock: clock)
        #expect(t.schedule(after: 900))
        clock.advance(899)
        await t.evaluate()
        #expect(locker.lockCalls == 0)
        #expect(t.remaining() == 1)
        clock.advance(1)
        await t.evaluate()
        #expect(locker.lockCalls == 1)
        if case .locked = t.state {} else { Issue.record("應為已上鎖：\(t.state)") }
        await t.evaluate()
        #expect(locker.lockCalls == 1)
    }

    @Test func cancelPreventsLock() async {
        let clock = FakeClock(), locker = FakeLocker()
        let t = LockTimerController(locker: locker, clock: clock)
        t.schedule(after: 60)
        t.cancel()
        clock.advance(120)
        await t.evaluate()
        #expect(locker.lockCalls == 0)
        #expect(t.state == .idle)
    }

    @Test func rescheduleCountsFromNow() async {
        let clock = FakeClock(), locker = FakeLocker()
        let t = LockTimerController(locker: locker, clock: clock)
        t.schedule(after: 60)
        clock.advance(50)
        t.schedule(after: 300)
        clock.advance(20)
        await t.evaluate()
        #expect(locker.lockCalls == 0)
        #expect(t.remaining() == 280)
    }

    @Test func missingPermissionIsReportedNotScheduled() {
        let locker = FakeLocker()
        locker.readinessValue = .needsAccessibility
        let t = LockTimerController(locker: locker, clock: FakeClock())
        #expect(!t.schedule(after: 60))
        #expect(locker.accessRequests == 1)
        if case .failed(let m) = t.state { #expect(m.contains("輔助使用")) } else { Issue.record("應為失敗") }
    }

    @Test func lockFailureIsNotReportedAsSuccess() async {
        let clock = FakeClock(), locker = FakeLocker()
        locker.outcome = .failed("快捷鍵被停用")
        let t = LockTimerController(locker: locker, clock: clock)
        t.schedule(after: 10)
        clock.advance(10)
        await t.evaluate()
        if case .failed(let m) = t.state { #expect(m.contains("快捷鍵被停用")) } else { Issue.record("應為失敗：\(t.state)") }
    }

    @Test func lockTimerIsIndependentOfAwake() async {
        let clock = FakeClock(), locker = FakeLocker(), power = FakePower()
        let awake = AwakeController(power: power, clock: clock)
        let t = LockTimerController(locker: locker, clock: clock)
        awake.start(duration: .indefinite)
        t.schedule(after: 60)
        clock.advance(60)
        await t.evaluate()
        awake.evaluate()
        #expect(locker.lockCalls == 1)
        #expect(awake.isActive)
        #expect(power.held.count == 1)
    }
}

@Suite(.language(.traditionalChinese))
struct TimeTextTests {
    @Test func labels() {
        #expect(TimeText.durationLabel(1800) == "30 分鐘")
        #expect(TimeText.durationLabel(3600) == "1 小時")
        #expect(TimeText.durationLabel(5400) == "1.5 小時")
        #expect(TimeText.remaining(30) == "不到 1 分鐘")
        #expect(TimeText.remaining(3600 + 23 * 60) == "1 小時 23 分")
        #expect(TimeText.compactRemaining(3600 + 5 * 60) == "1:05")
        #expect(TimeText.compactRemaining(45 * 60) == "45分")
    }
}
