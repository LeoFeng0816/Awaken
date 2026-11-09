import Foundation
import Observation
import ApplicationServices

// MARK: - 介面語言偏好

/// 設定中的語言選項。
///
/// 只使用 macOS 原本的機制：本 App 偏好網域中的 `AppleLanguages`。
/// 這與「系統設定 › 一般 › 語言與地區 › App」為個別 App 指定語言時寫入的是同一個值，
/// 所以舊版（v0.1.0 以前）在系統設定中指定的語言會直接顯示為目前選項，兩邊也不會互相矛盾。
/// 新值在下次開啟 App 時由 Foundation 讀取，介面、對話框與選單中的 App 名稱（lproj）一起切換。
public enum LanguagePreference: String, CaseIterable, Sendable, Identifiable {
    case system
    case traditionalChinese = "zh-Hant"
    case english = "en"

    public var id: String { rawValue }

    /// 選項名稱：語言名稱一律以該語言本身顯示，方便看不懂目前介面語言的人辨認。
    public var title: String {
        switch self {
        case .system: return L("跟隨系統", "Follow System")
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    /// 寫入 `AppleLanguages` 的值；跟隨系統時不寫入。
    var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .traditionalChinese: return ["zh-Hant"]
        case .english: return ["en"]
        }
    }

    /// 在指定的系統偏好語言下，下次開啟時會使用的介面語言。
    public func effectiveLanguage(systemPreferences: [String]) -> AppLanguage {
        switch self {
        case .system: return AppLanguage.resolve(preferences: systemPreferences)
        case .traditionalChinese: return .traditionalChinese
        case .english: return .english
        }
    }
}

/// 讀寫本 App 偏好網域中的 `AppleLanguages`。不碰全域（NSGlobalDomain）設定，也不影響其他 App。
public struct LanguagePreferenceStore {
    public static let key = "AppleLanguages"
    private let defaults: UserDefaults
    private let domain: String

    /// - Parameters:
    ///   - defaults: App 使用 `.standard`；測試使用獨立的 suite。
    ///   - domain: 偏好網域名稱（App 為 bundle identifier；suite 為 suite 名稱）。
    public init(defaults: UserDefaults, domain: String) {
        self.defaults = defaults
        self.domain = domain
    }

    /// App 用的預設值：bundle identifier 網域。
    public static func standard(bundle: Bundle = .main) -> LanguagePreferenceStore {
        LanguagePreferenceStore(defaults: .standard,
                                domain: bundle.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    /// 只看本 App 自己網域中的值（`defaults.object(forKey:)` 會回落到全域語言，不能用來判斷）。
    public func load() -> LanguagePreference {
        guard let list = defaults.persistentDomain(forName: domain)?[Self.key] as? [String], !list.isEmpty else {
            return .system
        }
        // 舊偏好可能是 zh-Hant-TW、en-GB 或多個語言；以 App 實際會選到的語言為準。
        return AppLanguage.resolve(preferences: list) == .english ? .english : .traditionalChinese
    }

    public func save(_ preference: LanguagePreference) {
        if let list = preference.appleLanguages {
            defaults.set(list, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }

    /// 系統（不含本 App 個別設定）的偏好語言。
    public static func systemPreferredLanguages() -> [String] {
        (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String])
            ?? Locale.preferredLanguages
    }
}

/// 設定畫面中與語言相關的文字。
public enum LanguageSettingsText {
    /// 變更需要重新開啟；App 不會自行結束。
    public static func restartNotice(running: AppLanguage, next: AppLanguage) -> String? {
        guard running != next else { return nil }
        if next == .english {
            return L("已儲存。下次開啟時會改用 English（Awaken）。靜醒不會自動結束，以免中斷正在進行的保持清醒、倒數或合蓋模式；方便時請自行結束並重新開啟。",
                     "Saved. Awaken will use English the next time it opens. Awaken will not quit on its own, so your Keep Awake, timers, and lid-closed mode are not interrupted. Quit and reopen Awaken when convenient.")
        }
        return L("已儲存。下次開啟時會改用繁體中文（靜醒）。靜醒不會自動結束，以免中斷正在進行的保持清醒、倒數或合蓋模式；方便時請自行結束並重新開啟。",
                 "Saved. Awaken will use Traditional Chinese (靜醒) the next time it opens. Awaken will not quit on its own, so your Keep Awake, timers, and lid-closed mode are not interrupted. Quit and reopen Awaken when convenient.")
    }

    public static var explanation: String {
        L("「跟隨系統」依「系統設定 › 一般 › 語言與地區」的偏好語言順序；沒有繁體中文或英文時使用英文。此選項與該頁「App」區塊為靜醒指定的語言是同一個設定。Finder 中的 App 名稱（靜醒／Awaken）依 macOS 系統語言顯示，不受此選項影響。",
          "“Follow System” uses the preferred language order in System Settings › General › Language & Region, falling back to English when neither English nor Traditional Chinese is listed. This is the same setting as choosing a language for Awaken in the Applications section of that page. The app name shown in Finder follows the macOS system language and is not affected by this option.")
    }
}

// MARK: - 權限

/// 「輔助使用」的實際狀態，由系統查詢（`CGPreflightPostEventAccess`），不自行推測或快取。
public struct AccessibilityStatus: Equatable, Sendable {
    /// 系統是否已允許本 App 送出鍵盤事件（列在「隱私權與安全性 › 輔助使用」）。
    public var granted: Bool
    /// 系統鎖定函式可用時，自動上鎖不需要這項權限。
    public var systemLockAvailable: Bool

    public init(granted: Bool, systemLockAvailable: Bool) {
        self.granted = granted
        self.systemLockAvailable = systemLockAvailable
    }

    public var isNeeded: Bool { !systemLockAvailable }

    public var title: String {
        granted ? L("已允許", "Allowed") : L("未允許", "Not allowed")
    }

    public var detail: String {
        switch (granted, systemLockAvailable) {
        case (true, _):
            return L("自動上鎖在需要時可送出 Control-Command-Q。若不再需要，可在系統設定中關閉。",
                     "Scheduled Lock can send Control-Command-Q when needed. You can turn this off in System Settings if you no longer need it.")
        case (false, true):
            return L("已偵測到系統鎖定函式，但不保證能成功上鎖。如果它失敗，靜醒需要這項權限才能改用 Control-Command-Q；否則會顯示上鎖失敗。",
                     "A system lock function was found, but it may not work. If it fails, Awaken needs this permission to try Control-Command-Q; otherwise it reports that locking failed.")
        case (false, false):
            return L("自動上鎖需要這項權限才能送出 Control-Command-Q。只有在你開始上鎖倒數時，macOS 才會詢問；也可以現在開啟系統設定允許「靜醒」。",
                     "Scheduled Lock needs this permission to send Control-Command-Q. macOS asks only when you start a lock timer; you can also open System Settings now and allow Awaken.")
        }
    }
}

public enum PermissionText {
    public static var accessibilityPurpose: String {
        L("用途：只在自動上鎖、而且系統鎖定螢幕功能無法使用時，送出 Apple 提供的 Control-Command-Q 鎖定快捷鍵。靜醒不讀取鍵盤輸入或螢幕內容。",
          "Purpose: only used by Scheduled Lock to send Apple’s Control-Command-Q lock shortcut when the system screen lock function is unavailable. Awaken does not read your keystrokes or screen.")
    }

    public static var administratorTitle: String { L("管理員授權（合蓋模式）", "Administrator Approval (Lid-Closed Mode)") }

    public static var administratorDetail: String {
        L("只有在你開啟「合上螢幕後繼續運作」並開始保持清醒時，才會出現 macOS 的密碼／Touch ID 對話框，用來暫時執行 pmset disablesleep。授權只用於該次，不會保存、不安裝背景輔助程式或登入項目；每次啟用都會重新詢問；正常結束由啟用時的看守程序還原，只有「立即還原系統睡眠」會再次詢問。",
          "The macOS password / Touch ID dialog appears only when you turn on “Keep Running with Lid Closed” and Keep Awake starts, to run pmset disablesleep temporarily. The approval is used for that one time; it is not stored, and no background helper or login item is installed. You are asked again every time. Normal stops are restored by the watchdog started with that approval; only “Restore System Sleep Now” asks again.")
    }

    public static func administratorStatus(lidEngaged: Bool) -> String {
        lidEngaged
            ? L("合蓋模式正在啟動、執行或停止；請查看主面板的實際狀態。", "Lid-closed mode is starting, running, or stopping; check its status in the main panel.")
            : L("請在主面板查看合蓋模式狀態與是否需要還原；此處不代表已確認系統睡眠設定。", "Check the main panel for the lid-closed mode status or required recovery; this view does not confirm the system sleep setting.")
    }

    public static var noOtherPermissions: String {
        L("靜醒不需要網路、通知、螢幕錄製、檔案或其他權限，也不會在啟動時要求任何權限。",
          "Awaken does not need network, notification, screen recording, file, or other permissions, and never asks for permissions at launch.")
    }
}

/// 系統設定的深層連結。
public enum SystemSettingsLink {
    public static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let languageAndRegion = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
}

// MARK: - 版本

public struct AppVersionInfo: Equatable, Sendable {
    public var version: String?
    public var build: String?

    public init(infoDictionary: [String: Any]?) {
        version = infoDictionary?["CFBundleShortVersionString"] as? String
        build = infoDictionary?["CFBundleVersion"] as? String
    }

    public var display: String {
        guard let version else { return L("開發版（非 .app 執行）", "Development build (not running from an .app)") }
        if let build, !build.isEmpty { return L("版本 \(version)（\(build)）", "Version \(version) (\(build))") }
        return L("版本 \(version)", "Version \(version)")
    }
}

// MARK: - 設定狀態（App 的設定視窗使用；可注入替身測試）

/// 查詢「輔助使用」實際狀態的抽象。只查詢，不要求授權。
@MainActor
public protocol AccessibilityProbing: AnyObject {
    func postEventAllowed() -> Bool
    var systemLockAvailable: Bool { get }
}

@MainActor
public final class SystemAccessibilityProbe: AccessibilityProbing {
    private let locker: SystemScreenLocker
    public init(locker: SystemScreenLocker) { self.locker = locker }
    /// 系統的真正授權狀態；不會顯示任何提示。
    public func postEventAllowed() -> Bool { CGPreflightPostEventAccess() }
    public var systemLockAvailable: Bool { locker.hasSystemLockFunction }
}

@MainActor
@Observable
public final class SettingsState {
    @ObservationIgnored private let store: LanguagePreferenceStore
    @ObservationIgnored private let probe: AccessibilityProbing
    @ObservationIgnored private let open: @MainActor (URL) -> Void
    @ObservationIgnored private let systemLanguages: () -> [String]
    /// 本次執行實際使用的介面語言（啟動時決定，執行中不變）。
    public let runningLanguage: AppLanguage
    public let version: AppVersionInfo

    public var languagePreference: LanguagePreference {
        didSet { if oldValue != languagePreference { store.save(languagePreference) } }
    }
    public private(set) var accessibility: AccessibilityStatus

    public init(store: LanguagePreferenceStore, probe: AccessibilityProbing,
                runningLanguage: AppLanguage = AppLanguage.current,
                version: AppVersionInfo = AppVersionInfo(infoDictionary: Bundle.main.infoDictionary),
                systemLanguages: @escaping () -> [String] = LanguagePreferenceStore.systemPreferredLanguages,
                open: @escaping @MainActor (URL) -> Void) {
        self.store = store
        self.probe = probe
        self.open = open
        self.systemLanguages = systemLanguages
        self.runningLanguage = runningLanguage
        self.version = version
        languagePreference = store.load()
        accessibility = AccessibilityStatus(granted: probe.postEventAllowed(), systemLockAvailable: probe.systemLockAvailable)
    }

    /// 下次開啟時會使用的語言。
    public var nextLanguage: AppLanguage {
        languagePreference.effectiveLanguage(systemPreferences: systemLanguages())
    }

    /// 需要重新開啟才會生效時的說明；不會結束 App。
    public var restartNotice: String? {
        LanguageSettingsText.restartNotice(running: runningLanguage, next: nextLanguage)
    }

    /// 重新查詢系統的實際授權狀態（使用者可能剛在系統設定中變更）。
    public func refresh() {
        let latest = AccessibilityStatus(granted: probe.postEventAllowed(), systemLockAvailable: probe.systemLockAvailable)
        if latest != accessibility { accessibility = latest }
        let saved = store.load()
        if saved != languagePreference { languagePreference = saved }
    }

    public func openAccessibilitySettings() { open(SystemSettingsLink.accessibility) }
    public func openLanguageSettings() { open(SystemSettingsLink.languageAndRegion) }
}
