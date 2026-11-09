import Foundation
import Testing
@testable import JingXingCore

/// 真實看守腳本 + 會卡住的假命令。假命令忽略 TERM 並帶著子程序，只有對行程群組送 KILL 才會消失。
/// 不需要 root，也不會執行真正的 `pmset -a disablesleep`。
extension WatchdogSuites {
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .language(.traditionalChinese))
struct WatchdogHangTests {
    typealias Sandbox = WatchdogScriptTests.Sandbox

    /// 等腳本結束並回傳結束碼；超過外層上限就強制結束，回傳 nil。
    private func exitStatus(_ proc: Process, limit: Double = 15) async -> Int32? {
        let end = Date().addingTimeInterval(limit)
        while proc.isRunning, Date() < end {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !proc.isRunning else {
            kill(proc.processIdentifier, SIGKILL)
            Issue.record("腳本超過 \(limit) 秒仍未結束")
            return nil
        }
        return proc.terminationStatus
    }

    private func expectNoHungLeft(_ box: Sandbox, sourceLocation: SourceLocation = #_sourceLocation) async {
        let gone = await WatchdogScriptTests.waitUntil(2) {
            box.recordedHungPids.allSatisfy { !WatchdogScriptTests.alive($0) }
        }
        #expect(gone, "卡住的命令應已被清除", sourceLocation: sourceLocation)
    }

    private func expectWorkDirRemoved(_ pid: Int32, sourceLocation: SourceLocation = #_sourceLocation) {
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [])
            .filter { $0.hasPrefix("jingxing-wd.\(pid).") }
        #expect(left.isEmpty, "暫存目錄應已移除", sourceLocation: sourceLocation)
    }

    // MARK: 開始之前：不可改動任何設定

    @Test func hungStateQueryAtStartChangesNothing() async throws {
        let box = try Sandbox()
        try box.setFlag("hang-state")
        let proc = try box.runDirect(box.params())
        let pid = proc.processIdentifier
        #expect(await exitStatus(proc) == 10)
        #expect(box.pmsetCalls.isEmpty)
        #expect(!box.sleepDisabled)
        #expect(!box.recordedHungPids.isEmpty)
        await expectNoHungLeft(box)
        expectWorkDirRemoved(pid)
    }

    @Test func alreadyDisabledIsNeverChangedEvenIfToolsHang() async throws {
        let box = try Sandbox(initiallyDisabled: true)
        for flag in ["hang-set-0", "hang-set-1", "hang-batt"] { try box.setFlag(flag) }
        #expect(await exitStatus(try box.runDirect(box.params())) == 10)
        #expect(box.pmsetCalls.isEmpty)
        #expect(box.sleepDisabled, "原本已停用，不可被改回 0")
    }

    @Test func alreadyDisabledWithUnreadableStateIsNeverChanged() async throws {
        let box = try Sandbox(initiallyDisabled: true)
        try box.setFlag("hang-state")
        #expect(await exitStatus(try box.runDirect(box.params())) == 10)
        #expect(box.pmsetCalls.isEmpty)
        #expect(box.sleepDisabled)
        await expectNoHungLeft(box)
    }

    // MARK: 設定卡住

    @Test func hungSetRestoresAndKillsWriter() async throws {
        let box = try Sandbox()
        try box.setFlag("hang-set-1")
        let proc = try box.runDirect(box.params())
        #expect(await exitStatus(proc) == 13)
        #expect(!box.sleepDisabled)
        #expect(box.pmsetCalls == ["1", "0"])
        await expectNoHungLeft(box)
        expectWorkDirRemoved(proc.processIdentifier)
    }

    @Test func failedSetIsReportedAndRestored() async throws {
        let box = try Sandbox()
        try box.setFlag("fail-set-1")
        #expect(await exitStatus(try box.runDirect(box.params())) == 13)
        #expect(!box.sleepDisabled)
    }

    @Test func lateWriteInKilledGroupNeverLands() async throws {
        let box = try Sandbox()
        try box.setFlag("late-group-set-1")
        #expect(await exitStatus(try box.runDirect(box.params())) == 13)
        // 超過假命令預定晚到的時間後再看一次。
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(!box.sleepDisabled)
        #expect(!box.pmsetCalls.contains("late-1"), "群組被殺後不應有晚到的寫入")
    }

    @Test func lateWriteOutsideGroupIsOverwrittenDuringSettle() async throws {
        let box = try Sandbox()
        try box.setFlag("late-escaped-set-1")
        let status = await exitStatus(try box.runDirect(box.params()))
        #expect(status == 13, "還原已確認，保留原本的失敗碼")
        #expect(box.pmsetCalls.contains("late-1"), "測試前提：晚到的寫入確實發生")
        #expect(box.pmsetCalls.last == "0", "晚到的 1 之後應再寫回 0")
        #expect(!box.sleepDisabled)
    }

    // MARK: 還原卡住：不可錯報成功

    @Test func hungRestoreIsBoundedAndNotReportedAsSuccess() async throws {
        let box = try Sandbox()
        try box.setFlag("hang-set-0")
        let proc = try box.runDirect(box.params())
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try Data().write(to: box.stop)
        #expect(await exitStatus(proc) == 20)
        #expect(box.sleepDisabled, "沒有還原成功，狀態不應被改寫")
        await expectNoHungLeft(box)
        expectWorkDirRemoved(proc.processIdentifier)
    }

    @Test func failedRestoreIsNotReportedAsSuccess() async throws {
        let box = try Sandbox()
        try box.setFlag("fail-set-0")
        let proc = try box.runDirect(box.params())
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try Data().write(to: box.stop)
        #expect(await exitStatus(proc) == 20)
        #expect(box.sleepDisabled)
    }

    @Test func restoreRetrySucceedsAfterTemporaryHang() async throws {
        let box = try Sandbox()
        try box.setFlag("hang-set-0")
        let proc = try box.runDirect(box.params())
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try Data().write(to: box.stop)
        // 第一次還原卡住後解除，第二次應成功。
        #expect(await WatchdogScriptTests.waitUntil { !box.recordedHungPids.isEmpty })
        box.clearFlag("hang-set-0")
        #expect(await exitStatus(proc) == 0)
        #expect(!box.sleepDisabled)
    }

    // MARK: 使用中查詢卡住

    @Test func hungStateQueryDuringSessionFallsBackConservatively() async throws {
        let box = try Sandbox()
        let proc = try box.runDirect(box.params())
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try box.setFlag("hang-state")
        // 查詢一直卡住：已寫入 0，但無法確認，不能回報成功。
        #expect(await exitStatus(proc) == 20)
        #expect(box.pmsetCalls.last == "0")
        #expect(!box.sleepDisabled)
        await expectNoHungLeft(box)
    }

    @Test func temporaryStateHangDuringSessionStillRestoresAndConfirms() async throws {
        let box = try Sandbox()
        let proc = try box.runDirect(box.params())
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try box.setFlag("hang-state")
        #expect(await WatchdogScriptTests.waitUntil { !box.recordedHungPids.isEmpty })
        box.clearFlag("hang-state")
        #expect(await exitStatus(proc) == 0)
        #expect(!box.sleepDisabled)
    }

    @Test func hungBatteryQueryEndsSessionWithinLimit() async throws {
        let box = try Sandbox()
        let proc = try box.runDirect(box.params(powerReadMaxFailures: 15))
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try box.setFlag("hang-batt")
        let started = Date()
        #expect(await exitStatus(proc) == 0)
        // 卡住的查詢最多容許約 3 次，不會等滿 15 次。
        #expect(Date().timeIntervalSince(started) < 8)
        #expect(!box.sleepDisabled)
        #expect(box.pmsetCalls == ["1", "0"])
        await expectNoHungLeft(box)
    }

    @Test func temporaryBatteryHangDoesNotEndSession() async throws {
        let box = try Sandbox()
        // 容許 3 次卡住：卡住一次後恢復，不應結束。
        let proc = try box.runDirect(box.params(powerReadMaxFailures: 15))
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try box.setFlag("hang-batt")
        #expect(await WatchdogScriptTests.waitUntil { !box.recordedHungPids.isEmpty })
        box.clearFlag("hang-batt")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(proc.isRunning)
        #expect(box.sleepDisabled)
        try Data().write(to: box.stop)
        #expect(await exitStatus(proc) == 0)
        #expect(!box.sleepDisabled)
    }

    @Test func stopRequestIsHonouredWhileQueriesHang() async throws {
        let box = try Sandbox()
        let proc = try box.runDirect(box.params(powerReadMaxFailures: 1_000))
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try box.setFlag("hang-batt")
        #expect(await WatchdogScriptTests.waitUntil { !box.recordedHungPids.isEmpty })
        try Data().write(to: box.stop)
        #expect(await exitStatus(proc, limit: 6) == 0)
        #expect(!box.sleepDisabled)
    }

    // MARK: 訊號

    @Test func terminateDuringHungQueryCleansUpAndRestores() async throws {
        let box = try Sandbox()
        let proc = try box.runDirect(box.params(powerReadMaxFailures: 1_000))
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try box.setFlag("hang-batt")
        #expect(await WatchdogScriptTests.waitUntil { !box.recordedHungPids.isEmpty })
        kill(proc.processIdentifier, SIGTERM)
        #expect(await exitStatus(proc) == 0)
        #expect(!box.sleepDisabled)
        await expectNoHungLeft(box)
        expectWorkDirRemoved(proc.processIdentifier)
    }

    @Test func terminateDuringHungWriteTreatsResultAsUncertain() async throws {
        let box = try Sandbox()
        try box.setFlag("late-escaped-set-1")
        let proc = try box.runDirect(box.params())
        #expect(await WatchdogScriptTests.waitUntil { !box.recordedHungPids.isEmpty })
        kill(proc.processIdentifier, SIGTERM)
        #expect(await exitStatus(proc) != nil)
        // 寫入被中斷也要觀察：晚到的 1 不可留下。
        #expect(box.pmsetCalls.contains("late-1"))
        #expect(box.pmsetCalls.last == "0")
        #expect(!box.sleepDisabled)
    }

    // MARK: 殺不掉的程序（覆寫 kill 模擬，真實情況是不可中斷的 kernel I/O）

    private func unkillablePrefix(_ box: Sandbox) -> String {
        let flag = ShellQuote.single(box.dir.appendingPathComponent("unkillable").path)
        return """
        kill() {
          if [ -e \(flag) ] && { [ "$1" = "-TERM" ] || [ "$1" = "-KILL" ]; }; then return 0; fi
          builtin kill "$@"
        }

        """
    }

    @Test func unkillableWriterDoesNotBlockForeverOrClaimSuccess() async throws {
        let box = try Sandbox()
        try box.setFlag("unkillable")
        try box.setFlag("hang-set-1")
        let started = Date()
        let proc = try box.runDirect(box.params(), prefix: unkillablePrefix(box))
        #expect(await exitStatus(proc) == 20, "還有殺不掉的寫入程序，不能當成已確認")
        #expect(Date().timeIntervalSince(started) < 12)
        // 能還原的部分仍然要還原。
        #expect(box.pmsetCalls.last == "0")
        #expect(!box.sleepDisabled)
        #expect(box.recordedHungPids.contains { WatchdogScriptTests.alive($0) }, "測試前提：模擬的程序確實沒被殺掉")
    }

    @Test func stragglerIsSweptWhenItBecomesKillable() async throws {
        let box = try Sandbox()
        try box.setFlag("unkillable")
        try box.setFlag("hang-set-1")
        var timing = Sandbox.fastTiming
        timing.stragglerHoldMs = 8_000
        let proc = try box.runDirect(box.params(timing: timing), prefix: unkillablePrefix(box))
        #expect(await WatchdogScriptTests.waitUntil { box.pmsetCalls.contains("0") })
        box.clearFlag("unkillable")
        // 程序一旦能被結束就會被清掉，還原得以確認，不必等滿追蹤上限。
        #expect(await exitStatus(proc) == 13)
        #expect(!box.sleepDisabled)
        await expectNoHungLeft(box)
    }

    @Test func writerCountStaysCappedWhenNothingCanBeKilled() async throws {
        let box = try Sandbox()
        try box.setFlag("unkillable")
        try box.setFlag("hang-set-0")
        var timing = Sandbox.fastTiming
        timing.stragglerHoldMs = 12_000
        let proc = try box.runDirect(box.params(timing: timing), prefix: unkillablePrefix(box))
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try Data().write(to: box.stop)
        #expect(await exitStatus(proc, limit: 40) == 20)
        #expect(box.sleepDisabled)
        #expect(box.recordedHungPids.count <= 8, "不可無限增加殺不掉的程序")
        #expect(box.recordedHungPids.count == 8, "測試前提：確實達到上限")
        expectWorkDirRemoved(proc.processIdentifier)
    }

    // MARK: 結束碼

    /// 反覆完整執行，確認在 job control 下每一步都能正確取得結束碼。
    @Test func commandStatusIsReliableAcrossManyRuns() async throws {
        for attempt in 0..<20 {
            let box = try Sandbox()
            let proc = try box.runDirect(box.params())
            let started = await WatchdogScriptTests.waitUntil(4) { box.sleepDisabled }
            #expect(started, "第 \(attempt + 1) 次沒有成功開始")
            try Data().write(to: box.stop)
            #expect(await exitStatus(proc) == 0, "第 \(attempt + 1) 次")
            #expect(box.pmsetCalls == ["1", "0"], "第 \(attempt + 1) 次")
        }
    }

    @Test func nonZeroStatusIsNotMistakenForSuccess() async throws {
        for _ in 0..<5 {
            let box = try Sandbox()
            try box.setFlag("fail-set-1")
            // 假 pmset 失敗時不會寫入狀態；腳本要以結束碼判斷，而不是等到下一步才發現。
            #expect(await exitStatus(try box.runDirect(box.params())) == 13)
        }
    }

    // MARK: 暫存目錄

    @Test func workDirIsPrivateWhileRunning() async throws {
        let box = try Sandbox()
        let proc = try box.runDirect(box.params())
        let pid = proc.processIdentifier
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        let name = try FileManager.default.contentsOfDirectory(atPath: "/tmp")
            .first { $0.hasPrefix("jingxing-wd.\(pid).") }
        let dirName = try #require(name)
        let attributes = try FileManager.default.attributesOfItem(atPath: "/tmp/\(dirName)")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
        try Data().write(to: box.stop)
        #expect(await exitStatus(proc) == 0)
        expectWorkDirRemoved(pid)
    }

    // MARK: 真實查詢命令的格式（唯讀；設定命令仍是假的）

    @Test func realIoregOutputIsParsedReadOnly() async throws {
        let box = try Sandbox()
        var tools = try #require(box.tools)
        tools.stateQuery = LidWatchdogScript.Tools.system.stateQuery
        box.tools = tools
        guard let realValue = SystemLidProbe().sleepDisabled() else {
            Issue.record("讀不到真實的 SleepDisabled")
            return
        }
        let status = await exitStatus(try box.runDirect(box.params()))
        if realValue {
            #expect(status == 10)
            #expect(box.pmsetCalls.isEmpty)
        } else {
            // 真實值讀到 0，假寫入不會改變真實值，所以「確認生效」失敗（14）；還原後讀到 0，不算還原失敗。
            // 這也證明沒有動到真實設定。
            #expect(status == 14)
            #expect(box.pmsetCalls == ["1", "0"])
            #expect(SystemLidProbe().sleepDisabled() == false)
        }
    }

    @Test func realBatteryOutputIsParsedReadOnly() async throws {
        let box = try Sandbox()
        var tools = try #require(box.tools)
        tools.batteryQuery = LidWatchdogScript.Tools.system.batteryQuery
        box.tools = tools
        // 只容許 1 次失敗：真實輸出若無法判讀，腳本會立刻結束。
        let proc = try box.runDirect(box.params(powerReadMaxFailures: 1))
        #expect(await WatchdogScriptTests.waitUntil { box.sleepDisabled })
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let power = SystemLidProbe().powerSource()
        let lowBattery = power.source == .battery && (power.batteryPercent ?? 100) < 10
        if !lowBattery { #expect(proc.isRunning, "真實的 pmset -g batt 輸出應可判讀") }
        try Data().write(to: box.stop)
        #expect(await exitStatus(proc) != nil)
    }

    // MARK: 時限設定

    @Test func productionLimitsAreBoundedAndArgumentsMatch() {
        let timing = LidWatchdogScript.Timing.production
        #expect(timing.stuckCommandSeconds(limitMs: timing.queryMs) == 8)
        #expect(timing.stuckCommandSeconds(limitMs: timing.writeMs) == 11)
        #expect(timing.worstCaseRestoreSeconds < 300)
        let script = LidWatchdogScript()
        let p = LidWatchdogScript.Parameters(appPID: 1, deadline: Date(), duration: 60, stopFile: "/s", heartbeatFile: "/h")
        #expect(script.arguments(p).count == 16)
        #expect(script.body.contains("${16}"))
        #expect(!script.body.contains(" | "), "腳本不可使用管線，否則無法個別管理生命週期")
    }
}

}

// MARK: - 真實腳本 + 控制器：UI 看到的狀態

/// 讀取沙盒狀態的探測器；process 用真實資料，只把 uid 視為 root。
private final class SandboxProbe: LidSystemProbe {
    let box: WatchdogSuites.WatchdogScriptTests.Sandbox
    private let real = SystemLidProbe()
    init(box: WatchdogSuites.WatchdogScriptTests.Sandbox) { self.box = box }
    func sleepDisabled() -> Bool? { box.sleepDisabled }
    func clamshell() -> ClamshellInfo? { ClamshellInfo(closed: false) }
    func powerSource() -> PowerSourceInfo { PowerSourceInfo(source: .ac, batteryPercent: 80) }
    func thermal() -> ThermalLevel { .nominal }
    func process(_ pid: Int32) -> ProcessSnapshot? {
        guard var snap = real.process(pid) else { return nil }
        snap.uid = 0
        return snap
    }
}

/// 只執行帶看守程序標記（且使用假工具）的命令；其他命令一律不執行，絕不碰真正的 pmset。
@MainActor
private final class SandboxRunner: PrivilegedRunner {
    let box: WatchdogSuites.WatchdogScriptTests.Sandbox
    var restoreCommands = 0
    init(box: WatchdogSuites.WatchdogScriptTests.Sandbox) { self.box = box }
    func runAsAdministrator(_ command: String, prompt: String) async -> PrivilegedResult {
        guard command.contains(LidWatchdogScript.processTag) else {
            restoreCommands += 1
            try? box.writeState(false)
            return .success("")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let out = Pipe()
        proc.standardOutput = out
        do { try proc.run() } catch { return .failed("\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return .success(String(decoding: data, as: UTF8.self))
    }
}

extension WatchdogSuites {
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .language(.traditionalChinese))
struct WatchdogControllerIntegrationTests {
    typealias Sandbox = WatchdogScriptTests.Sandbox

    private func make(_ box: Sandbox, stopTimeout: Double = 1) -> (LidSleepController, FileLidSessionFiles, SandboxRunner) {
        let files = FileLidSessionFiles(directory: box.dir.appendingPathComponent("session"))
        let runner = SandboxRunner(box: box)
        let controller = LidSleepController(
            probe: SandboxProbe(box: box), files: files, runner: runner, clock: SystemTimeSource(),
            appPID: box.app!.processIdentifier, script: LidWatchdogScript(tools: box.tools),
            confirmTimeout: 3, stopTimeout: stopTimeout,
            watchdogTiming: Sandbox.fastTiming, pollInterval: 0.2)
        return (controller, files, runner)
    }

    @Test func hungRestoreSurfacesRecoveryAndKeepsRecord() async throws {
        let box = try Sandbox()
        try box.setFlag("hang-set-0")
        let (lid, files, runner) = make(box)
        #expect(await lid.start(until: Date().addingTimeInterval(120)))
        await lid.stop()
        guard case .needsRecovery = lid.state else {
            Issue.record("還原卡住不可顯示成功：\(lid.state)")
            return
        }
        #expect(files.loadRecord() != nil)

        // 看守程序放棄結束後：狀態仍是停用，警告與記錄都要留著。
        let record = try #require(files.loadRecord())
        let pid = try #require(record.watchdogPID)
        #expect(await WatchdogScriptTests.waitUntil(15) { !WatchdogScriptTests.alive(pid) })
        await lid.tick()
        if case .needsRecovery = lid.state {} else { Issue.record("應持續提醒：\(lid.state)") }
        #expect(box.sleepDisabled)
        #expect(files.loadRecord() != nil)

        // 既有 UI 的手動還原仍可用（替身，不執行真正的 pmset）。
        await lid.forceRestore()
        #expect(runner.restoreCommands == 1)
        #expect(lid.state == .off)
        #expect(files.loadRecord() == nil)
    }

    @Test func slowRestoreClearsWarningWhenWatchdogFinishes() async throws {
        let box = try Sandbox()
        try box.setFlag("hang-set-0")
        let (lid, files, _) = make(box)
        #expect(await lid.start(until: Date().addingTimeInterval(120)))
        await lid.stop()
        if case .needsRecovery = lid.state {} else { Issue.record("應先提醒：\(lid.state)") }
        // 卡住的命令恢復後，看守程序重試成功，警告會自動解除。
        box.clearFlag("hang-set-0")
        let cleared = await WatchdogScriptTests.waitUntil(15) { !box.sleepDisabled }
        #expect(cleared)
        let record = try #require(files.loadRecord())
        let pid = try #require(record.watchdogPID)
        #expect(await WatchdogScriptTests.waitUntil(10) { !WatchdogScriptTests.alive(pid) })
        await lid.tick()
        #expect(lid.state == .off)
        #expect(lid.message?.contains("已還原") == true)
    }

    @Test func hungBatteryQueryEndsSessionAndControllerReportsRestored() async throws {
        let box = try Sandbox()
        let (lid, files, _) = make(box)
        #expect(await lid.start(until: Date().addingTimeInterval(120)))
        let pid = try #require(files.loadRecord()?.watchdogPID)
        try box.setFlag("hang-batt")
        #expect(await WatchdogScriptTests.waitUntil(20) { !WatchdogScriptTests.alive(pid) })
        await lid.tick()
        #expect(lid.state == .off)
        #expect(files.loadRecord() == nil)
        #expect(!box.sleepDisabled)
    }

    @Test func hungStartupQueryIsReportedWithoutChange() async throws {
        let box = try Sandbox()
        try box.setFlag("hang-state")
        let (lid, files, _) = make(box, stopTimeout: 4)
        #expect(!(await lid.start(until: Date().addingTimeInterval(120))))
        #expect(lid.state == .off)
        #expect(lid.message?.contains("時限內") == true)
        #expect(box.pmsetCalls.isEmpty)
        #expect(files.loadRecord() == nil)
    }
}
}
