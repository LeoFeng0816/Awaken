import Foundation
@testable import JingXingCore

final class FakeClock: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

struct InstantSleeper: Sleeper {
    func sleep(seconds: Double) async { await Task.yield() }
}

final class FakePower: PowerAssertionService {
    struct Held: Equatable { let id: AssertionID; let type: String; let timeout: TimeInterval? }
    var held: [Held] = []
    var nextID: AssertionID = 100
    var failCreate = false
    var createCount = 0

    func create(type: String, reason: String, timeout: TimeInterval?) -> Result<AssertionID, PowerAssertionError> {
        createCount += 1
        if failCreate { return .failure(PowerAssertionError(code: -536870199, operation: "建立電源 assertion")) }
        nextID += 1
        held.append(Held(id: nextID, type: type, timeout: timeout))
        return .success(nextID)
    }

    func release(_ id: AssertionID) -> Result<Void, PowerAssertionError> {
        guard let i = held.firstIndex(where: { $0.id == id }) else {
            return .failure(PowerAssertionError(code: -536870208, operation: "釋放電源 assertion"))
        }
        held.remove(at: i)
        return .success(())
    }
}

@MainActor
final class FakeLocker: ScreenLocking {
    var readinessValue: LockReadiness = .ready(method: "替身")
    var outcome: LockOutcome = .locked(method: "替身")
    var lockCalls = 0
    var accessRequests = 0
    func readiness() -> LockReadiness { readinessValue }
    func requestAccess() { accessRequests += 1 }
    func lockNow() async -> LockOutcome { lockCalls += 1; return outcome }
}

/// 模擬 IOPMrootDomain、電源與看守程序的狀態。
final class FakeProbe: LidSystemProbe {
    var sleepDisabledValue: Bool? = false
    var clamshellValue: ClamshellInfo? = ClamshellInfo(closed: false)
    var powerValue = PowerSourceInfo(source: .ac, batteryPercent: 80)
    var thermalValue: ThermalLevel = .nominal
    var processes: [Int32: ProcessSnapshot] = [:]

    func sleepDisabled() -> Bool? { sleepDisabledValue }
    func clamshell() -> ClamshellInfo? { clamshellValue }
    func powerSource() -> PowerSourceInfo { powerValue }
    func thermal() -> ThermalLevel { thermalValue }
    func process(_ pid: Int32) -> ProcessSnapshot? { processes[pid] }
}

final class MemoryFiles: LidSessionFiles {
    var record: LidSessionRecord?
    var touched: [String] = []
    var stopRequests: [String] = []
    var failStop = false
    var onStop: ((String) -> Void)?

    func prepare(token: String) throws -> (stop: String, heartbeat: String) {
        ("/fake/lid-\(token).stop", "/fake/lid-\(token).heartbeat")
    }
    func touch(_ path: String) { touched.append(path) }
    func requestStop(_ path: String) throws {
        if failStop { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "磁碟錯誤"]) }
        stopRequests.append(path)
        onStop?(path)
    }
    func remove(_ record: LidSessionRecord) {}
    func loadRecord() -> LidSessionRecord? { record }
    func saveRecord(_ record: LidSessionRecord) throws { self.record = record }
    func clearRecord() { record = nil }
}

final class FakeRunner: PrivilegedRunner {
    var commands: [String] = []
    var handler: (String) -> PrivilegedResult = { _ in .cancelled }
    func runAsAdministrator(_ command: String, prompt: String) async -> PrivilegedResult {
        commands.append(command)
        return handler(command)
    }
}
