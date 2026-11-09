import SwiftUI
import JingXingCore

struct MenuView: View {
    @Bindable var model: AppModel
    var confirmLid: () -> Bool
    var openSettings: () -> Void
    var quit: () -> Void

    private var awake: AwakeController { model.awake }
    private var lock: LockTimerController { model.lock }
    private var lid: LidSleepController { model.lid }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            awakeCard
            modeCard
            guardCard
            lockCard
            lidCard
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 348)
    }

    // MARK: 狀態與主要按鈕

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(awake.isActive ? Color.accentColor : Color.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(awake.isActive ? L("正在保持清醒", "Keeping Awake") : L("未啟用", "Inactive"))
                    .font(.headline)
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusDetail: String {
        _ = model.now
        guard awake.isActive else {
            if awake.lastEndReason == .expired { return L("已到時，電腦恢復依系統設定休眠。", "Expired. Your Mac will follow its sleep settings.") }
            return L("電腦依系統設定休眠。", "Your Mac follows its sleep settings.")
        }
        guard let deadline = awake.deadline, let left = awake.remaining() else {
            return L("\(awake.mode.title)，直到手動停止。", "\(awake.mode.title) until stopped.")
        }
        let remaining = TimeText.remaining(left)
        let end = TimeText.clock(deadline, relativeTo: model.now)
        return L("剩 \(remaining)・\(end) 結束", "\(remaining) left · ends \(end)")
    }

    private var awakeCard: some View {
        Card {
            Button(action: model.toggleAwake) {
                Label(awake.isActive ? L("停止保持清醒", "Stop Keeping Awake") : L("開始保持清醒", "Keep Awake"),
                      systemImage: awake.isActive ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(awake.isActive ? .orange : .accentColor)
            .keyboardShortcut(.defaultAction)

            HStack {
                Text(L("時長", "Duration"))
                Spacer()
                Picker(L("時長", "Duration"), selection: $model.durationChoice) {
                    ForEach(AwakeDuration.presets, id: \.self) { d in
                        Text(d.label).tag(DurationChoice.preset(d))
                    }
                    Divider()
                    Text(L("自訂時數…", "Custom hours…")).tag(DurationChoice.custom)
                }
                .labelsHidden()
                .fixedSize()
            }
            if model.durationChoice == .custom {
                HStack {
                    Text(L("自訂", "Custom"))
                    Spacer()
                    TextField(L("小時", "hours"), value: $model.customHours, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(L("自訂小時數", "Custom hours"))
                    Stepper("", value: $model.customHours, in: 0.25...72, step: 0.5)
                        .labelsHidden()
                        .accessibilityLabel(L("調整自訂小時數", "Adjust custom hours"))
                    Text(L("小時", "hours"))
                }
            }
            if awake.isActive {
                Caption(L("執行中變更時長會從現在重新計時。", "Changing the duration while running restarts the timer from now."))
            }
            if let error = awake.lastError {
                Warning(text: error)
            }
        }
    }

    // MARK: 模式

    private var modeCard: some View {
        Card {
            Picker(L("模式", "Mode"), selection: Binding(get: { awake.mode }, set: { model.setMode($0) })) {
                ForEach(AwakeMode.allCases, id: \.self) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Caption(awake.mode.detail)
            HStack {
                Button {
                    model.sleepDisplayNow()
                } label: {
                    Label(L("立即關閉螢幕", "Turn Display Off Now"), systemImage: "display")
                }
                Spacer()
            }
            Caption(L("只關閉螢幕，不等於上鎖；動一下滑鼠或鍵盤就會亮起。是否需要密碼依系統設定。", "This turns off the display without locking. Move the mouse or press a key to wake it; password requirements follow system settings."))
            if let m = model.displayMessage { Warning(text: m) }
        }
    }

    // MARK: 防止閒置自動上鎖

    private var idleGuard: IdleLockGuardController { model.idleGuard }

    private var guardCard: some View {
        Card {
            HStack {
                Label(L("限時防止閒置自動上鎖", "Temporarily Prevent Idle Lock"), systemImage: idleGuard.isActive ? "lock.slash.fill" : "lock.slash")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(idleGuard.isActive ? L("停止", "Stop") : L("開始", "Start"), action: model.toggleGuard)
                    .tint(idleGuard.isActive ? .orange : .accentColor)
                    .accessibilityLabel(idleGuard.isActive ? L("停止防止閒置自動上鎖", "Stop preventing idle lock") : L("開始防止閒置自動上鎖", "Start preventing idle lock"))
            }
            HStack {
                Text(L("時長", "Duration"))
                Spacer()
                Picker(L("防止上鎖時長", "Idle lock prevention duration"), selection: $model.guardChoice) {
                    ForEach(GuardChoice.presets, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                    Divider()
                    Text(L("自訂時數…", "Custom hours…")).tag(GuardChoice.custom)
                }
                .labelsHidden()
                .fixedSize()
            }
            if model.guardChoice == .custom {
                HStack {
                    Text(L("自訂", "Custom"))
                    Spacer()
                    TextField(L("小時", "hours"), value: $model.customGuardHours, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(L("防止上鎖的自訂小時數", "Custom idle lock prevention hours"))
                    Stepper("", value: $model.customGuardHours, in: 0.25...24, step: 0.5)
                        .labelsHidden()
                        .accessibilityLabel(L("調整防止上鎖的自訂小時數", "Adjust idle lock prevention hours"))
                    Text(L("小時", "hours"))
                }
            }
            guardStatus
            if let error = idleGuard.lastError {
                Warning(text: error)
            }
            Caption(L("請求 macOS 在期間內不因閒置關閉螢幕，通常可避免閒置後要求密碼；螢幕會一直亮著，電腦也不會閒置睡眠。這不保證阻止所有自動上鎖：螢幕保護程式、系統或管理政策、合蓋等仍可能上鎖。不更改密碼或「鎖定畫面」設定；你仍可隨時手動上鎖（Control-Command-Q），下方的自動上鎖倒數也照常執行。與保持清醒互相獨立。", "Asks macOS not to turn off the display due to inactivity during this period, which usually avoids the idle password prompt. The display stays on and your Mac will not idle sleep. This does not guarantee that every automatic lock is prevented: a screen saver, system or management policy, or closing the lid may still lock your Mac. Your password and Lock Screen settings are not changed; you can still lock manually at any time (Control-Command-Q), and the scheduled lock below still runs. Independent of Keep Awake."))
        }
    }

    @ViewBuilder private var guardStatus: some View {
        let _ = model.now
        if let deadline = idleGuard.deadline {
            VStack(alignment: .leading, spacing: 2) {
                Text(guardActiveText(deadline))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                if idleGuard.isPaused {
                    Caption(L("螢幕已鎖定，暫停中；解鎖後會繼續到原定時間。", "Paused while the screen is locked; resumes after unlocking until the original deadline."))
                } else {
                    Caption(L("執行中變更時長會從現在重新計時。", "Changing the duration while running restarts the timer from now."))
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(idleGuard.lastEndReason == .expired ? L("已到期，恢復依系統設定閒置上鎖。", "Expired. Idle locking follows system settings.") : L("未啟用，依系統設定閒置上鎖。", "Inactive. Idle locking follows system settings."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func guardActiveText(_ deadline: Date) -> String {
        let end = TimeText.clock(deadline, relativeTo: model.now)
        let left = TimeText.remaining(idleGuard.remaining() ?? 0)
        return L("防止中・\(end) 到期・剩 \(left)", "Active · until \(end) · \(left) left")
    }

    // MARK: 自動上鎖

    private var lockCard: some View {
        Card {
            HStack {
                Label(L("自動上鎖", "Scheduled Lock"), systemImage: "lock")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if lock.isScheduled {
                    Button(L("取消", "Cancel"), role: .cancel, action: model.cancelLock)
                }
            }
            HStack {
                Picker(L("上鎖時間", "Lock after"), selection: $model.lockChoice) {
                    ForEach(LockChoice.presets, id: \.self) { c in
                        Text(L("\(c.label)後", "After \(c.label)")).tag(c)
                    }
                    Divider()
                    Text(L("自訂…", "Custom…")).tag(LockChoice.custom)
                }
                .labelsHidden()
                .fixedSize()
                if model.lockChoice == .custom {
                    TextField(L("分鐘", "min"), value: $model.customLockMinutes, format: .number)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(L("自訂上鎖分鐘數", "Custom lock delay in minutes"))
                    Stepper("", value: $model.customLockMinutes, in: 1...1440)
                        .labelsHidden()
                        .accessibilityLabel(L("調整自訂上鎖分鐘數", "Adjust custom lock delay"))
                    Text(L("分鐘", "min"))
                }
                Spacer()
                Button(lock.isScheduled ? L("重新計時", "Restart Timer") : L("開始倒數", "Start Timer"), action: model.scheduleLock)
                    .disabled(lock.state == .locking)
            }
            lockStatus
            Caption(L("到時會嘗試鎖定登入工作階段（回到鎖定畫面），並確認是否真的鎖定；失敗時會顯示原因。與保持清醒互不影響：上鎖後保持清醒仍會繼續。", "When time is up, Awaken tries to lock your login session (back to the lock screen) and checks that it actually locked; if not, it shows why. Independent of Keep Awake: Keep Awake continues after locking."))
        }
    }

    @ViewBuilder private var lockStatus: some View {
        let _ = model.now
        switch lock.state {
        case .idle:
            Text(L("不自動上鎖", "No lock scheduled")).font(.callout).foregroundStyle(.secondary)
        case .scheduled(let deadline, _):
            Text(lockScheduledText(deadline))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.accentColor)
        case .locking:
            Text(L("正在上鎖…", "Locking…")).font(.callout)
        case .locked(let at, _):
            HStack {
                let time = TimeText.clock(at, relativeTo: model.now)
                Text(L("已於 \(time) 上鎖", "Locked at \(time)")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("清除", "Clear")) { lock.dismiss() }.buttonStyle(.link)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Warning(text: message)
                Button(L("清除", "Clear")) { lock.dismiss() }.buttonStyle(.link)
            }
        }
    }

    private func lockScheduledText(_ deadline: Date) -> String {
        let at = TimeText.clock(deadline, relativeTo: model.now)
        let left = TimeText.remaining(lock.remaining() ?? 0)
        return L("\(at) 上鎖・剩 \(left)", "Locks at \(at) · \(left) left")
    }

    // MARK: 合蓋模式

    private var lidCard: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("合上螢幕後繼續運作", "Keep Running with Lid Closed")).font(.subheadline.weight(.semibold))
                    Text(L("進階・需要管理員授權・預設關閉", "Advanced · Administrator approval required · Off by default")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(L("合上螢幕後繼續運作", "Keep Running with Lid Closed"), isOn: Binding(get: { lidToggleOn }, set: { setLid($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!lidToggleEnabled)
                    .accessibilityHint(L("需要管理員授權，會暫時停用整台電腦的睡眠", "Requires administrator approval and temporarily disables system-wide sleep"))
            }
            lidStatus
            if let message = lid.message {
                HStack(alignment: .top) {
                    Caption(message)
                    Spacer(minLength: 0)
                    Button(L("知道了", "Dismiss")) { lid.clearMessage() }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var lidToggleOn: Bool {
        lid.isEngaged || (model.isLidWanted && !awake.isActive)
    }

    private var lidToggleEnabled: Bool {
        switch lid.state {
        case .off, .active: return true
        case .starting, .stopping: return false
        case .unavailable, .externallyDisabled, .needsRecovery: return model.isLidWanted
        }
    }

    private func setLid(_ on: Bool) {
        if on {
            guard confirmLid() else { return }
            Task { await model.enableLid() }
        } else {
            Task { await model.disableLid() }
        }
    }

    @ViewBuilder private var lidStatus: some View {
        let _ = model.now
        switch lid.state {
        case .off:
            if model.isLidWanted && !awake.isActive {
                let end = TimeText.clock(model.lidPlannedEnd, relativeTo: model.now)
                Caption(L("按「開始保持清醒」時會要求管理員授權，最長 12 小時（至 \(end)）。",
                          "Administrator approval will be requested when you click “Keep Awake”. Lasts up to 12 hours (until \(end))."))
            } else {
                Caption(L("一般的保持清醒無法阻止合蓋睡眠。若有外接螢幕、電源與鍵盤滑鼠，也可使用 Apple 的外接螢幕合蓋模式。", "Keep Awake alone cannot prevent sleep when the lid closes. With an external display, power, and keyboard or mouse, you can use Apple’s closed-display mode."))
            }
        case .unavailable(let reason):
            Caption(L("無法使用：\(reason)", "Unavailable: \(reason)"))
        case .externallyDisabled:
            Caption(L("系統睡眠目前已是停用狀態（SleepDisabled = 1）。靜醒無法判斷是誰設定的，不會更動它；若不是你預期的，可在「終端機」執行 sudo pmset -a disablesleep 0。", "System sleep is already disabled (SleepDisabled = 1). Awaken cannot determine who changed it and will not change it. If unexpected, run sudo pmset -a disablesleep 0 in Terminal."))
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Caption(L("等待管理員授權並確認設定…", "Waiting for administrator approval and verifying settings…"))
            }
        case .active(let deadline):
            VStack(alignment: .leading, spacing: 4) {
                let end = TimeText.clock(deadline, relativeTo: model.now)
                Label(L("已停用全系統睡眠，預定 \(end) 還原", "System-wide sleep is disabled; scheduled to restore \(end)"),
                      systemImage: "laptopcomputer")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Caption(lidHealth)
                if lid.power.assess(minimumBattery: LidSleepController.stopBattery) == .unknown {
                    let grace = Int(LidSleepController.powerUnknownGrace)
                    Warning(text: L("目前讀不到供電或電量，無法監測低電量。若持續約 \(grace) 秒，將停止合蓋模式並嘗試還原。",
                                    "Power source or battery level is unavailable, so low battery cannot be monitored. If this lasts about \(grace) seconds, lid-closed mode will stop and Awaken will try to restore sleep."))
                }
                Caption(L("請保持通風與供電，勿放進包包；手動選擇「睡眠」也不會生效。靜醒會盡力監測電量與溫度，但這依賴靜醒與看守程序正常運作，不能保證 macOS 的防護一定會介入。", "Keep your Mac ventilated and connected to power, and do not put it in a bag. Choosing Sleep manually will not work either. Awaken does its best to monitor battery and temperature, but this depends on Awaken and its watchdog running correctly; it cannot guarantee that macOS safeguards will intervene."))
            }
        case .stopping:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Caption(L("正在還原系統睡眠設定…", "Restoring system sleep settings…"))
            }
        case .needsRecovery(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Warning(text: reason)
                Button(L("立即還原系統睡眠（需要管理員授權）", "Restore System Sleep Now (administrator approval required)")) { Task { await lid.forceRestore() } }
                Caption(L("或在「終端機」執行：sudo pmset -a disablesleep 0。這會把全系統設定改為 0，若其他工具也需要停用睡眠，會一併受影響。", "Or run sudo pmset -a disablesleep 0 in Terminal. This sets the system-wide setting to 0; other tools that also need sleep disabled will be affected."))
            }
        }
    }

    private var lidHealth: String {
        var parts: [String] = []
        if let c = lid.clamshell { parts.append(c.closed ? L("上蓋：已合上", "Lid: closed") : L("上蓋：開啟", "Lid: open")) }
        switch lid.power.source {
        case .ac:
            parts.append(L("使用電源轉接器", "On power adapter"))
        case .battery:
            parts.append(lid.power.batteryPercent.map { L("使用電池 \($0)%", "On battery \($0)%") }
                         ?? L("使用電池（電量未知）", "On battery (charge unknown)"))
        case .unknown:
            parts.append(L("供電狀態未知", "Power source unknown"))
        }
        parts.append(L("溫度：\(lid.thermal.title)", "Temperature: \(lid.thermal.title)"))
        return parts.joined(separator: L("・", " · "))
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Label(L("設定…", "Settings…"), systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            .help(L("語言、權限與版本資訊", "Language, permissions, and version information"))
            .accessibilityHint(L("開啟設定視窗：介面語言、輔助使用與管理員授權說明、版本資訊", "Opens the settings window: interface language, Accessibility and administrator approval, and version information"))
            Spacer()
            Button(action: quit) {
                Label(L("結束靜醒", "Quit Awaken"), systemImage: "power")
            }
            .keyboardShortcut("q")
            .help(L("停止保持清醒與防止閒置上鎖、取消上鎖倒數並結束程式", "Stop Keep Awake and idle lock prevention, cancel the lock timer, and quit"))
        }
    }
}

// MARK: - 小元件

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Warning: View {
    let text: String
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
        .accessibilityLabel(L("警告：\(text)", "Warning: \(text)"))
    }
}
