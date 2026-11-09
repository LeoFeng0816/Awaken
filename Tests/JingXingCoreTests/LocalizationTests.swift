import Foundation
import Testing
@testable import JingXingCore

private func hasCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
}

// MARK: - 語言選擇

struct AppLanguageResolutionTests {
    @Test(arguments: [
        (["en-TW", "zh-Hant-TW"], AppLanguage.english),
        (["en-US"], .english),
        (["en-GB", "zh-Hant-TW"], .english),
        (["zh-Hant-TW"], .traditionalChinese),
        (["zh-Hant-TW", "en-US"], .traditionalChinese),
        (["zh-HK"], .traditionalChinese),
        (["fr-FR", "zh-Hant-TW"], .traditionalChinese),
        (["ja-JP", "en-US"], .english),
        // 不支援的語言（含簡體中文）：Foundation 的預設選擇是英文。
        (["ja-JP"], .english),
        (["zh-Hans-CN"], .english),
    ])
    func preferences(_ prefs: [String], _ expected: AppLanguage) {
        #expect(AppLanguage.resolve(preferences: prefs) == expected)
    }

    @Test func matchesIdentifiers() {
        #expect(AppLanguage.match("en") == .english)
        #expect(AppLanguage.match("en_GB") == .english)
        #expect(AppLanguage.match("zh-Hant") == .traditionalChinese)
        #expect(AppLanguage.match("zh_TW") == .traditionalChinese)
        #expect(AppLanguage.match("zh-Hant-HK") == .traditionalChinese)
        #expect(AppLanguage.match("zh-Hans") == nil)
        #expect(AppLanguage.match("eng") == nil)
        #expect(AppLanguage.match("Base") == nil)
    }

    /// 與實際 .app 相同的結構：個別 App 語言（AppleLanguages）決定使用哪個 lproj。
    @Test func followsBundleLocalizations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jingxing-l10n-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        for lproj in ["zh-Hant.lproj", "en.lproj"] {
            try FileManager.default.createDirectory(at: resources.appendingPathComponent(lproj), withIntermediateDirectories: true)
        }
        // 與 Resources/Info.plist 相同的開發地區。
        let plist: [String: Any] = ["CFBundleIdentifier": "test.jingxing.l10n", "CFBundleDevelopmentRegion": "en",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: root))
        #expect(Set(bundle.localizations).isSuperset(of: ["zh-Hant", "en"]))
        #expect(AppLanguage.resolve(bundle: bundle, preferences: ["en-TW", "zh-Hant-TW"]) == .english)
        #expect(AppLanguage.resolve(bundle: bundle, preferences: ["zh-Hant-TW", "en-TW"]) == .traditionalChinese)
        #expect(AppLanguage.resolve(bundle: bundle, preferences: ["zh-Hant"]) == .traditionalChinese)
        #expect(AppLanguage.resolve(bundle: bundle, preferences: ["ja-JP"]) == .english)
        #expect(AppLanguage.resolve(bundle: bundle, preferences: ["ja-JP", "zh-Hant-TW"]) == .traditionalChinese)
    }

    /// 專案的 Info.plist 必須宣告兩種語系，並允許 Finder 顯示在地化名稱。
    @Test func infoPlistDeclaresLocalizations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleLocalizations"] as? [String] == ["zh-Hant", "en"])
        #expect(plist["LSHasLocalizedDisplayName"] as? Bool == true)
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        for (lproj, name) in [("zh-Hant", "靜醒"), ("en", "Awaken")] {
            let url = root.appendingPathComponent("Resources/\(lproj).lproj/InfoPlist.strings")
            let strings = try #require(NSDictionary(contentsOf: url) as? [String: String], "\(lproj) InfoPlist.strings")
            #expect(strings["CFBundleDisplayName"] == name)
            #expect(strings["CFBundleName"] == name)
        }
    }

    @Test func overrideIsScopedToTask() async {
        AppLanguage.$override.withValue(.english) {
            #expect(L("中", "en") == "en")
            AppLanguage.$override.withValue(.traditionalChinese) {
                #expect(L("中", "en") == "中")
            }
            #expect(AppLanguage.current == .english)
        }
    }

    @Test func appNames() {
        #expect(AppLanguage.english.appName == "Awaken")
        #expect(AppLanguage.traditionalChinese.appName == "靜醒")
    }
}

// MARK: - 動態時間

@Suite(.language(.english))
struct EnglishTimeTextTests {
    @Test func durations() {
        #expect(TimeText.durationLabel(60) == "1 minute")
        #expect(TimeText.durationLabel(1800) == "30 minutes")
        #expect(TimeText.durationLabel(3600) == "1 hour")
        #expect(TimeText.durationLabel(7200) == "2 hours")
        #expect(TimeText.durationLabel(5400) == "1.5 hours")
        #expect(TimeText.durationLabel(3600 + 15 * 60) == "1 hour 15 minutes")
        #expect(AwakeDuration.indefinite.label == "Until stopped")
        #expect(AwakeDuration.presets.map(\.label) == ["30 minutes", "1 hour", "2 hours", "4 hours", "8 hours", "Until stopped"])
    }

    @Test func remaining() {
        #expect(TimeText.remaining(30) == "less than 1 min")
        #expect(TimeText.remaining(12 * 60) == "12 min")
        #expect(TimeText.remaining(3600) == "1 hr")
        #expect(TimeText.remaining(3600 + 23 * 60) == "1 hr 23 min")
        #expect(TimeText.compactRemaining(30) == "<1m")
        #expect(TimeText.compactRemaining(45 * 60) == "45m")
        #expect(TimeText.compactRemaining(3600 + 5 * 60) == "1:05")
    }

    @Test func clockFollowsEnglishLocale() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 0)))
        let today = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 22, minute: 45)))
        let tomorrow = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 8, minute: 30)))
        let later = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 8, minute: 30)))
        let us = Locale(identifier: "en_US")
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(norm(TimeText.clock(today, relativeTo: now, calendar: cal, locale: us)) == "10:45 PM")
        #expect(norm(TimeText.clock(tomorrow, relativeTo: now, calendar: cal, locale: us)) == "tomorrow, 8:30 AM")
        #expect(norm(TimeText.clock(later, relativeTo: now, calendar: cal, locale: us)) == "Nov 5, 8:30 AM")
        let gb = Locale(identifier: "en_GB")
        #expect(TimeText.clock(today, relativeTo: now, calendar: cal, locale: gb) == "22:45")
        #expect(!hasCJK(TimeText.clock(later, relativeTo: now, calendar: cal)))
    }
}

@Suite(.language(.traditionalChinese))
struct ChineseTimeTextTests {
    /// 繁中格式維持原樣：固定 24 小時制，不受英文地區設定影響。
    @Test func clockUnchanged() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 0)))
        let today = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 22, minute: 45)))
        let tomorrow = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 8, minute: 30)))
        let later = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 8, minute: 30)))
        #expect(TimeText.clock(today, relativeTo: now, calendar: cal) == "22:45")
        #expect(TimeText.clock(tomorrow, relativeTo: now, calendar: cal) == "明天 08:30")
        #expect(TimeText.clock(later, relativeTo: now, calendar: cal) == "11月5日 08:30")
        #expect(TimeText.durationLabel(3600 + 15 * 60) == "1 小時 15 分鐘")
        #expect(AwakeDuration.indefinite.label == "直到手動停止")
        #expect(TimeText.compactRemaining(30) == "<1分")
    }
}

// MARK: - 安全警告與錯誤訊息（兩種語言都要完整）

@MainActor
struct SafetyTextTests {
    /// 合蓋模式確認對話框必須在兩種語言都包含每一項風險說明。
    @Test func lidConfirmationEnglish() async {
        AppLanguage.$override.withValue(.english) {
            let text = LidSleepController.confirmationText
            #expect(!hasCJK(text))
            for needle in ["pmset disablesleep", "entire Mac", "administrator password", "12 hours",
                           "\(LidSleepController.stopBattery)%", "cannot guarantee", "ventilated", "bag",
                           "force-terminated", "may remain", "restore it manually", "closed-display mode"] {
                #expect(text.contains(needle), "missing: \(needle)")
            }
        }
    }

    @Test func lidConfirmationChinese() async {
        AppLanguage.$override.withValue(.traditionalChinese) {
            let text = LidSleepController.confirmationText
            for needle in ["pmset disablesleep", "整台電腦", "管理員密碼", "12 小時", "\(LidSleepController.stopBattery)%",
                           "不能保證", "通風", "包包", "強制終止", "殘留", "手動還原", "外接螢幕合蓋模式"] {
                #expect(text.contains(needle), "缺少：\(needle)")
            }
        }
    }

    @Test func adminPromptsAndQuitPrompt() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AppLanguage.$override.withValue(.english) {
            let admin = LidSleepController.adminPrompt
            #expect(!hasCJK(admin) && admin.contains("disablesleep") && admin.contains("restore"))
            for running in [true, false] {
                let p = LidQuitPrompt(reason: "Reason.", watchdogRunning: running, latestRestore: now, now: now)
                #expect(!hasCJK(p.title + p.body + p.cancelTitle + p.quitTitle))
                #expect(p.body.contains("sudo pmset -a disablesleep 0"))
                #expect(p.body.contains("Restore System Sleep Now"))
                #expect(p.cancelTitle == "Cancel Quit" && p.quitTitle == "Quit Anyway")
                #expect(p.body.contains(running ? "continue trying to restore" : "will not be restored automatically"))
            }
        }
        AppLanguage.$override.withValue(.traditionalChinese) {
            let p = LidQuitPrompt(reason: "原因。", watchdogRunning: false, latestRestore: now, now: now)
            #expect(p.title == "系統睡眠設定尚未確認還原")
            #expect(p.body.contains("立即還原系統睡眠") && p.body.contains("sudo pmset -a disablesleep 0"))
            #expect(p.cancelTitle == "取消結束" && p.quitTitle == "仍然結束")
        }
    }

    @Test func enumeratedMessagesAreFullyTranslated() async {
        AppLanguage.$override.withValue(.english) {
            var texts: [String] = AwakeMode.allCases.flatMap { [$0.title, $0.detail] }
            texts += [ThermalLevel.nominal, .fair, .serious, .critical].map(\.title)
            let reasons: [LidSleepController.StopReason] = [.manual, .expired, .lowBattery, .thermal, .powerUnknown, .quitting]
            texts += reasons.compactMap(\.message) + reasons.compactMap(\.attemptMessage)
            texts += [AwakeController.assertionReason, IdleLockGuardController.assertionReason,
                      PowerAssertionError(code: -536870199, operation: "Create power assertion").message]
            for t in texts { #expect(!hasCJK(t), "untranslated: \(t)") }
            #expect(PowerAssertionError(code: -536870199, operation: "Create power assertion").message
                    == "Create power assertion failed (IOReturn 0xE00002C9)")
            #expect(AwakeMode.systemOnly.detail.contains("not guaranteed"))
        }
        AppLanguage.$override.withValue(.traditionalChinese) {
            #expect(AwakeController.assertionReason == "靜醒：使用者要求保持清醒")
            #expect(IdleLockGuardController.assertionReason == "靜醒：限時防止閒置自動上鎖")
            #expect(PowerAssertionError(code: -536870199, operation: "建立電源 assertion").message
                    == "建立電源 assertion失敗（IOReturn 0xE00002C9）")
            #expect(LidSleepController.StopReason.lowBattery.message == "電池電量過低，已停止合蓋模式並還原系統睡眠設定。")
        }
    }
}

// MARK: - 實際流程的英文訊息（與繁中測試相同情境）

@MainActor @Suite(.language(.english))
struct EnglishFlowTests {
    let clock = FakeClock()
    let probe = FakeProbe()
    let files = MemoryFiles()
    let runner = FakeRunner()

    func makeLid() -> LidSleepController {
        LidSleepController(probe: probe, files: files, runner: runner, clock: clock,
                           sleeper: InstantSleeper(), appPID: 4242, confirmTimeout: 2, stopTimeout: 2)
    }

    @Test func lidPreflightMessages() async {
        probe.powerValue = PowerSourceInfo(source: .battery, batteryPercent: 12)
        let c = makeLid()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(c.message == "Battery is at 12%. Lid-closed mode will not start below 20%. Connect power first.")

        probe.powerValue = .unknown
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(c.message?.contains("Cannot determine power or battery status") == true)

        probe.powerValue = PowerSourceInfo(source: .ac, batteryPercent: 80)
        probe.thermalValue = .serious
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(c.message == "System temperature is high. Lid-closed mode will not start for now.")
        #expect(runner.commands.isEmpty, "preflight failures must not request admin rights")
    }

    @Test func lidCancelAndFailureMessages() async {
        runner.handler = { _ in .cancelled }
        let c = makeLid()
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(c.message == "Administrator authorization was cancelled; no system settings were changed.")

        runner.handler = { _ in .failed("boom") }
        #expect(!(await c.start(until: clock.now().addingTimeInterval(3600))))
        #expect(c.message?.hasPrefix("Could not start the lid-closed watchdog: boom") == true)
        #expect(!hasCJK(c.message ?? ""))

        probe.clamshellValue = nil
        c.refresh()
        if case .unavailable(let reason) = c.state { #expect(reason == "This Mac has no closable display lid.") }
        else { Issue.record("should be unavailable: \(c.state)") }
    }

    @Test func lidRecoveryMessages() async {
        files.record = LidSessionRecord(token: "t", appPID: 1, originalSleepDisabled: false,
                                        requestedAt: clock.now(), deadline: clock.now(),
                                        stopFile: "/fake/stop", heartbeatFile: "/fake/hb")
        probe.sleepDisabledValue = true
        let c = makeLid()
        await c.recoverOnLaunch()
        guard case .needsRecovery(let reason) = c.state else { Issue.record("should need recovery: \(c.state)"); return }
        #expect(!hasCJK(reason) && reason.contains("did not end normally"))

        runner.handler = { [probe] _ in probe.sleepDisabledValue = false; return .success("") }
        await c.forceRestore()
        #expect(c.message == "System sleep settings were restored.")
        #expect(runner.commands == ["/usr/bin/pmset -a disablesleep 0"])
    }

    @Test func lockAndAwakeErrors() async {
        let locker = FakeLocker()
        locker.readinessValue = .needsAccessibility
        let t = LockTimerController(locker: locker, clock: clock)
        #expect(!t.schedule(after: 60))
        if case .failed(let m) = t.state { #expect(m.contains("Accessibility") && !hasCJK(m)) } else { Issue.record("should fail") }

        locker.readinessValue = .ready(method: "fake")
        locker.outcome = .failed("shortcut disabled")
        t.schedule(after: 10)
        clock.advance(10)
        await t.evaluate()
        #expect(t.state == .failed("Scheduled lock failed: shortcut disabled"))

        let guardController = IdleLockGuardController(power: FakePower(), clock: clock)
        #expect(!guardController.start(duration: 30))
        #expect(guardController.lastError == "Duration must be at least one minute.")
        #expect(!guardController.start(duration: 48 * 3600))
        #expect(guardController.lastError == "Duration can be at most 24 hours.")
    }
}
