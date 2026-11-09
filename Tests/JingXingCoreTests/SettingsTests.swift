import Foundation
import Testing
@testable import JingXingCore

private func hasCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
}

/// 每個測試使用獨立的 UserDefaults suite，不碰本機 App 或全域偏好。
private final class TempDefaults {
    let name = "test.jingxing.settings.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    var store: LanguagePreferenceStore { LanguagePreferenceStore(defaults: defaults, domain: name) }
    var saved: [String]? { defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] }
    deinit { defaults.removePersistentDomain(forName: name) }
}

@MainActor
private final class FakeAccessibility: AccessibilityProbing {
    var allowed = false
    var systemLockAvailable = false
    var queries = 0
    func postEventAllowed() -> Bool { queries += 1; return allowed }
}

// MARK: - 語言偏好的保存與舊偏好相容

struct LanguagePreferenceStoreTests {
    @Test func defaultsToFollowSystem() {
        let t = TempDefaults()
        #expect(t.store.load() == .system)
        #expect(t.saved == nil)
    }

    @Test func persistsEachChoiceAsAppleLanguages() {
        let t = TempDefaults()
        t.store.save(.english)
        #expect(t.saved == ["en"])
        #expect(t.store.load() == .english)
        t.store.save(.traditionalChinese)
        #expect(t.saved == ["zh-Hant"])
        #expect(t.store.load() == .traditionalChinese)
        // 跟隨系統：移除本 App 的值，讓 Foundation 回到系統語言順序。
        t.store.save(.system)
        #expect(t.saved == nil)
        #expect(t.store.load() == .system)
    }

    @Test func survivesNewStoreInstance() {
        let t = TempDefaults()
        t.store.save(.english)
        let reopened = LanguagePreferenceStore(defaults: UserDefaults(suiteName: t.name)!, domain: t.name)
        #expect(reopened.load() == .english)
    }

    /// 舊版從「系統設定 › 語言與地區 › App」為靜醒指定的語言（同一個 AppleLanguages 值）。
    @Test(arguments: [
        (["zh-Hant-TW"], LanguagePreference.traditionalChinese),
        (["zh-Hant"], .traditionalChinese),
        (["zh-HK"], .traditionalChinese),
        (["en-GB"], .english),
        (["en"], .english),
        (["ja-JP", "zh-Hant-TW"], .traditionalChinese),
        // 只有不支援的語言時，App 實際使用英文，選項也如實顯示英文。
        (["ja-JP"], .english),
    ])
    func readsLegacyPerAppLanguage(_ legacy: [String], _ expected: LanguagePreference) {
        let t = TempDefaults()
        t.defaults.set(legacy, forKey: "AppleLanguages")
        #expect(t.store.load() == expected)
    }

    @Test func ignoresGlobalLanguageFallback() {
        // `object(forKey:)` 會回落到全域語言；儲存值只看本網域，所以沒設定時仍是跟隨系統。
        let t = TempDefaults()
        #expect(t.store.load() == .system)
    }

    @Test func emptyListMeansSystem() {
        let t = TempDefaults()
        t.defaults.set([String](), forKey: "AppleLanguages")
        #expect(t.store.load() == .system)
    }

    @Test(arguments: [
        (LanguagePreference.system, ["zh-Hant-TW", "en-US"], AppLanguage.traditionalChinese),
        (.system, ["en-US", "zh-Hant-TW"], .english),
        (.system, ["ja-JP"], .english),
        (.english, ["zh-Hant-TW"], .english),
        (.traditionalChinese, ["en-US"], .traditionalChinese),
    ])
    func effectiveLanguage(_ pref: LanguagePreference, _ system: [String], _ expected: AppLanguage) {
        #expect(pref.effectiveLanguage(systemPreferences: system) == expected)
    }

    /// 寫入的值必須能讓真正的 .app 結構選到對應的 lproj（與 Finder／選單中的 App 名稱一致）。
    @Test func savedValueSelectsBundleLocalization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jingxing-settings-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        for lproj in ["zh-Hant.lproj", "en.lproj"] {
            try FileManager.default.createDirectory(at: resources.appendingPathComponent(lproj), withIntermediateDirectories: true)
        }
        let plist: [String: Any] = ["CFBundleIdentifier": "test.jingxing.settings", "CFBundleDevelopmentRegion": "en",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: root))
        for pref in [LanguagePreference.english, .traditionalChinese] {
            let list = try #require(pref.appleLanguages)
            // 個別 App 語言排在系統語言前面（Foundation 的實際行為）。
            #expect(AppLanguage.resolve(bundle: bundle, preferences: list + ["ja-JP"]) == pref.effectiveLanguage(systemPreferences: []))
        }
    }
}

// MARK: - 設定狀態

@MainActor @Suite(.language(.traditionalChinese))
struct SettingsStateTests {
    private func make(_ t: TempDefaults, running: AppLanguage = .traditionalChinese,
                      system: [String] = ["zh-Hant-TW"], probe: FakeAccessibility = FakeAccessibility(),
                      opened: @escaping @MainActor (URL) -> Void = { _ in }) -> SettingsState {
        SettingsState(store: t.store, probe: probe, runningLanguage: running,
                      version: AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]),
                      systemLanguages: { system }, open: opened)
    }

    @Test func selectionPersistsAndRequiresManualRestart() {
        let t = TempDefaults()
        let s = make(t)
        #expect(s.languagePreference == .system)
        #expect(s.restartNotice == nil)
        s.languagePreference = .english
        #expect(t.saved == ["en"])
        #expect(s.nextLanguage == .english)
        #expect(s.restartNotice?.contains("不會自動結束") == true)
        #expect(s.restartNotice?.contains("重新開啟") == true)
        // 選回與目前相同的語言：不需要重新開啟。
        s.languagePreference = .traditionalChinese
        #expect(s.restartNotice == nil)
        s.languagePreference = .system
        #expect(t.saved == nil)
        #expect(s.restartNotice == nil)
    }

    @Test func followSystemNoticeDependsOnSystemLanguage() {
        let t = TempDefaults()
        t.store.save(.traditionalChinese)
        let s = make(t, running: .traditionalChinese, system: ["en-US"])
        #expect(s.languagePreference == .traditionalChinese)
        s.languagePreference = .system
        #expect(s.nextLanguage == .english)
        #expect(s.restartNotice != nil)
    }

    @Test func loadsLegacyPreferenceAtInit() {
        let t = TempDefaults()
        t.defaults.set(["en-GB"], forKey: "AppleLanguages")
        let s = make(t, running: .english)
        #expect(s.languagePreference == .english)
        #expect(s.restartNotice == nil)
        // 只是讀取不會改寫舊值。
        #expect(t.saved == ["en-GB"])
    }

    @Test func refreshReflectsRealPermissionChangesWithoutRequesting() {
        let t = TempDefaults()
        let probe = FakeAccessibility()
        var opened: [URL] = []
        let s = make(t, probe: probe, opened: { opened.append($0) })
        #expect(s.accessibility.granted == false)
        #expect(s.accessibility.isNeeded)
        probe.allowed = true
        #expect(s.accessibility.granted == false)   // 尚未重新查詢
        s.refresh()
        #expect(s.accessibility.granted)
        probe.allowed = false
        s.refresh()
        #expect(s.accessibility.granted == false)
        #expect(probe.queries >= 3)
        // 查詢與重新整理都不會開啟任何頁面或要求授權。
        #expect(opened.isEmpty)
        s.openAccessibilitySettings()
        #expect(opened == [SystemSettingsLink.accessibility])
        s.openLanguageSettings()
        #expect(opened.last == SystemSettingsLink.languageAndRegion)
    }

    @Test func refreshPicksUpExternalLanguageChange() {
        let t = TempDefaults()
        let s = make(t)
        // 使用者在系統設定的「App」區塊為靜醒指定英文。
        t.defaults.set(["en"], forKey: "AppleLanguages")
        s.refresh()
        #expect(s.languagePreference == .english)
        #expect(t.saved == ["en"])
    }

    @Test func accessibilityLinkTargetsPrivacyPane() {
        #expect(SystemSettingsLink.accessibility.scheme == "x-apple.systempreferences")
        #expect(SystemSettingsLink.accessibility.absoluteString.hasSuffix("Privacy_Accessibility"))
    }

    @Test func versionDisplay() {
        let s = make(TempDefaults())
        #expect(s.version.display == "版本 0.1.0（1）")
        #expect(AppVersionInfo(infoDictionary: nil).display.contains("開發版"))
    }
}

// MARK: - 權限說明（真實、不虛構）

struct PermissionTextTests {
    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func accessibilityDetailMatchesRealState(_ granted: Bool, _ systemLock: Bool) {
        let status = AccessibilityStatus(granted: granted, systemLockAvailable: systemLock)
        AppLanguage.$override.withValue(.traditionalChinese) {
            #expect(status.title == (granted ? "已允許" : "未允許"))
            if !granted && systemLock { #expect(status.detail.contains("不保證")) }
            if !granted && !systemLock { #expect(status.detail.contains("只有在你開始上鎖倒數時")) }
        }
        AppLanguage.$override.withValue(.english) {
            #expect(status.title == (granted ? "Allowed" : "Not allowed"))
            #expect(!hasCJK(status.detail))
        }
    }

    @Test func administratorTextIsPerUseAndNotPersistent() {
        AppLanguage.$override.withValue(.traditionalChinese) {
            let text = PermissionText.administratorDetail
            #expect(text.contains("只有在你開啟"))
            #expect(text.contains("不會保存"))
            #expect(text.contains("每次啟用都會重新詢問"))
            #expect(PermissionText.administratorStatus(lidEngaged: false).contains("是否需要還原"))
        }
        AppLanguage.$override.withValue(.english) {
            let text = PermissionText.administratorDetail
            #expect(text.contains("only when"))
            #expect(text.contains("not stored"))
            #expect(!hasCJK(text))
        }
    }

    @Test func englishSettingsTextsHaveNoChinese() {
        AppLanguage.$override.withValue(.english) {
            let texts = [
                LanguageSettingsText.explanation,
                LanguageSettingsText.restartNotice(running: .traditionalChinese, next: .english) ?? "",
                PermissionText.accessibilityPurpose,
                PermissionText.administratorTitle,
                PermissionText.administratorStatus(lidEngaged: true),
                PermissionText.noOtherPermissions,
                LanguagePreference.system.title,
                AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.0"]).display,
            ]
            for text in texts { #expect(!text.isEmpty); #expect(!hasCJK(text), "\(text)") }
            // 切換到中文的提示中，語言名稱本身可以是中文。
            #expect(LanguageSettingsText.restartNotice(running: .english, next: .traditionalChinese)?.contains("Traditional Chinese") == true)
        }
    }

    @Test func languageOptionNamesAreInTheirOwnLanguage() {
        for lang in [AppLanguage.english, .traditionalChinese] {
            AppLanguage.$override.withValue(lang) {
                #expect(LanguagePreference.traditionalChinese.title == "繁體中文")
                #expect(LanguagePreference.english.title == "English")
            }
        }
        AppLanguage.$override.withValue(.traditionalChinese) { #expect(LanguagePreference.system.title == "跟隨系統") }
        AppLanguage.$override.withValue(.english) { #expect(LanguagePreference.system.title == "Follow System") }
    }

    @Test func restartNoticeOnlyWhenLanguageChanges() {
        #expect(LanguageSettingsText.restartNotice(running: .english, next: .english) == nil)
        #expect(LanguageSettingsText.restartNotice(running: .traditionalChinese, next: .traditionalChinese) == nil)
        #expect(LanguageSettingsText.restartNotice(running: .english, next: .traditionalChinese) != nil)
    }
}
