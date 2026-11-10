# Awaken: advanced use and technical details

[Back to the user guide](../README.en.md) · [繁體中文](technical.zh-Hant.md)

## Using Awaken

Click the menu bar icon to open the panel.

### Keep Awake
- **Keep Awake / Stop Keeping Awake**: one button toggles it. While active, the icon becomes a filled cup with the remaining time beside it (for example `1:23` or `45m`; “Until stopped” shows `∞`). The panel also shows the remaining time and the end time.
- **Duration**: 30 minutes, 1, 2, 4, 8 hours, Until stopped, or “Custom hours…” from 0.25 to 72 hours. **Changing the duration while running restarts the timer from now**; no restart of the app is needed.
- Timing uses the actual deadline, so expiration is judged by real time even after the Mac sleeps and wakes. When time is up or you stop manually, Awaken releases only its own power assertion and never touches assertions held by other apps.

### Mode
- **Keep Mac and display awake**: neither the Mac nor the display sleeps due to inactivity (`PreventUserIdleDisplaySleep`).
- **Keep Mac running only**: the Mac does not idle sleep, but the display still turns off on the schedule in System Settings › Lock Screen / Displays (`PreventUserIdleSystemSleep`). **This mode does not guarantee the display turns off right away.**
- **Turn Display Off Now**: runs `pmset displaysleepnow`; no administrator rights needed. Turning off the display **is not locking**: moving the mouse or pressing a key wakes it, and whether a password is required depends on your lock settings.
- You can switch modes while running: Awaken creates the new assertion before releasing the old one, so there is no gap.

### Temporarily Prevent Idle Lock
- Requests that macOS keep the display on during inactivity for a chosen time (30 minutes to 8 hours, or a custom value up to 24 hours), which also prevents ordinary idle sleep. **It does not guarantee that every automatic lock is prevented or that your Mac never locks**: a screen saver, system or management (MDM) policy, lid closure, or another cause may still lock the Mac.
- It does not change your password or Lock Screen settings. You can still lock manually at any time (Control-Command-Q; locking after lid closure depends on system settings), and the scheduled lock still runs. While the session is locked, it pauses and releases its assertion; after unlocking it resumes until the original deadline. Independent of Keep Awake.

### Scheduled Lock
- Choose 5, 10, 15, 30, 60, or 120 minutes, or a custom 1–1440 minutes, then click **Start Timer**. The panel shows the lock time and the time left; you can **Cancel** at any time or click **Restart Timer** to count down again from now.
- When time is up, Awaken **tries to lock your login session** (back to the lock screen), not just turning off the display or starting the screen saver. Afterwards it reads the system’s `CGSSessionScreenIsLocked` to confirm the lock; on failure it shows the reason and never pretends it succeeded.
- Lock methods:
  1. First, the lock function in the system’s `login.framework`. It is the same mechanism as “Lock Screen” in Control Center and is an undocumented Apple API. Awaken looks it up at run time and skips it if missing; it does **not** depend on the old `CGSession` path, which no longer exists.
  2. Otherwise, Awaken sends **Control-Command-Q**, the shortcut Apple documents for locking the screen. This requires allowing Awaken in System Settings › Privacy & Security › Accessibility. The permission request appears only when you schedule a lock and this method is needed; you can check the current status in **Settings…**. If the shortcut is disabled or changed in Keyboard Shortcuts, locking fails and the reason is shown.
- **Independent of Keep Awake**: locking does not stop Keep Awake, so with “Keep Mac and display awake” the lock screen stays lit; Keep Awake does not delay the lock either.

### Keep Running with Lid Closed (advanced, off by default, not yet verified on real hardware)

> The real-world behavior of this feature (running `pmset` as root and staying awake with the lid closed) **has not been verified on real hardware**; see “Known limitations”. Do not rely on it unattended or in a bag.

Apple’s documentation states that assertions preventing idle sleep can still let the Mac sleep when the lid is closed, so **regular Keep Awake cannot provide this feature**. Awaken uses macOS `pmset disablesleep` instead:

- This is a **system-wide setting** that disables all sleep, not just lid-close sleep; choosing Sleep manually will not work either. Awaken explains this before turning it on and only then asks for **administrator approval** (the macOS password / Touch ID dialog).
- It works only while Keep Awake is on, for **at most 12 hours**. If Keep Awake is set to “Until stopped”, lid-closed mode still ends after 12 hours; the end time is shown in the panel.
- If `SleepDisabled` is already 1 before you turn it on and there is no Awaken record, Awaken leaves it alone and will not set it to 0 at the end. Awaken cannot tell who set it or why.
- Power checks: only “confirmed on power adapter” or “confirmed on battery with a readable charge level” count as monitorable. **Unknown is never treated as being on power.**
  - At start: below 20% battery, or when power and charge cannot be confirmed, Awaken does not start and does not ask for administrator approval; the panel shows the reason.
  - While running: Awaken stops lid-closed mode and tries to restore sleep when the battery is below 15%, the system temperature is high, or power/charge stays unreadable for about 30 seconds. The watchdog also exits and restores when the battery is below 10% or when `pmset -g batt` fails or cannot be parsed 15 times in a row (about 30 seconds). Temporary read failures do not stop it; a single valid reading resets the count.
- **Limits of battery and thermal protection**: Awaken does its best to monitor battery and system temperature, but monitoring depends on the app and its watchdog running correctly. `disablesleep` is a system-wide change, so there is no guarantee that macOS low-battery or overheating safeguards will intervene. Keep your Mac ventilated and connected to power while the lid is closed, and do not put it in a bag.
- With an external display, power, and a keyboard and mouse, you can instead use [Apple’s closed-display mode](https://support.apple.com/en-us/102501), which does not change system settings.

**How restoration works**: after one approval, the system starts a short-lived watchdog as root (`/bin/bash`; the script is passed directly as an argument, not read from a writable file). The watchdog:

1. Reads the original `SleepDisabled` itself, changes it to 1 only if it was 0, and confirms the change took effect.
2. Checks every 2 seconds. In any of the following cases it sets the value back to the original 0 and retries until confirmed: a stop request, the deadline, the loop-count limit (in case the system clock is set back), the Awaken app has exited (matched by PID plus process start time so a reused PID is not mistaken for Awaken), no heartbeat for more than 120 seconds (app hung), low battery, power/charge unreadable repeatedly, or `SleepDisabled` already set back to 0.
3. Writes no user-controllable files; it only checks whether the stop file exists and reads the heartbeat file’s modification time.

**System commands have time limits**: every external command the watchdog runs (reading sleep state, battery, the app process, the heartbeat file time, and `pmset -a disablesleep`) is time-limited without relying on GNU `timeout` or any other extra tool:

| Step | Limit | If it hangs |
|---|---|---|
| Reading sleep state or the app process before starting | 5 s | Exit without changing anything (a setting that was already disabled is left alone) |
| Setting `disablesleep 1` | 8 s | Treated as uncertain; restore immediately |
| Reading sleep state, app process, or heartbeat file while running | 5 s | Exit and restore |
| Reading battery while running | 5 s | Tolerates about 3 hangs, then exits and restores; ordinary read failures still allow about 15 |
| Restoring `disablesleep 0` | 8 s | 5 attempts in total; success is always judged by re-reading the value |

- Each command runs in its own process group. On timeout the whole group receives TERM, then KILL after 1 second, then Awaken waits up to 2 seconds to confirm the group is gone, so no child processes remain and a killed writer cannot change the setting later.
- If a write command timed out, the watchdog watches for 3 more seconds after restoring. If a late 1 appears, it writes 0 again.
- If even KILL cannot end a group, the watchdog keeps tracking it for up to 120 seconds while keeping the setting at 0, then exits with a failure. At most 8 such leftover processes are tracked; at that limit no new commands are started and only the temporary directory is cleaned up.
- Command output goes to a root-only temporary directory `/tmp/jingxing-wd.*` (mode 0700; its type and owner are verified after creation and it is removed at exit; if the watchdog is force-terminated a tiny leftover remains, which macOS cleans up from `/tmp` periodically). A missing exit status is always treated as failure.
- Time limits are counted in wait iterations, so time the Mac spends asleep is not counted as a command timeout; deadlines use real time, so expiration is checked right after waking.
- Even if every command hangs, restoration takes at most about 4–5 minutes (`Timing.worstCaseRestoreSeconds`); after that the watchdog always exits instead of waiting forever.

**Restore failures are never reported as success**: the panel shows “restored” only when the watchdog has exited and the app re-reads `SleepDisabled` as 0. The app waits up to about 15 seconds. While the watchdog is still retrying, the panel says the watchdog is still running; if it later succeeds, the warning clears automatically; if it fails, the recovery record and the **Restore System Sleep Now** button remain.

The panel shows “System-wide sleep is disabled” only after the watchdog is confirmed to exist **and** `SleepDisabled` is confirmed to be 1. Cancelled approval, failures, and unconfirmed results are all reported and cleaned up.

**When the setting may remain**: if the watchdog itself is force-terminated (for example `kill -9`), power is suddenly lost, the restore command fails on every retry, or one of the cases under “What cannot be guaranteed” occurs, `SleepDisabled` may stay at 1 and will not recover automatically. Reopening Awaken checks for this and offers a manual restore; if the recovery record is also lost, follow “Manual check / restore” below.

## Quitting and recovery

- **Quit Awaken** (⌘Q) at the bottom right of the panel:
  - If lid-closed mode was not used, Awaken stops Keep Awake, cancels any pending lock timer, and quits without asking.
  - If lid-closed mode was used, Awaken first asks the watchdog to restore sleep and waits for confirmation (up to about 15 seconds) before quitting.
  - **If restoration cannot be confirmed, Awaken does not quit silently.** It shows “System sleep restoration could not be confirmed” with the reason and next steps:
    - **Cancel Quit** (default): Awaken keeps running, Keep Awake and the lock timer are unaffected, and the panel shows the restore button.
    - **Quit Anyway**: Awaken quits but keeps the recovery record. If the watchdog is still running it will keep trying to restore sleep, but its timing and success cannot be guaranteed; if it is no longer running, system sleep may stay disabled until you restore it manually.
- If Awaken is force-quit or crashes: the system automatically releases assertions held by the process; the watchdog (if still running) notices the app has exited and tries to restore the lid setting. Keep Awake is always inactive on the next launch.
- If the previous lid-closed session did not end normally (for example a power loss, forced shutdown, or a terminated watchdog), the panel shows a warning on the next launch and offers **Restore System Sleep Now (administrator approval required)**. Awaken never asks for a password automatically at launch.
- Manual check / restore:
  ```bash
  pmset -g | grep SleepDisabled                 # 1 means sleep is disabled; no output means not disabled
  pmset -g assertions | grep -E '靜醒|Awaken'    # check whether Awaken holds an assertion (name follows the app language)
  sudo pmset -a disablesleep 0                  # manually restore system sleep
  ```
- A manual restore sets the system-wide setting to 0. Other tools that also need sleep disabled will be affected.
- Awaken’s session files live in `~/Library/Application Support/JingXing/` (created only when lid-closed mode is used) and can be deleted after quitting Awaken.

## Building and testing

```bash
./build.sh           # clean release build → dist/靜醒.app (icon, Info.plist, lproj resources, ad-hoc signing and checks)
./build.sh --test    # run all tests first, then build
DIST=/tmp/awaken-build ./build.sh   # build to another directory (for example while the app in dist is running)
Scripts/build-dmg.sh             # clean app build in a temp dir → dist/dmg/Awaken-v0.1.0-macOS-arm64.dmg and .sha256
DMG_OUTPUT_DIR=/tmp/awaken-dmg Scripts/build-dmg.sh   # another output directory (refuses to overwrite an existing DMG)
Scripts/verify-dmg.sh dist/dmg/Awaken-v0.1.0-macOS-arm64.dmg 0.1.0   # read-only mount, verify, detach
swift Scripts/make-icon.swift --png Assets/Awaken.png 512            # regenerate the README icon
caffeinate -i -s swift test   # tests only (about 3 minutes)
swift test --skip Watchdog    # quick tests without the real watchdog-script suites (seconds)
dist/靜醒.app/Contents/MacOS/JingXing --self-check   # read-only self-check: prints the status item and default state, then quits
```

Building and verifying the DMG needs no administrator rights, installs nothing, and never touches a running copy of Awaken in `dist/` or Applications:

- `build-dmg.sh` creates an HFS+ image with `hdiutil`, mounts it only at its own temporary directory (`-nobrowse`, hidden from Finder), and writes the Finder layout directly with `Scripts/dmg-layout.swift` (`.DS_Store`: icon size and positions, alias and bookmark to a Retina background image) — **no Finder AppleScript**. It then converts the image to read-only UDZO, ad-hoc signs it, and runs `hdiutil verify`. It always detaches and deletes its temporary files, even on failure.
- `verify-dmg.sh` mounts read-only and checks: image format and ad-hoc signature, `靜醒.app`, the `/Applications` symlink, the drag instructions (background and guide file), the `.DS_Store` layout and that the background alias resolves, the app version, `LSMinimumSystemVersion`, arm64-only binary, and the app signature (strict/deep, no Team ID). The Gatekeeper assessment is expected to be “rejected” (not notarized) and is printed for reference. Finally it detaches.
- How Finder actually renders the window should be checked by opening the DMG in Finder; the scripts can only verify the layout data itself.

The watchdog-script tests run real processes and have outer limits measured in real time. If the Mac sleeps during the tests these limits may expire and cause false failures, so run them under `caffeinate` (`./build.sh --test` already does). `caffeinate` only takes effect while the test process is alive and does not change system settings.

The tests use injectable clocks, power, lock, permission, and watchdog fakes. Watchdog tests run the real script without changing real system settings:

- Language: picks the interface language from the preferred languages and the bundle’s `zh-Hant.lproj` / `en.lproj`; duration, remaining-time, and end-time formats in both languages; the lid-closed confirmation, administrator prompt, quit alert, and error messages are complete in both languages. Each suite pins its language with a task-local value, independent of the test Mac’s system language.
- Settings: the language choice is saved and read back as `AppleLanguages`, Follow System removes it, per-app languages set in System Settings by earlier versions (such as `zh-Hant-TW`, `en-GB`, or only unsupported languages) map correctly, the global language fallback is ignored, and the saved value selects the matching lproj of a real .app layout; changing the language only shows a “reopen yourself” notice and never quits; the Accessibility state is re-queried from the system (a fake) every time, querying never requests permission or opens anything, and only the button opens the correct System Settings pane; the administrator text says approval is per use and not stored; version display; all settings texts are complete in both languages (no Chinese in English).
- Keep Awake: expiration by deadline, manual stop, changing the duration while running, switching modes without a gap, no fake activation when assertion creation fails.
- Real IOKit: creates and immediately releases only the test process’s own assertion, verifying the timeout properties and release.
- Scheduled lock: locks only when due, cancel, restart, missing Accessibility permission, lock failure not reported as success, independence from Keep Awake.
- Power checks: read failures, unknown sources, and implausible charge values all report unknown; unknown prevents starting; temporary unknown does not stop; persistent unknown stops and restores.
- Quit flow: immediate quit without lid mode, no prompt when restored, prompt when unconfirmed, cancel keeps everything, Quit Anyway keeps the recovery record and prompts on next launch, an unreadable state does not count as restored.
- Lid-mode controller: unavailable on desktop Macs or when the state is unreadable, leaves a pre-existing disabled state alone, low battery and high temperature, cancelled approval, journal written before the privileged call, cleanup after unconfirmed start, PID reuse, expiration, heartbeat, unexpected watchdog exit, stop timeout, stop-file failure, manual restore, handling of leftover sessions at launch.
- **Real watchdog script**: with fake `pmset`, `ioreg`, and battery commands, in paths containing spaces, Chinese characters, and single quotes, verifying the stop file, app exit, deadline, pre-existing 1, missing app, stale heartbeat, low battery, persistent `pmset -g batt` failures or unparseable output, recovery after temporary failures, SIGTERM, and the setting being changed back. The full escaping and background-launch path through `osascript do shell script` (without administrator privileges) is also tested.
- **Hanging commands**: fake commands that ignore TERM and spawn children, each test with an outer limit. Covers hangs while reading state, battery, setting, and restoring; no writes at all when sleep was already disabled; late writes (impossible within the group; overwritten during the observation window when outside it); restore failure reported with exit code 20; recovery after a temporary hang; stop requests or SIGTERM during a hang; simulated unkillable processes (by overriding `kill`, not a real kernel hang); temp-directory permissions and cleanup; reliable exit codes across repeated runs.
- **Real script plus controller**: when restoring hangs, the panel shows that a restore is needed, keeps the recovery record, and manual restore is available; when restoring later succeeds, the warning clears automatically.
- **Read-only checks of real output formats**: parsing is tested against the real `ioreg` and `pmset -g batt`; write commands remain fakes.

## Known limitations and items needing real-hardware verification

- **Lid-closed mode has not been fully verified with administrator rights on real hardware**: The watchdog logic and the full launch command have been verified with fake tools and without root. Still to be confirmed on real hardware: running `pmset -a disablesleep 1/0` as root, the watchdog continuing after the administrator dialog closes, and the Mac actually staying awake with the lid closed.
- **Scheduled lock has not been fully verified on real hardware**: the lock flow was tested with fakes; actual behavior may depend on the macOS version, permissions, and settings.
- “Temporarily Prevent Idle Lock” only asks macOS not to turn off the display due to inactivity; **it does not guarantee that your Mac never locks**.
- The settings window, language switching, and the DMG’s Finder appearance were verified with automated checks and off-screen snapshots; their exact appearance on other macOS versions has not been individually confirmed.
- The `login.framework` lock function is an undocumented API and may change in future macOS versions; if it becomes unavailable, Awaken falls back to the shortcut or clearly reports failure.
- Every rebuild of an ad-hoc signed app changes its signature hash; if you previously granted Accessibility permission, you may need to grant it again.
- If other software also sets `disablesleep 1` while lid-closed mode is active, Awaken still sets it back to the 0 it read before enabling, because it cannot tell who set it. Likewise, Awaken cannot know why other software set this value.
- **What cannot be guaranteed**: time limits on external commands do not overcome every system failure. These cases may still delay or prevent restoration or leave the setting behind:
  - Uninterruptible kernel I/O: a process that even SIGKILL cannot end; the command may take effect after tracking ends.
  - Requests already sent to `powerd` that take effect after the 3-second observation window.
  - Child processes that leave the process group; the real `pmset` / `ioreg` do not do this, but group signals cannot clean them up.
  - The watchdog being force-terminated, a sudden power loss, or a crash.
  - bash or `/bin/sleep` failing to run, or a hung file system, for example an unresponsive disk holding `/tmp` or the stop file. The script’s built-in file checks and `sleep` have no separate time limit.
  - Very high system load may cause false timeouts; this ends lid-closed mode early and restores sleep, which errs on the safe side.
- Commands outside the watchdog are not covered by these time limits: the app’s administrator `osascript` (including manual restore) and `pmset displaysleepnow` for “Turn Display Off Now”. If they hang, the panel may stay in a waiting state. The latter currently waits on the main thread, so the panel becomes unresponsive if it hangs; force-quit and reopen the app.
- The time-limit mechanism still needs to be confirmed when running as real root; tests ran only as a normal user with fake write commands.
- The watchdog’s battery check parses the text output of `pmset -g batt`; if a future macOS changes the format, it is treated as unreadable, so the watchdog exits and restores (safe, but lid-closed mode cannot continue).
- The loop-count limit assumes at least 2 seconds per iteration, so if the system clock is set back, the watchdog may restore a little later than planned, but it never disables sleep indefinitely.
- Changing the language requires quitting and reopening Awaken yourself. A system language that is neither English nor Traditional Chinese falls back to English.

## Project layout

```
Package.swift
Sources/JingXingCore/   timing, IOKit assertions, locking, lid watchdog, localization, settings state (testable core)
Sources/JingXing/       menu bar app (AppDelegate, panel UI, settings window, app state)
Tests/JingXingCoreTests/
Assets/Awaken.png        app icon for the README (generated by make-icon.swift)
Scripts/make-icon.swift  original app icon drawn with CoreGraphics vector paths (iconset or single PNG)
Scripts/dmg-layout.swift DMG background and Finder layout (.DS_Store): generate, read back, check
Scripts/build-dmg.sh     builds the drag-to-Applications DMG
Scripts/verify-dmg.sh    verifies a DMG with a read-only mount
Resources/Info.plist
Resources/zh-Hant.lproj/  Traditional Chinese app name (靜醒)
Resources/en.lproj/       English app name (Awaken)
build.sh
dist/靜醒.app           local build output (shown as “Awaken” in English)
```
