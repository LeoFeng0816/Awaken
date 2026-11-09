import Foundation
import IOKit.pwr_mgt
import Testing
@testable import JingXingCore

/// 真正的 IOKit assertion：只建立並立刻釋放本測試程序自己的 assertion，不改任何永久設定。
@Suite(.language(.traditionalChinese))
struct IOKitAssertionTests {
    private func ownAssertionTypes() -> [String] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let map = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let mine = map[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.filter { ($0["AssertName"] as? String) == AwakeController.assertionReason }
            .compactMap { $0["AssertType"] as? String }
    }

    @Test(arguments: AwakeMode.allCases)
    func createAndReleaseWithTimeout(mode: AwakeMode) throws {
        let service = IOKitPowerAssertionService()
        let id = try service.create(type: mode.assertionType, reason: AwakeController.assertionReason, timeout: 120).get()
        #expect(ownAssertionTypes().contains(mode.assertionType))
        try service.release(id).get()
        #expect(!ownAssertionTypes().contains(mode.assertionType))
    }

    @Test func invalidTypeFailsHonestly() {
        let result = IOKitPowerAssertionService().create(type: "NotARealAssertionType", reason: "test", timeout: nil)
        if case .success(let id) = result {
            _ = IOPMAssertionRelease(id)
            Issue.record("不存在的類型不應成功")
        }
    }
}
