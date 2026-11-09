import AppKit
import SwiftUI
import JingXingCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var model: AppModel!
    private var quitInProgress = false
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只允許一個執行個體。
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !bundleID.isEmpty, !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        let clock = SystemTimeSource()
        let awake = AwakeController(power: IOKitPowerAssertionService(), clock: clock)
        let locker = SystemScreenLocker()
        let lock = LockTimerController(locker: locker, clock: clock)
        var lid = LidSleepController(probe: SystemLidProbe(),
                                     files: FileLidSessionFiles(directory: FileLidSessionFiles.defaultDirectory()),
                                     runner: OsascriptRunner(), clock: clock)
        #if DEBUG
        if CommandLine.arguments.contains("--debug-quit-alert") { lid = DebugQuitCheck.makeLid(clock: clock) }
        #endif
        let idleGuard = IdleLockGuardController(power: IOKitPowerAssertionService(), clock: clock)
        model = AppModel(awake: awake, lock: lock, lid: lid, idleGuard: idleGuard, clock: clock,
                         display: PmsetDisplaySleeper(), sessionLocked: { SystemScreenLocker.isSessionLocked() })

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let settings = SettingsState(store: .standard(), probe: SystemAccessibilityProbe(locker: locker),
                                     open: { NSWorkspace.shared.open($0) })
        settingsWindow = SettingsWindowController(settings: settings, lidEngaged: { [weak model] in model?.lid.isEngaged ?? false })
        let view = MenuView(model: model, confirmLid: { [weak self] in self?.confirmLid() ?? false },
                            openSettings: { [weak self] in self?.openSettings() },
                            quit: { NSApp.terminate(nil) })
            .environment(\.locale, AppLanguage.current.locale)
        popover.contentViewController = NSHostingController(rootView: view)

        model.onStatusChange = { [weak self] in self?.updateStatusItem() }
        model.launch()
        // Explicit one-shot launch option for starting the guard without opening the popover.
        if let index = CommandLine.arguments.firstIndex(of: "--guard-hours"),
           index + 1 < CommandLine.arguments.count,
           let hours = Double(CommandLine.arguments[index + 1]), hours.isFinite {
            _ = idleGuard.start(duration: hours * 3600, sessionLocked: SystemScreenLocker.isSessionLocked())
        }
        updateStatusItem()
        RunLoop.main.add(Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }, forMode: .common)
        #if DEBUG
        if CommandLine.arguments.contains("--debug-quit-alert") { DebugQuitCheck.run() }
        #endif
        if CommandLine.arguments.contains("--self-check") {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.selfCheck() }
            }
        }
    }

    /// 只讀的自我檢查：印出狀態列項目與預設狀態後正常結束（不變更任何設定）。
    private func selfCheck() {
        let button = statusItem.button
        let lines = [
            "statusItem.isVisible=\(statusItem.isVisible)",
            "button.exists=\(button != nil)",
            "button.image=\(button?.image != nil)",
            "button.accessibility=\(button?.accessibilityLabel() ?? "")",
            "button.window=\(button?.window.map { NSStringFromRect($0.frame) } ?? "nil")",
            "awake.isActive=\(model.awake.isActive)",
            "lock.state=\(model.lock.state)",
            "idleGuard.state=\(model.idleGuard.state)",
            "lid.state=\(model.lid.state)",
            "language=\(AppLanguage.current.rawValue)",
            "bundle.displayName=\(Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "")",
            "activationPolicy=\(NSApp.activationPolicy() == .accessory ? "accessory" : "other")",
        ]
        print(lines.joined(separator: "\n"))
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// 開發用：把面板離屏渲染成淺色／深色 PNG，供檢查版面。
    private func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = SettingsState(store: .standard(), probe: SystemAccessibilityProbe(locker: SystemScreenLocker()),
                                     open: { _ in })
        let pages: [(String, AnyView)] = [
            ("", AnyView(MenuView(model: model, confirmLid: { false }, openSettings: {}, quit: {}))),
            ("settings-", AnyView(SettingsView(settings: settings, lidEngaged: { false }))),
        ]
        for (prefix, page) in pages {
        for (base, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let name = prefix + base
            let view = NSHostingView(rootView: page
                .environment(\.locale, AppLanguage.current.locale)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = appearance == .aqua ? .windowBackgroundColor : NSColor(white: 0.15, alpha: 1)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            window.setContentSize(size)
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            window.orderBack(nil)
            view.display()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
            window.orderOut(nil)
            print("snapshot=\(dir.appendingPathComponent("\(name).png").path) size=\(NSStringFromSize(size))")
        }
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        settingsWindow?.show()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.tick()
        model.lid.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let model else { return }
        let awake = model.awake
        let symbol: String
        var accessibility = L("靜醒：", "Awaken: ")
        if model.lid.isEngaged {
            symbol = "laptopcomputer"
        } else if awake.isActive {
            symbol = "cup.and.saucer.fill"
        } else if model.idleGuard.isActive {
            symbol = "lock.slash"
        } else if model.lock.isScheduled {
            symbol = "lock"
        } else {
            symbol = "cup.and.saucer"
        }
        if awake.isActive {
            accessibility += L("正在保持清醒", "Keeping Awake")
            if let left = awake.remaining() {
                let text = TimeText.remaining(left)
                accessibility += L("，剩 \(text)", ", \(text) left")
            } else {
                accessibility += L("，直到手動停止", ", until stopped")
            }
        } else {
            accessibility += L("未啟用", "Inactive")
        }
        if model.lid.isEngaged { accessibility += L("，合蓋模式啟用中", ", lid-closed mode on") }
        if let end = model.idleGuard.deadline {
            let time = TimeText.clock(end, relativeTo: Date())
            accessibility += L("，防止閒置自動上鎖至 \(time)", ", preventing idle lock until \(time)")
            if model.idleGuard.isPaused { accessibility += L("（螢幕已鎖定，暫停中）", " (paused while the screen is locked)") }
        }
        if let left = model.lock.remaining() {
            let text = TimeText.remaining(left)
            accessibility += L("，\(text)後上鎖", ", locks in \(text)")
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
            ?? NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: accessibility)
        image?.isTemplate = true
        button.image = image
        if awake.isActive, let left = awake.remaining() {
            button.title = " " + TimeText.compactRemaining(left)
        } else if awake.isActive {
            button.title = " ∞"
        } else if let left = model.idleGuard.remaining() {
            button.title = " " + TimeText.compactRemaining(left)
        } else {
            button.title = ""
        }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        button.setAccessibilityLabel(accessibility)
        button.toolTip = accessibility
    }

    /// 開啟合蓋模式前的明確說明與確認。
    private func confirmLid() -> Bool {
        popover.performClose(nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("要讓 Mac 合上螢幕後繼續運作嗎？", "Keep your Mac running with its lid closed?")
        alert.informativeText = LidSleepController.confirmationText
        alert.addButton(withTitle: L("我了解，啟用", "I Understand, Enable"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.addButton(withTitle: L("Apple 說明…", "Apple Help…"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertThirdButtonReturn:
            let page = L("https://support.apple.com/zh-tw/102501", "https://support.apple.com/en-us/102501")
            if let url = URL(string: page) { NSWorkspace.shared.open(url) }
            return false
        default:
            return false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // 流程進行中再次要求結束時不可跳過還原確認。
        if quitInProgress { return .terminateCancel }
        if model.quitCoordinator.quitImmediatelyIfPossible() { return .terminateNow }
        quitInProgress = true
        Task { @MainActor in
            let shouldQuit = await model.quitCoordinator.run { [weak self] prompt in
                await self?.askAboutUnresolvedLid(prompt) ?? .cancelQuit
            }
            quitInProgress = false
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
            if !shouldQuit { showPopover() }
        }
        return .terminateLater
    }

    /// 透過 RunLoop 而非 Task 顯示對話框：在主佇列工作中執行巢狀 run loop 會讓其他主執行緒工作暫停。
    private func askAboutUnresolvedLid(_ prompt: LidQuitPrompt) async -> QuitCoordinator.Decision {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    continuation.resume(returning: self.runQuitAlert(prompt))
                }
            }
        }
    }

    private func runQuitAlert(_ prompt: LidQuitPrompt) -> QuitCoordinator.Decision {
        popover.performClose(nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = prompt.title
        alert.informativeText = prompt.body
        // 第一個按鈕（預設、Return）是較安全的取消結束；Esc 也對應取消。
        alert.addButton(withTitle: prompt.cancelTitle)
        alert.buttons[0].keyEquivalent = "\r"
        let quit = alert.addButton(withTitle: prompt.quitTitle)
        quit.keyEquivalent = ""
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .quitAnyway : .cancelQuit
    }
}

#if DEBUG
/// 只存在於 debug 建置：以暫存檔與假的系統探測走完整的結束對話框流程，不碰真實系統設定、不要求密碼。
@MainActor
enum DebugQuitCheck {
    final class Probe: LidSystemProbe {
        func sleepDisabled() -> Bool? { true }
        func clamshell() -> ClamshellInfo? { ClamshellInfo(closed: false) }
        func powerSource() -> PowerSourceInfo { PowerSourceInfo(source: .ac, batteryPercent: 80) }
        func thermal() -> ThermalLevel { .nominal }
        func process(_ pid: Int32) -> ProcessSnapshot? { nil }
    }
    final class Runner: PrivilegedRunner {
        func runAsAdministrator(_ command: String, prompt: String) async -> PrivilegedResult { .failed("debug") }
    }

    static func makeLid(clock: TimeSource) -> LidSleepController {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jingxing-debug-\(UUID().uuidString)")
        let files = FileLidSessionFiles(directory: dir)
        try? files.saveRecord(LidSessionRecord(token: "debug", appPID: 1, originalSleepDisabled: false,
                                               requestedAt: clock.now(), deadline: clock.now(),
                                               stopFile: dir.appendingPathComponent("stop").path,
                                               heartbeatFile: dir.appendingPathComponent("hb").path))
        return LidSleepController(probe: Probe(), files: files, runner: Runner(), clock: clock)
    }

    static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        RunLoop.main.add(Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated(body)
        }, forMode: .common)
    }

    static func report(_ text: String) { print(text); fflush(stdout) }

    /// NSApp.terminate 在等待回覆期間不會返回，所以要在呼叫前先排好下一步。
    static func run() {
        after(1.5) {
            report("step1 terminate -> 應顯示對話框")
            after(2) {
                report("step2 modalWindow=\(NSApp.modalWindow != nil) -> 選擇取消結束")
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                after(1.5) {
                    report("step3 仍在執行，modalWindow=\(NSApp.modalWindow != nil) -> 再次結束")
                    after(1.5) {
                        report("step4 modalWindow=\(NSApp.modalWindow != nil) -> 選擇仍然結束")
                        NSApp.stopModal(withCode: .alertSecondButtonReturn)
                    }
                    NSApp.terminate(nil)
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
