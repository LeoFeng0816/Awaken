import Foundation
import Testing
@testable import JingXingCore

/// 以假的 pmset／ioreg／電池命令實際執行看守程序腳本。不需要 root，也不會碰真正的系統電源設定。
/// 所有會執行真實腳本的測試都放在這裡循序執行，避免大量程序互搶資源造成假的逾時。
@Suite(.serialized) enum WatchdogSuites {}

/// 每項測試都有外層上限（waitUntil 的逾時與 Suite 的 timeLimit），假命令卡住也不會拖住測試。
extension WatchdogSuites {
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .language(.traditionalChinese))
struct WatchdogScriptTests {
    final class Sandbox {
        let dir: URL
        var state: URL { dir.appendingPathComponent("state") }
        var log: URL { dir.appendingPathComponent("pmset.log") }
        var batt: URL { dir.appendingPathComponent("batt") }
        var hungPids: URL { dir.appendingPathComponent("hung.pids") }
        var stop: URL { dir.appendingPathComponent("lid.stop") }
        var heartbeat: URL { dir.appendingPathComponent("lid.heartbeat") }
        var app: Process?

        init(initiallyDisabled: Bool = false, prewarm: Bool = true) throws {
            // 路徑刻意包含空白、中文與單引號，驗證跳脫。
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("靜醒 test 'q' \(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeState(initiallyDisabled)
            try "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%; charged;\n".write(to: batt, atomically: true, encoding: .utf8)
            try Data().write(to: heartbeat)
            let q = ShellQuote.single
            // 卡住的假命令：忽略 TERM、帶著子程序，只有對群組送 KILL 才會消失。
            let hang = """
            hang() {
              echo $$ >> \(q(hungPids.path))
              trap '' TERM
              while :; do /bin/sleep 1; done
            }
            """
            func flag(_ name: String) -> String { q(dir.appendingPathComponent(name).path) }
            let pmset = dir.appendingPathComponent("fake-pmset")
            try """
            #!/bin/bash
            \(hang)
            write_state() {
              if [ "$1" = "1" ]; then v=Yes; else v=No; fi
              printf '  "SleepDisabled" = %s\\n' "$v" > \(q(state.path))
            }
            [ "$1" = "-a" ] && [ "$2" = "disablesleep" ] || exit 1
            echo "$3" >> \(q(log.path))
            [ -e \(flag("fail-set-"))"$3" ] && exit 1
            [ -e \(flag("hang-set-"))"$3" ] && hang
            if [ -e \(flag("late-group-set-"))"$3" ]; then
              # 晚到的寫入留在同一個行程群組：群組被殺就不會發生。
              ( /bin/sleep 1.5; write_state "$3"; echo "late-$3" >> \(q(log.path)) ) &
              hang
            fi
            if [ -e \(flag("late-escaped-set-"))"$3" ]; then
              # 模擬已無法收回的要求：晚到的寫入脫離行程群組，只能靠事後觀察修正。
              set -m
              ( /bin/sleep 1.5; write_state "$3"; echo "late-$3" >> \(q(log.path)) ) &
              hang
            fi
            write_state "$3"
            """.write(to: pmset, atomically: true, encoding: .utf8)
            let ioreg = dir.appendingPathComponent("fake-ioreg")
            try """
            #!/bin/bash
            \(hang)
            [ -e \(flag("hang-state")) ] && hang
            exec /bin/cat \(q(state.path))
            """.write(to: ioreg, atomically: true, encoding: .utf8)
            let battery = dir.appendingPathComponent("fake-batt")
            try """
            #!/bin/bash
            \(hang)
            [ -e \(flag("hang-batt")) ] && hang
            exec /bin/cat \(q(batt.path))
            """.write(to: battery, atomically: true, encoding: .utf8)
            for tool in [pmset, ioreg, battery] {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            }
            tools = LidWatchdogScript.Tools(stateQuery: q(ioreg.path), pmset: q(pmset.path), batteryQuery: q(battery.path))
            // macOS 第一次執行新建立的可執行檔時可能停頓數百毫秒，先各執行一次，避免被當成命令卡住。
            if prewarm {
                for tool in [pmset, ioreg, battery] {
                    let warm = Process()
                    warm.executableURL = tool
                    warm.standardOutput = FileHandle.nullDevice
                    warm.standardError = FileHandle.nullDevice
                    try warm.run()
                    warm.waitUntilExit()
                }
            }
            // 模擬 App 程序。
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["120"]
            try p.run()
            app = p
        }

        var tools: LidWatchdogScript.Tools!

        func writeState(_ disabled: Bool) throws {
            try "  \"SleepDisabled\" = \(disabled ? "Yes" : "No")\n".write(to: state, atomically: true, encoding: .utf8)
        }

        var sleepDisabled: Bool { (try? String(contentsOf: state, encoding: .utf8))?.contains("Yes") == true }
        var pmsetCalls: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func setFlag(_ name: String) throws { try Data().write(to: dir.appendingPathComponent(name)) }
        func clearFlag(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }

        /// 曾經卡住的假命令 PID（確認逾時後都已被清除）。
        var recordedHungPids: [Int32] {
            ((try? String(contentsOf: hungPids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
        }

        static let fastTiming = LidWatchdogScript.Timing(queryMs: 500, writeMs: 500, termGraceMs: 200, killGraceMs: 300,
                                                         settleMs: 2_500, stragglerHoldMs: 1_000, restoreAttempts: 2)

        func params(duration: TimeInterval = 60, heartbeatMaxAge: Int = 120, powerReadMaxFailures: Int = 15,
                    timing: LidWatchdogScript.Timing = Sandbox.fastTiming) -> LidWatchdogScript.Parameters {
            LidWatchdogScript.Parameters(appPID: app!.processIdentifier, deadline: Date().addingTimeInterval(duration),
                                         duration: duration, stopFile: stop.path, heartbeatFile: heartbeat.path,
                                         heartbeatMaxAge: heartbeatMaxAge, pollInterval: 0.2, minimumBatteryPercent: 10,
                                         powerReadMaxFailures: powerReadMaxFailures, timing: timing)
        }

        /// 用 /bin/sh 執行與正式版相同的啟動命令，回傳看守程序 PID。
        func launch(_ p: LidWatchdogScript.Parameters) throws -> Int32 {
            let command = LidWatchdogScript(tools: tools).launchCommand(p)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", command]
            let out = Pipe()
            proc.standardOutput = out
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }

        /// 直接執行腳本以取得結束碼；prefix 可在腳本前插入測試用的覆寫。
        func runDirect(_ p: LidWatchdogScript.Parameters, prefix: String = "") throws -> Process {
            let script = LidWatchdogScript(tools: tools)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", prefix + script.body, LidWatchdogScript.processTag] + script.arguments(p)
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            directProcess = proc
            return proc
        }
        var directProcess: Process?

        deinit {
            app?.terminate()
            // 就算測試失敗也不留下假命令或看守程序。
            for pid in recordedHungPids {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
            if let directProcess, directProcess.isRunning {
                kill(directProcess.processIdentifier, SIGKILL)
            }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    static func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    @Test func appliesThenRestoresOnStopFile() async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params())
        #expect(pid > 1)
        #expect(await Self.waitUntil { box.sleepDisabled })
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(Self.alive(pid), "看守程序應持續執行")
        try Data().write(to: box.stop)
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
        #expect(box.pmsetCalls.first == "1")
        #expect(box.pmsetCalls.last == "0")
    }

    @Test func restoresWhenAppDies() async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params())
        #expect(await Self.waitUntil { box.sleepDisabled })
        box.app?.terminate()
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
    }

    @Test func restoresAtDeadline() async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params(duration: 2))
        #expect(await Self.waitUntil { box.sleepDisabled })
        #expect(await Self.waitUntil(8) { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
    }

    @Test func leavesPreexistingSettingUntouched() async throws {
        let box = try Sandbox(initiallyDisabled: true)
        let pid = try box.launch(box.params())
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(box.sleepDisabled, "原本就是 1，不可被改回 0")
        #expect(box.pmsetCalls.isEmpty)
    }

    @Test func doesNothingIfAppPIDMissing() async throws {
        let box = try Sandbox()
        var p = box.params()
        box.app?.terminate()
        box.app?.waitUntilExit()
        p.appPID = box.app!.processIdentifier
        let pid = try box.launch(p)
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(box.pmsetCalls.isEmpty)
    }

    @Test func restoresWhenHeartbeatGoesStale() async throws {
        let box = try Sandbox()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)],
                                              ofItemAtPath: box.heartbeat.path)
        let pid = try box.launch(box.params(heartbeatMaxAge: 5))
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
        #expect(box.pmsetCalls == ["1", "0"])
    }

    @Test func restoresOnLowBattery() async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params())
        #expect(await Self.waitUntil { box.sleepDisabled })
        try "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t8%; discharging;\n"
            .write(to: box.batt, atomically: true, encoding: .utf8)
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
    }

    /// 持續讀不到或無法判讀時，有限次容錯後結束並還原。
    @Test(arguments: [
        "Now drawing from 'Something Else'\n",
        "",
        "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\tdischarging;\n",
        "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t999%; discharging;\n",
    ])
    func restoresWhenPowerOutputUnparsable(output: String) async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params(powerReadMaxFailures: 4))
        #expect(await Self.waitUntil { box.sleepDisabled })
        try output.write(to: box.batt, atomically: true, encoding: .utf8)
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
        #expect(box.pmsetCalls.last == "0")
    }

    @Test func restoresWhenPowerCommandKeepsFailing() async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params(powerReadMaxFailures: 4))
        #expect(await Self.waitUntil { box.sleepDisabled })
        try FileManager.default.removeItem(at: box.batt)   // /bin/cat 回傳非 0
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
    }

    @Test func toleratesTemporaryPowerReadFailure() async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params(powerReadMaxFailures: 5))
        #expect(await Self.waitUntil { box.sleepDisabled })
        let good = try String(contentsOf: box.batt, encoding: .utf8)
        // 重複「短暫失敗後恢復」，總時間超過單次容錯；計數沒有歸零就會被提前結束。
        for _ in 0..<3 {
            try FileManager.default.removeItem(at: box.batt)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try good.write(to: box.batt, atomically: true, encoding: .utf8)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        #expect(Self.alive(pid), "暫時失敗不應結束看守程序")
        #expect(box.sleepDisabled)
        try Data().write(to: box.stop)
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
    }

    @Test func keepsRunningOnBatteryWithReadablePercent() async throws {
        let box = try Sandbox()
        try "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t55%; discharging;\n"
            .write(to: box.batt, atomically: true, encoding: .utf8)
        let pid = try box.launch(box.params(powerReadMaxFailures: 3))
        #expect(await Self.waitUntil { box.sleepDisabled })
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(Self.alive(pid))
        try Data().write(to: box.stop)
        #expect(await Self.waitUntil { !Self.alive(pid) })
    }

    @Test func restoresOnTerminate() async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params())
        #expect(await Self.waitUntil { box.sleepDisabled })
        kill(pid, SIGTERM)
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
    }

    @Test func exitsIfSomeoneElseRestored() async throws {
        let box = try Sandbox()
        let pid = try box.launch(box.params())
        #expect(await Self.waitUntil { box.sleepDisabled })
        try box.writeState(false)
        #expect(await Self.waitUntil { !Self.alive(pid) })
    }

    /// 走完整的 osascript `do shell script` 跳脫路徑（不使用管理員權限）。
    @Test func fullOsascriptPathWithoutAdmin() async throws {
        let box = try Sandbox()
        let runner = OsascriptRunner(useAdministratorPrivileges: false)
        let command = LidWatchdogScript(tools: box.tools).launchCommand(box.params())
        let result = await runner.runAsAdministrator(command, prompt: "測試「引號」\"")
        guard case .success(let out) = result, let pid = Int32(out) else {
            Issue.record("osascript 結果：\(result)")
            return
        }
        #expect(await Self.waitUntil { box.sleepDisabled })
        #expect(Self.alive(pid), "osascript 結束後看守程序仍應存活")
        try Data().write(to: box.stop)
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(!box.sleepDisabled)
    }

    @Test func osascriptFailureIsReported() async {
        let runner = OsascriptRunner(useAdministratorPrivileges: false)
        let result = await runner.runAsAdministrator("exit 3", prompt: "")
        if case .failed = result {} else { Issue.record("應回報失敗：\(result)") }
    }

    @Test func processProbeIdentifiesBash() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 5", LidWatchdogScript.processTag]
        try p.run()
        defer { p.terminate() }
        let snap = SystemLidProbe().process(p.processIdentifier)
        #expect(snap?.command == "bash")
        #expect(snap?.uid == getuid())
        #expect(abs((snap?.startTime ?? .distantPast).timeIntervalSinceNow) < 5)
        #expect(SystemLidProbe().process(999_999) == nil)
    }

    @Test func quoting() {
        #expect(ShellQuote.single("a'b") == "'a'\\''b'")
        #expect(AppleScriptQuote.string("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }
}
}
