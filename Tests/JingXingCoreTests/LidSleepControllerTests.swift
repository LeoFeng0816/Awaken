import Foundation
import Testing
@testable import JingXingCore

@MainActor @Suite(.language(.traditionalChinese))
struct LidSleepControllerTests {
    let clock = FakeClock()
    let probe = FakeProbe()
    let files = MemoryFiles()
    let runner = FakeRunner()

    func make() -> LidSleepController {
        LidSleepController(probe: probe, files: files, runner: runner, clock: clock,
                           sleeper: InstantSleeper(), appPID: 4242, confirmTimeout: 2, stopTimeout: 2)
    }

    /// 模擬「授權成功、看守程序啟動並設定 disablesleep 1」。
    func simulateWatchdogLaunch(pid: Int32 = 777) {
        runner.handler = { [probe, clock] _ in
            probe.processes[pid] = ProcessSnapshot(pid: pid, startTime: clock.now(), command: "bash", uid: 0)
            probe.sleepDisabledValue = true
            return .success("\(pid)\n")
        }
        // 停止檔出現 → 看守程序還原並結束。
        files.onStop = { [probe] _ in
            probe.processes[pid] = nil
            probe.sleepDisabledValue = false
        }
    }

    @Test func unavailableOnDesktopMac() {
        probe.clamshellValue = nil
        let c = make()
        c.refresh()
        if case .unavailable = c.state {} else { Issue.record("應不可用") }
    }

    @Test func unavailableWhenStateUnreadable() async {
        probe.sleepDisabledValue = nil
        let c = make()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(runner.commands.isEmpty)
        if case .unavailable = c.state {} else { Issue.record("應不可用") }
    }

    @Test func preexistingSleepDisabledIsLeftAlone() async {
        probe.sleepDisabledValue = true
        let c = make()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(runner.commands.isEmpty, "不應要求管理員權限")
        #expect(c.state == .externallyDisabled)
    }

    @Test func refusesOnLowBatteryAndHeat() async {
        probe.powerValue = PowerSourceInfo(source: .battery, batteryPercent: 12)
        let c = make()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(c.message?.contains("12%") == true)
        probe.powerValue = PowerSourceInfo(source: .ac, batteryPercent: 12)
        probe.thermalValue = .serious
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(runner.commands.isEmpty)
    }

    @Test func userCancelsAuthorization() async {
        runner.handler = { _ in .cancelled }
        let c = make()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(c.state == .off)
        #expect(files.record == nil)
        #expect(c.message?.contains("取消") == true)
    }

    @Test func journalWrittenBeforePrivilegedCall() async {
        var recordAtCall: LidSessionRecord?
        runner.handler = { [files] _ in recordAtCall = files.record; return .cancelled }
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        #expect(recordAtCall?.originalSleepDisabled == false)
        #expect(recordAtCall?.appPID == 4242)
    }

    @Test func successfulStartAndManualStopRestores() async {
        simulateWatchdogLaunch()
        let c = make()
        #expect(await c.start(until: clock.now().addingTimeInterval(3600)))
        #expect(c.state == .active(deadline: clock.now().addingTimeInterval(3600)))
        #expect(runner.commands.first?.contains(LidWatchdogScript.processTag) == true)
        await c.stop()
        #expect(c.state == .off)
        #expect(probe.sleepDisabledValue == false)
        #expect(files.record == nil)
    }

    @Test func durationIsCappedAt12Hours() async {
        simulateWatchdogLaunch()
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(48 * 3600))
        #expect(c.deadline == clock.now().addingTimeInterval(LidSleepController.maxDuration))
    }

    @Test func notConfirmedMeansFailureAndCleanup() async {
        // 授權成功但 SleepDisabled 沒有變成 1。
        runner.handler = { [probe, clock] _ in
            probe.processes[900] = ProcessSnapshot(pid: 900, startTime: clock.now(), command: "bash", uid: 0)
            return .success("900")
        }
        files.onStop = { [probe] _ in probe.processes[900] = nil }
        let c = make()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(c.state == .off)
        #expect(files.stopRequests.count == 1)
        #expect(files.record == nil)
    }

    @Test func reusedPIDIsNotMistakenForWatchdog() async {
        // 回報的 PID 屬於一般使用者的其他程序。
        runner.handler = { [probe, clock] _ in
            probe.processes[901] = ProcessSnapshot(pid: 901, startTime: clock.now().addingTimeInterval(-500), command: "Safari", uid: 501)
            probe.sleepDisabledValue = true
            return .success("901")
        }
        let c = make()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        if case .needsRecovery = c.state {} else { Issue.record("SleepDisabled 仍為 1，應要求還原：\(c.state)") }
    }

    @Test func expiryStopsWatchdog() async {
        simulateWatchdogLaunch()
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(600))
        clock.advance(601)
        await c.tick()
        #expect(c.state == .off)
        #expect(c.message?.contains("到時") == true)
    }

    @Test func heartbeatIsSentWhileActive() async {
        simulateWatchdogLaunch()
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(600))
        let before = files.touched.count
        clock.advance(11)
        await c.tick()
        #expect(files.touched.count == before + 1)
    }

    @Test func lowBatteryAndThermalStop() async {
        simulateWatchdogLaunch()
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        probe.powerValue = PowerSourceInfo(source: .battery, batteryPercent: 14)
        await c.tick()
        #expect(c.state == .off)
        #expect(c.message?.contains("電池") == true)

        simulateWatchdogLaunch(pid: 778)
        probe.powerValue = PowerSourceInfo(source: .ac, batteryPercent: 90)
        await c.start(until: clock.now().addingTimeInterval(3600))
        probe.thermalValue = .critical
        await c.tick()
        #expect(c.state == .off)
        #expect(c.message?.contains("溫度") == true)
    }

    @Test func watchdogDiedButSleepStillDisabledNeedsRecovery() async {
        simulateWatchdogLaunch()
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        probe.processes[777] = nil   // 看守程序被強制終止，沒有還原
        await c.tick()
        if case .needsRecovery = c.state {} else { Issue.record("應需還原：\(c.state)") }
    }

    @Test func stopTimeoutLeadsToRecoveryNotFakeSuccess() async {
        simulateWatchdogLaunch()
        files.onStop = nil   // 看守程序沒有回應停止檔
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        await c.stop()
        if case .needsRecovery = c.state {} else { Issue.record("應需還原：\(c.state)") }
        #expect(files.record != nil, "日誌須保留以便還原")
    }

    @Test func stopFileFailureLeadsToRecovery() async {
        simulateWatchdogLaunch()
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        files.failStop = true
        await c.stop()
        if case .needsRecovery(let m) = c.state { #expect(m.contains("磁碟錯誤")) } else { Issue.record("應需還原") }
    }

    @Test func forceRestoreRunsOnlyRecordedRestore() async {
        simulateWatchdogLaunch()
        files.onStop = nil
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        probe.processes[777] = nil
        await c.tick()
        runner.handler = { [probe] cmd in
            if cmd == "/usr/bin/pmset -a disablesleep 0" { probe.sleepDisabledValue = false; return .success("") }
            return .failed("unexpected")
        }
        await c.forceRestore()
        #expect(runner.commands.last == "/usr/bin/pmset -a disablesleep 0")
        #expect(c.state == .off)
        #expect(files.record == nil)
    }

    @Test func forceRestoreCancelledKeepsWarning() async {
        files.record = LidSessionRecord(token: "t", appPID: 1, originalSleepDisabled: false, requestedAt: clock.now(),
                                        deadline: clock.now(), stopFile: "/s", heartbeatFile: "/h")
        probe.sleepDisabledValue = true
        let c = make()
        await c.recoverOnLaunch()
        if case .needsRecovery = c.state {} else { Issue.record("應需還原") }
        #expect(runner.commands.isEmpty, "啟動時不可自動要求密碼")
        runner.handler = { _ in .cancelled }
        await c.forceRestore()
        if case .needsRecovery = c.state {} else { Issue.record("取消後仍應警告") }
    }

    @Test func launchWithStaleRecordButRestoredStateClearsIt() async {
        files.record = LidSessionRecord(token: "t", appPID: 1, originalSleepDisabled: false, requestedAt: clock.now(),
                                        deadline: clock.now(), stopFile: "/s", heartbeatFile: "/h", watchdogPID: 55)
        probe.sleepDisabledValue = false
        let c = make()
        await c.recoverOnLaunch()
        #expect(c.state == .off)
        #expect(files.record == nil)
    }

    @Test func launchWithRunningOldWatchdogStopsIt() async {
        let start = clock.now()
        files.record = LidSessionRecord(token: "t", appPID: 1, originalSleepDisabled: false, requestedAt: start,
                                        deadline: start.addingTimeInterval(100), stopFile: "/s", heartbeatFile: "/h",
                                        watchdogPID: 55, watchdogStart: start)
        probe.processes[55] = ProcessSnapshot(pid: 55, startTime: start, command: "bash", uid: 0)
        probe.sleepDisabledValue = true
        files.onStop = { [probe] _ in probe.processes[55] = nil; probe.sleepDisabledValue = false }
        let c = make()
        await c.recoverOnLaunch()
        #expect(files.stopRequests == ["/s"])
        #expect(c.state == .off)
    }

    @Test func noRecordMeansNoTouchingSystem() async {
        probe.sleepDisabledValue = true   // 別人設定的
        let c = make()
        await c.recoverOnLaunch()
        #expect(c.state == .externallyDisabled)
        await c.forceRestore()
        #expect(runner.commands.isEmpty)
    }
}
