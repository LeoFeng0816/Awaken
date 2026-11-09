import Foundation
import IOKit
import IOKit.pwr_mgt

/// 保持清醒的模式。
public enum AwakeMode: String, CaseIterable, Codable, Sendable {
    /// 電腦與螢幕都不因閒置而休眠。
    case systemAndDisplay
    /// 只防止電腦閒置睡眠；螢幕仍依系統設定關閉。
    case systemOnly

    public var title: String {
        switch self {
        case .systemAndDisplay: return L("電腦與螢幕保持清醒", "Keep Mac and display awake")
        case .systemOnly: return L("只讓電腦保持運作", "Keep Mac running only")
        }
    }

    public var detail: String {
        switch self {
        case .systemAndDisplay:
            return L("螢幕不會因閒置變暗或關閉。", "The display will not dim or turn off due to inactivity.")
        case .systemOnly:
            return L("電腦不會因閒置睡眠；螢幕仍會依「顯示器」設定的時間關閉，不保證立刻關閉。", "Your Mac will not sleep due to inactivity. The display still turns off according to your Display settings; it is not guaranteed to turn off right away.")
        }
    }

    /// IOKit assertion 類型字串（等同 kIOPMAssertionTypePreventUserIdle…）。
    public var assertionType: String {
        switch self {
        case .systemAndDisplay: return "PreventUserIdleDisplaySleep"
        case .systemOnly: return "PreventUserIdleSystemSleep"
        }
    }
}

public typealias AssertionID = UInt32

public struct PowerAssertionError: Error, Equatable, Sendable {
    public let code: Int32
    public let operation: String
    public init(code: Int32, operation: String) {
        self.code = code
        self.operation = operation
    }
    public var message: String {
        String(format: L("%@失敗（IOReturn 0x%08X）", "%@ failed (IOReturn 0x%08X)"), operation, UInt32(bitPattern: code))
    }
}

/// 電源 assertion 的抽象，方便以假物件測試。
public protocol PowerAssertionService: AnyObject {
    func create(type: String, reason: String, timeout: TimeInterval?) -> Result<AssertionID, PowerAssertionError>
    func release(_ id: AssertionID) -> Result<Void, PowerAssertionError>
}

/// 真正的 IOKit 實作。只建立、釋放本程式自己的 assertion，不碰其他程式的 assertion。
/// 另外替有時限的 assertion 設定系統端逾時（TimeoutActionRelease），即使本程式的計時器被延遲，
/// powerd 也會在截止時間後自動釋放；程式結束時系統也會自動釋放該程序持有的 assertion。
public final class IOKitPowerAssertionService: PowerAssertionService {
    /// 系統端逾時比 App 的截止時間晚一點，正常情況由 App 自己準時釋放。
    public static let systemTimeoutSlack: TimeInterval = 30

    public init() {}

    public func create(type: String, reason: String, timeout: TimeInterval?) -> Result<AssertionID, PowerAssertionError> {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            return .failure(PowerAssertionError(code: result, operation: L("建立電源 assertion", "Create power assertion")))
        }
        if let timeout {
            if case .failure(let error) = setTimeout(id, timeout: timeout) {
                _ = IOPMAssertionRelease(id)
                return .failure(error)
            }
        }
        return .success(id)
    }

    /// 只在建立後立即呼叫；變更時長時改為「建立新 assertion → 釋放舊 assertion」，避免逾時起算點的歧義。
    private func setTimeout(_ id: AssertionID, timeout: TimeInterval?) -> Result<Void, PowerAssertionError> {
        // 0 代表不逾時。
        let seconds = timeout.map { max(1, $0 + Self.systemTimeoutSlack) } ?? 0
        let r1 = IOPMAssertionSetProperty(id, "TimeoutSeconds" as CFString, NSNumber(value: seconds))
        guard r1 == kIOReturnSuccess else {
            return .failure(PowerAssertionError(code: r1, operation: L("設定 assertion 逾時", "Set assertion timeout")))
        }
        let r2 = IOPMAssertionSetProperty(id, "TimeoutAction" as CFString, "TimeoutActionRelease" as CFString)
        guard r2 == kIOReturnSuccess else {
            return .failure(PowerAssertionError(code: r2, operation: L("設定 assertion 逾時動作", "Set assertion timeout action")))
        }
        return .success(())
    }

    public func release(_ id: AssertionID) -> Result<Void, PowerAssertionError> {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else {
            return .failure(PowerAssertionError(code: result, operation: L("釋放電源 assertion", "Release power assertion")))
        }
        return .success(())
    }
}
