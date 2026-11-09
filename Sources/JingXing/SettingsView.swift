import AppKit
import SwiftUI
import JingXingCore

/// 設定視窗：語言、權限與版本資訊。
struct SettingsView: View {
    @Bindable var settings: SettingsState
    let lidEngaged: () -> Bool

    var body: some View {
        Form {
            languageSection
            accessibilitySection
            administratorSection
            aboutSection
        }
        .formStyle(.grouped)
        // 固定寬度、可捲動：小螢幕（13 吋）也能完整顯示，內容較長時在 Form 內捲動。
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 620)
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // 使用者在系統設定切換權限後，不必重新開啟視窗就能看到實際狀態。
            settings.refresh()
        }
    }

    // MARK: 語言

    private var languageSection: some View {
        Section {
            Picker(L("介面語言", "Interface Language"), selection: $settings.languagePreference) {
                ForEach(LanguagePreference.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint(L("變更後需自行結束並重新開啟靜醒才會生效", "Takes effect after you quit and reopen Awaken"))

            LabeledContent(L("目前使用", "Currently Using")) {
                Text(settings.runningLanguage == .english ? "English" : "繁體中文")
            }

            if let notice = settings.restartNotice {
                Label {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }

            Note(LanguageSettingsText.explanation)
            HStack {
                Spacer()
                Button(L("開啟「語言與地區」設定…", "Open Language & Region Settings…"), action: settings.openLanguageSettings)
            }
        } header: {
            Text(L("語言", "Language"))
        }
    }

    // MARK: 權限

    private var accessibilitySection: some View {
        Section {
            LabeledContent(L("輔助使用", "Accessibility")) {
                Label(settings.accessibility.title,
                      systemImage: settings.accessibility.granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(settings.accessibility.granted ? Color.green : Color.secondary)
            }
            .accessibilityElement(children: .combine)
            Note(settings.accessibility.detail)
            Note(PermissionText.accessibilityPurpose)
            Note(L("若清單中沒有「靜醒」，可按「+」從「應用程式」資料夾加入。重新建置或更新 App 後，系統可能需要重新允許。",
                   "If Awaken is not in the list, click “+” and add it from the Applications folder. After an update or rebuild, macOS may require you to allow it again."))
            HStack {
                Button(L("重新檢查", "Check Again"), action: settings.refresh)
                Spacer()
                Button(L("開啟「輔助使用」設定…", "Open Accessibility Settings…"), action: settings.openAccessibilitySettings)
            }
        } header: {
            Text(L("權限", "Permissions"))
        }
    }

    private var administratorSection: some View {
        Section {
            Text(PermissionText.administratorTitle).font(.body.weight(.semibold))
            Note(PermissionText.administratorDetail)
            Note(PermissionText.administratorStatus(lidEngaged: lidEngaged()))
            Note(PermissionText.noOtherPermissions)
        }
    }

    // MARK: 關於

    private var aboutSection: some View {
        Section {
            LabeledContent(AppLanguage.current.appName) {
                Text(settings.version.display).textSelection(.enabled)
            }
            LabeledContent(L("系統需求", "Requirements")) {
                Text(L("macOS 14 以上・Apple Silicon", "macOS 14 or later · Apple Silicon"))
            }
            LabeledContent(L("授權", "License")) { Text("MIT License") }
            HStack {
                Spacer()
                Link(L("專案網頁（GitHub）", "Project Page (GitHub)"),
                     destination: URL(string: "https://github.com/LeoFeng0816/Awaken")!)
            }
        } header: {
            Text(L("關於", "About"))
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 管理設定視窗：選單列 App 沒有 Dock 圖示，所以開啟時要主動帶到最前面。
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: SettingsState
    private let lidEngaged: () -> Bool

    init(settings: SettingsState, lidEngaged: @escaping () -> Bool) {
        self.settings = settings
        self.lidEngaged = lidEngaged
    }

    func show() {
        settings.refresh()
        if window == nil {
            let view = SettingsView(settings: settings, lidEngaged: lidEngaged)
                .environment(\.locale, AppLanguage.current.locale)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = L("靜醒設定", "Awaken Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 520, height: 620))
            window.contentMinSize = NSSize(width: 520, height: 360)
            window.contentMaxSize = NSSize(width: 520, height: 1400)
            window.isReleasedWhenClosed = false
            window.setAccessibilityLabel(window.title)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
