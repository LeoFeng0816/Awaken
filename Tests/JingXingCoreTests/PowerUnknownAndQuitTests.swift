import Foundation
import Testing
@testable import JingXingCore

@Suite(.language(.traditionalChinese))
struct PowerParsingTests {
    private let battery: [String: Any] = ["Current Capacity": 42, "Max Capacity": 100]

    @Test func unknownIsNeverTreatedAsAC() {
        #expect(PowerSourceInfo.parse(providing: nil, batteries: []).source == .unknown)
        #expect(PowerSourceInfo.parse(providing: "UPS Power", batteries: []).source == .unknown)
        #expect(PowerSourceInfo.unknown.assess(minimumBattery: 20) == .unknown)
        // 讀得到百分比但供電來源未知，也不算確認。
        #expect(PowerSourceInfo.parse(providing: nil, batteries: [battery]).assess(minimumBattery: 20) == .unknown)
    }

    @Test func parsesKnownSources() {
        let ac = PowerSourceInfo.parse(providing: "AC Power", batteries: [battery])
        #expect(ac == PowerSourceInfo(source: .ac, batteryPercent: 42))
        #expect(ac.assess(minimumBattery: 50) == .safe)
        let onBattery = PowerSourceInfo.parse(providing: "Battery Power", batteries: [battery])
        #expect(onBattery.assess(minimumBattery: 20) == .safe)
        #expect(onBattery.assess(minimumBattery: 50) == .low(42))
    }

    @Test func unreadableBatteryPercentIsUnknownOnBattery() {
        let cases: [[[String: Any]]] = [
            [],
            [["Current Capacity": 42]],
            [["Current Capacity": 42, "Max Capacity": 0]],
            [["Current Capacity": 500, "Max Capacity": 100]],
            [["Current Capacity": -1, "Max Capacity": 100]],
            [["Current Capacity": "x", "Max Capacity": 100]],
        ]
        for batteries in cases {
            let info = PowerSourceInfo.parse(providing: "Battery Power", batteries: batteries)
            #expect(info.batteryPercent == nil)
            #expect(info.assess(minimumBattery: 20) == .unknown)
        }
    }

    @Test func realProbeNeverReportsContradiction() {
        // 只讀取本機狀態：回報電池時要嘛有合理電量，要嘛被判定為未知。
        let info = SystemLidProbe().powerSource()
        if let pct = info.batteryPercent { #expect((0...100).contains(pct)) }
        if info.source == .battery, info.batteryPercent == nil {
            #expect(info.assess(minimumBattery: 20) == .unknown)
        }
    }
}

@MainActor @Suite(.language(.traditionalChinese))
struct LidPowerUnknownTests {
    let clock = FakeClock()
    let probe = FakeProbe()
    let files = MemoryFiles()
    let runner = FakeRunner()

    func make() -> LidSleepController {
        LidSleepController(probe: probe, files: files, runner: runner, clock: clock,
                           sleeper: InstantSleeper(), appPID: 4242, confirmTimeout: 2, stopTimeout: 2)
    }

    func simulateWatchdogLaunch(pid: Int32 = 777) {
        runner.handler = { [probe, clock] _ in
            probe.processes[pid] = ProcessSnapshot(pid: pid, startTime: clock.now(), command: "bash", uid: 0)
            probe.sleepDisabledValue = true
            return .success("\(pid)\n")
        }
        files.onStop = { [probe] _ in
            probe.processes[pid] = nil
            probe.sleepDisabledValue = false
        }
    }

    @Test(arguments: [
        PowerSourceInfo.unknown,
        PowerSourceInfo(source: .unknown, batteryPercent: 80),
        PowerSourceInfo(source: .battery, batteryPercent: nil),
    ])
    func refusesToStartWhenPowerUnknown(power: PowerSourceInfo) async {
        probe.powerValue = power
        let c = make()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(runner.commands.isEmpty, "未知時不可要求管理員授權")
        #expect(files.record == nil)
        #expect(c.state == .off)
        #expect(c.message?.contains("無法確認") == true)
    }

    @Test func startsOnConfirmedACWithoutBatteryPercent() async {
        simulateWatchdogLaunch()
        probe.powerValue = PowerSourceInfo(source: .ac, batteryPercent: nil)
        let c = make()
        #expect(await c.start(until: clock.now().addingTimeInterval(3600)))
    }

    @Test func temporaryUnknownDoesNotStop() async {
        simulateWatchdogLaunch()
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        // 反覆短暫失敗，累計超過容錯時間，但每次都恢復。
        for _ in 0..<4 {
            probe.powerValue = .unknown
            await c.tick()
            clock.advance(LidSleepController.powerUnknownGrace - 5)
            await c.tick()
            if case .active = c.state {} else { Issue.record("容錯內不應停止：\(c.state)") }
            probe.powerValue = PowerSourceInfo(source: .ac, batteryPercent: 80)
            await c.tick()
        }
        #expect(files.stopRequests.isEmpty)
    }

    @Test func persistentUnknownStopsAndRestores() async {
        simulateWatchdogLaunch()
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        probe.powerValue = .unknown
        await c.tick()
        clock.advance(LidSleepController.powerUnknownGrace)
        await c.tick()
        #expect(files.stopRequests.count == 1)
        #expect(c.state == .off)
        #expect(probe.sleepDisabledValue == false)
        #expect(c.message?.contains("讀不到供電") == true)
    }

    @Test func persistentUnknownWithFailedRestoreExplains() async {
        simulateWatchdogLaunch()
        files.onStop = nil
        let c = make()
        await c.start(until: clock.now().addingTimeInterval(3600))
        probe.powerValue = PowerSourceInfo(source: .battery, batteryPercent: nil)
        await c.tick()
        clock.advance(LidSleepController.powerUnknownGrace)
        await c.tick()
        if case .needsRecovery = c.state {} else { Issue.record("應需還原：\(c.state)") }
        #expect(c.message?.contains("無法確認供電") == true)
        #expect(files.record != nil)
    }

    @Test func watchdogToleranceMatchesAppGrace() {
        let seconds = Double(LidSleepController.watchdogPowerReadMaxFailures) * LidSleepController.watchdogPollInterval
        #expect(seconds == LidSleepController.powerUnknownGrace)
    }

    @Test func launchKeepsRecordWhenStateUnreadable() async {
        files.record = LidSessionRecord(token: "t", appPID: 1, originalSleepDisabled: false, requestedAt: clock.now(),
                                        deadline: clock.now(), stopFile: "/s", heartbeatFile: "/h")
        probe.sleepDisabledValue = nil
        let c = make()
        await c.recoverOnLaunch()
        if case .needsRecovery = c.state {} else { Issue.record("應需還原：\(c.state)") }
        #expect(files.record != nil)
    }
}

@MainActor @Suite(.language(.traditionalChinese))
struct QuitCoordinatorTests {
    let clock = FakeClock()
    let probe = FakeProbe()
    let files = MemoryFiles()
    let runner = FakeRunner()
    let power = FakePower()
    let locker = FakeLocker()

    func makeLid() -> LidSleepController {
        LidSleepController(probe: probe, files: files, runner: runner, clock: clock,
                           sleeper: InstantSleeper(), appPID: 4242, confirmTimeout: 2, stopTimeout: 2)
    }

    func simulateWatchdogLaunch(respondsToStop: Bool = true) {
        runner.handler = { [probe, clock] _ in
            probe.processes[777] = ProcessSnapshot(pid: 777, startTime: clock.now(), command: "bash", uid: 0)
            probe.sleepDisabledValue = true
            return .success("777\n")
        }
        if respondsToStop {
            files.onStop = { [probe] _ in
                probe.processes[777] = nil
                probe.sleepDisabledValue = false
            }
        }
    }

    private func setUp(_ lid: LidSleepController) -> (AwakeController, LockTimerController, QuitCoordinator) {
        let awake = AwakeController(power: power, clock: clock)
        let lock = LockTimerController(locker: locker, clock: clock)
        awake.start(duration: .indefinite)
        lock.schedule(after: 600)
        return (awake, lock, QuitCoordinator(lid: lid, awake: awake, lock: lock, clock: clock))
    }

    @Test func plainQuitIsImmediateAndReleasesEverything() {
        let lid = makeLid()
        let (awake, lock, coordinator) = setUp(lid)
        #expect(coordinator.quitImmediatelyIfPossible())
        #expect(!awake.isActive)
        #expect(power.held.isEmpty)
        #expect(lock.state == .idle)
        #expect(files.stopRequests.isEmpty)
    }

    @Test func quitWithRestoredLidDoesNotAsk() async {
        simulateWatchdogLaunch()
        let lid = makeLid()
        await lid.start(until: clock.now().addingTimeInterval(3600))
        let (awake, _, coordinator) = setUp(lid)
        #expect(!coordinator.quitImmediatelyIfPossible(), "有合蓋工作階段不可跳過確認")
        #expect(awake.isActive)
        var asked = false
        let quit = await coordinator.run { _ in asked = true; return .cancelQuit }
        #expect(quit)
        #expect(!asked)
        #expect(!awake.isActive)
        #expect(probe.sleepDisabledValue == false)
        #expect(files.record == nil)
    }

    @Test func unresolvedLidAsksAndCancelKeepsEverything() async {
        simulateWatchdogLaunch(respondsToStop: false)
        let lid = makeLid()
        await lid.start(until: clock.now().addingTimeInterval(3600))
        let (awake, lock, coordinator) = setUp(lid)
        var prompt: LidQuitPrompt?
        let quit = await coordinator.run { prompt = $0; return .cancelQuit }
        #expect(!quit)
        #expect(prompt?.title.contains("尚未確認還原") == true)
        #expect(prompt?.body.contains("sudo pmset -a disablesleep 0") == true)
        #expect(prompt?.body.contains("繼續嘗試還原") == true, "看守程序仍在時要說明它會嘗試處理")
        // 取消結束：保持清醒、上鎖倒數與恢復記錄都不受影響。
        #expect(awake.isActive)
        #expect(lock.isScheduled)
        #expect(power.held.count == 1)
        #expect(files.record != nil)
        if case .needsRecovery = lid.state {} else { Issue.record("應需還原：\(lid.state)") }
        // 面板上仍可手動還原。
        runner.handler = { [probe] _ in probe.sleepDisabledValue = false; probe.processes[777] = nil; return .success("") }
        await lid.forceRestore()
        #expect(lid.state == .off)
        #expect(files.record == nil)
    }

    @Test func quitAnywayKeepsRecordForNextLaunch() async {
        simulateWatchdogLaunch(respondsToStop: false)
        let lid = makeLid()
        await lid.start(until: clock.now().addingTimeInterval(3600))
        let (awake, lock, coordinator) = setUp(lid)
        probe.processes[777] = nil   // 看守程序已被強制終止，設定殘留
        var prompt: LidQuitPrompt?
        let quit = await coordinator.run { prompt = $0; return .quitAnyway }
        #expect(quit)
        #expect(prompt?.body.contains("不會自動恢復") == true)
        #expect(!awake.isActive)
        #expect(lock.state == .idle)
        #expect(files.record != nil, "恢復記錄必須保留")

        // 下一次啟動：顯示未啟用的保持清醒，但提示還原，且不自動要求密碼。
        let commandsBefore = runner.commands.count
        let next = makeLid()
        await next.recoverOnLaunch()
        if case .needsRecovery = next.state {} else { Issue.record("下次啟動應提示還原：\(next.state)") }
        #expect(runner.commands.count == commandsBefore)
    }

    @Test func hopelessCaseDoesNotWaitForTimeout() async {
        files.record = LidSessionRecord(token: "t", appPID: 1, originalSleepDisabled: false, requestedAt: clock.now(),
                                        deadline: clock.now(), stopFile: "/s", heartbeatFile: "/h")
        probe.sleepDisabledValue = true
        let lid = makeLid()
        await lid.recoverOnLaunch()
        let outcome = await lid.prepareForTermination()
        guard case .unresolved(_, let running, _) = outcome else {
            Issue.record("應為未確認：\(outcome)")
            return
        }
        #expect(!running)
        #expect(files.stopRequests.isEmpty)
    }

    @Test func unreadableStateAtQuitIsUnresolvedNotRestored() async {
        simulateWatchdogLaunch()
        let lid = makeLid()
        await lid.start(until: clock.now().addingTimeInterval(3600))
        files.onStop = { [probe] _ in
            probe.processes[777] = nil
            probe.sleepDisabledValue = nil
        }
        let outcome = await lid.prepareForTermination()
        if case .unresolved = outcome {} else { Issue.record("讀不到不能算已還原：\(outcome)") }
        #expect(files.record != nil)
    }

    @Test func noRecordMeansNotInvolved() async {
        probe.sleepDisabledValue = true   // 別人設定的，與靜醒無關
        let lid = makeLid()
        lid.refresh()
        #expect(!lid.hasSessionToResolve)
        #expect(await lid.prepareForTermination() == .notInvolved)
    }
}
