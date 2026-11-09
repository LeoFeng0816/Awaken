import Foundation

/// 合蓋模式的「有限時特權看守程序」。
///
/// 透過一次管理員授權以 root 啟動一個短命的 /bin/bash 腳本，它：
/// 1. 自己讀取目前的 SleepDisabled；只有明確讀到 0 才會繼續，已停用、逾時或讀不到都不做任何變更就結束。
/// 2. 執行 `pmset -a disablesleep 1` 並確認生效（失敗或逾時就還原後結束）。
/// 3. 每隔數秒檢查：停止檔、截止時間、迴圈次數上限（防時鐘倒退）、App 程序是否仍是同一個
///    （以 PID + 啟動時間比對，避免 PID 重複使用）、心跳檔是否過期（App 卡死）、電池是否過低、
///    供電或電量是否連續多次讀不到、SleepDisabled 是否已被別人改回 0。任一條件成立即結束。
/// 4. 透過 EXIT trap 在任何正常結束、TERM/INT/QUIT 時把 SleepDisabled 設回原本的 0，並重試確認。
///
/// 外部命令一律有時限（見 `run_bounded`）：
/// - 每個命令在獨立的行程群組執行（`set -m`），逾時後對整個群組送 TERM、KILL，並確認群組消失，子程序不會留下。
/// - 由主程序輪詢逾時，不另開計時程序，因此不會在主程序死後對被重複使用的 PID 送訊號。
/// - 不使用管線與 `$(...)` 等待外部命令；輸出寫到 root 專用的 0700 暫存目錄，再由 bash 內建功能解析。
/// - 寫入命令曾逾時就視為結果不確定：還原後再觀察一段時間，晚到的 `1` 會被覆寫回 0。
/// - 殺不掉的群組會持續追蹤到上限為止；仍未消失就以非 0 結束，不把狀態當成已確認。
/// - 是否已還原一律以重新讀取的 SleepDisabled 為準，不看 pmset 的結束碼。
///
/// 無法克服的情況：bash 本身或 /bin/sleep 無法執行、不可中斷的 kernel I/O（連 SIGKILL 都無效）、
/// 已經送進 powerd 且晚於觀察期才生效的要求、脫離行程群組的程序、看守程序被強制終止、斷電。
///
/// 看守程序不寫入任何使用者可控制的路徑（避免 root 透過 symlink 覆寫檔案），只讀取停止檔是否存在與心跳檔的修改時間。
/// 腳本內容直接以參數傳入 bash，不從 App 套件或暫存檔讀取，避免授權後被替換。
public struct LidWatchdogScript: Sendable {
    public struct Tools: Sendable {
        /// 讀取 IOPMrootDomain 屬性的命令（輸出需含 `"SleepDisabled" = Yes/No`）。
        public var stateQuery: String
        /// 修改 disablesleep 的 pmset 路徑。
        public var pmset: String
        /// 讀取電池狀態的命令（輸出格式同 `pmset -g batt`）。
        public var batteryQuery: String

        public init(stateQuery: String, pmset: String, batteryQuery: String) {
            self.stateQuery = stateQuery
            self.pmset = pmset
            self.batteryQuery = batteryQuery
        }

        public static let system = Tools(
            stateQuery: "/usr/sbin/ioreg -r -c IOPMrootDomain -d 1",
            pmset: "/usr/bin/pmset",
            batteryQuery: "/usr/bin/pmset -g batt"
        )
    }

    /// 外部命令的時限（毫秒）。
    public struct Timing: Sendable {
        public var queryMs: Int
        public var writeMs: Int
        /// 送 TERM 後等待結束的時間。
        public var termGraceMs: Int
        /// 送 KILL 後等待群組消失的時間。
        public var killGraceMs: Int
        /// 寫入逾時後，還原完成還要觀察多久（應付晚到的修改）。
        public var settleMs: Int
        /// 有殺不掉的群組時，最多再追蹤多久。
        public var stragglerHoldMs: Int
        public var restoreAttempts: Int

        public init(queryMs: Int, writeMs: Int, termGraceMs: Int, killGraceMs: Int, settleMs: Int,
                    stragglerHoldMs: Int, restoreAttempts: Int) {
            self.queryMs = queryMs
            self.writeMs = writeMs
            self.termGraceMs = termGraceMs
            self.killGraceMs = killGraceMs
            self.settleMs = settleMs
            self.stragglerHoldMs = stragglerHoldMs
            self.restoreAttempts = restoreAttempts
        }

        public static let production = Timing(queryMs: 5_000, writeMs: 8_000, termGraceMs: 1_000, killGraceMs: 2_000,
                                              settleMs: 3_000, stragglerHoldMs: 120_000, restoreAttempts: 5)

        /// 一次卡住的命令最多佔用多久才會放手（不含輪詢額外耗時）。
        public func stuckCommandSeconds(limitMs: Int) -> Double {
            Double(limitMs + termGraceMs + killGraceMs) / 1000
        }

        /// 從開始還原到程序結束的時間上限估計（所有命令都卡住；不含輪詢額外耗時）。
        public var worstCaseRestoreSeconds: Double {
            let attempt = stuckCommandSeconds(limitMs: writeMs) + stuckCommandSeconds(limitMs: queryMs) + 1
            return Double(restoreAttempts) * attempt + Double(max(settleMs, stragglerHoldMs)) / 1000
                + stuckCommandSeconds(limitMs: writeMs) + 2 * stuckCommandSeconds(limitMs: queryMs)
        }
    }

    public struct Parameters: Sendable {
        public var appPID: Int32
        public var deadline: Date
        public var duration: TimeInterval
        public var stopFile: String
        public var heartbeatFile: String
        public var heartbeatMaxAge: Int
        public var pollInterval: Double
        public var minimumBatteryPercent: Int
        /// 連續幾次讀不到供電或電量就結束並還原；中間讀到一次有效值就重新計算。
        public var powerReadMaxFailures: Int
        public var timing: Timing

        public init(appPID: Int32, deadline: Date, duration: TimeInterval, stopFile: String, heartbeatFile: String,
                    heartbeatMaxAge: Int = 120, pollInterval: Double = 2, minimumBatteryPercent: Int = 10,
                    powerReadMaxFailures: Int = 15, timing: Timing = .production) {
            self.appPID = appPID
            self.deadline = deadline
            self.duration = duration
            self.stopFile = stopFile
            self.heartbeatFile = heartbeatFile
            self.heartbeatMaxAge = heartbeatMaxAge
            self.pollInterval = pollInterval
            self.minimumBatteryPercent = minimumBatteryPercent
            self.powerReadMaxFailures = powerReadMaxFailures
            self.timing = timing
        }

        /// 迴圈次數上限：每圈至少睡 pollInterval 秒，因此正常情況不會早於截止時間觸發；
        /// 若系統時鐘被調回，仍會在大約 duration（加上每圈的少量額外耗時）後結束。
        public var maxLoops: Int {
            Int((duration / pollInterval).rounded(.up)) + 5
        }
    }

    /// 程序名稱標記（$0），也用於 ps 中辨識。
    public static let processTag = "jingxing-lid-watchdog"

    public var tools: Tools
    public init(tools: Tools = .system) { self.tools = tools }

    public var body: String {
        """
        set -u
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        APP_PID="$1"; DEADLINE="$2"; MAX_LOOPS="$3"; STOP_FILE="$4"; HEARTBEAT="$5"; HB_MAX="$6"; POLL="$7"; MIN_BATT="$8"; POWER_MAX_FAILS="$9"
        QUERY_MS="${10}"; WRITE_MS="${11}"; TERM_MS="${12}"; KILL_MS="${13}"; SETTLE_MS="${14}"; HOLD_MS="${15}"; RESTORE_TRIES="${16}"
        # 讓每個背景命令自成行程群組，逾時時可以連同子程序一起結束。
        set -m
        trap '' HUP
        STEP_MS=50
        MAX_STRAGGLERS=8
        WORK_DIR=""
        OUT=""
        OUT_SEQ=0
        STATE="?"
        CUR_PID=""
        STRAGGLERS=""
        STRAGGLER_COUNT=0
        ARMED=0
        WRITE_PENDING=0
        WRITE_UNCERTAIN=0
        q_state() { \(tools.stateQuery); }
        q_batt() { \(tools.batteryQuery); }
        q_pmset() { \(tools.pmset) "$@"; }
        group_alive() { kill -0 -- "-$1" 2>/dev/null; }
        # 等待程序與其群組消失；不使用 wait，避免卡在殺不掉的程序上。
        wait_gone() {
          local waited=0
          while kill -0 "$1" 2>/dev/null || group_alive "$1"; do
            [ "$waited" -ge "$2" ] && return 1
            /bin/sleep 0.05
            waited=$((waited + STEP_MS))
          done
          return 0
        }
        # TERM → KILL → 確認群組消失；殺不掉就記錄下來繼續追蹤。
        stop_group() {
          kill -TERM -- "-$1" 2>/dev/null
          if ! wait_gone "$1" "$TERM_MS"; then
            kill -KILL -- "-$1" 2>/dev/null
            if ! wait_gone "$1" "$KILL_MS"; then
              STRAGGLERS="$STRAGGLERS $1"
              STRAGGLER_COUNT=$((STRAGGLER_COUNT + 1))
              return 1
            fi
          fi
          wait "$1" 2>/dev/null
          return 0
        }
        sweep_stragglers() {
          local kept="" count=0 p
          for p in $STRAGGLERS; do
            if group_alive "$p"; then
              kill -KILL -- "-$p" 2>/dev/null
              kept="$kept $p"
              count=$((count + 1))
            fi
          done
          STRAGGLERS="$kept"
          STRAGGLER_COUNT=$count
        }
        # 回傳命令的結束碼；124 = 逾時已清除、125 = 逾時且殺不掉、126 = 殺不掉的程序太多，拒絕再開新的。
        run_bounded() {
          local limit="$1" out="$2" waited=0 pid rc
          shift 2
          [ "$STRAGGLER_COUNT" -ge "$MAX_STRAGGLERS" ] && return 126
          "$@" >"$out" 2>/dev/null </dev/null &
          pid=$!
          CUR_PID="$pid"
          while kill -0 "$pid" 2>/dev/null; do
            if [ "$waited" -ge "$limit" ]; then
              CUR_PID=""
              OUT_SEQ=$((OUT_SEQ + 1))
              if stop_group "$pid"; then return 124; fi
              return 125
            fi
            /bin/sleep 0.05
            waited=$((waited + STEP_MS))
          done
          CUR_PID=""
          # 拿不到結束碼時 wait 回傳非 0，一樣視為失敗。
          wait "$pid" 2>/dev/null
          rc=$?
          # 主命令已結束，清掉群組內可能留下的子程序（例如晚到的寫入）。
          kill -KILL -- "-$pid" 2>/dev/null
          return "$rc"
        }
        query() {
          local file="$WORK_DIR/out.$OUT_SEQ" rc
          OUT=""
          run_bounded "$QUERY_MS" "$file" "$@"
          rc=$?
          [ "$rc" -eq 0 ] && { IFS= read -r -d '' OUT <"$file" || :; }
          return "$rc"
        }
        read_state() {
          STATE="?"
          query q_state || return 0
          case "$OUT" in
            *'"SleepDisabled" = Yes'*)
              case "$OUT" in *'"SleepDisabled" = No'*) ;; *) STATE=1 ;; esac
              ;;
            *'"SleepDisabled" = No'*)
              STATE=0
              ;;
          esac
        }
        set_disabled() {
          local rc
          WRITE_PENDING=1
          run_bounded "$WRITE_MS" /dev/null q_pmset -a disablesleep "$1"
          rc=$?
          WRITE_PENDING=0
          case "$rc" in 124|125) WRITE_UNCERTAIN=1 ;; esac
          return "$rc"
        }
        # 還原並確認；回傳 0 只代表重新讀到 0 且沒有殺不掉的程序。
        restore() {
          local i=0 start waited=0 passes=0 need=0
          while [ "$i" -lt "$RESTORE_TRIES" ]; do
            sweep_stragglers
            set_disabled 0
            read_state
            [ "$STATE" = "0" ] && break
            i=$((i + 1))
            [ "$i" -lt "$RESTORE_TRIES" ] && /bin/sleep 1
          done
          [ "$WRITE_UNCERTAIN" = "1" ] && need="$SETTLE_MS"
          start="$SECONDS"
          # 迴圈以秒數與次數雙重計算，時鐘被調回也不會延長太久。
          while :; do
            sweep_stragglers
            waited=$(( (SECONDS - start) * 1000 ))
            [ $((passes * 250)) -gt "$waited" ] && waited=$((passes * 250))
            if [ "$waited" -ge "$need" ]; then
              [ -z "$STRAGGLERS" ] && break
              [ "$waited" -ge "$HOLD_MS" ] && break
            fi
            /bin/sleep 0.25
            passes=$((passes + 1))
            read_state
            if [ "$STATE" != "0" ]; then
              set_disabled 0
            fi
          done
          read_state
          [ "$STATE" = "0" ] && [ -z "$STRAGGLERS" ]
        }
        finish() {
          local rc=$?
          trap '' TERM INT QUIT
          if [ -n "$CUR_PID" ]; then
            [ "$WRITE_PENDING" = "1" ] && WRITE_UNCERTAIN=1
            local interrupted="$CUR_PID"
            CUR_PID=""
            stop_group "$interrupted"
            WRITE_PENDING=0
          fi
          if [ "$ARMED" = "1" ]; then
            restore || rc=20
          fi
          if [ -n "$WORK_DIR" ]; then
            # 清理不受殺不掉程序數量上限影響；它不會寫入系統設定。
            STRAGGLER_COUNT=0
            run_bounded "$QUERY_MS" /dev/null /bin/rm -rf "$WORK_DIR"
          fi
          trap - EXIT
          exit "$rc"
        }
        trap 'exit 0' TERM INT QUIT
        trap finish EXIT
        # 私有暫存目錄：mkdir 遇到已存在的路徑（含 symlink）會失敗，建立後再確認型別與擁有者。
        CANDIDATE="/tmp/jingxing-wd.$$.$RANDOM$RANDOM"
        run_bounded "$QUERY_MS" /dev/null /bin/mkdir -m 700 "$CANDIDATE" || exit 16
        { [ -d "$CANDIDATE" ] && [ ! -L "$CANDIDATE" ] && [ -O "$CANDIDATE" ]; } || exit 16
        WORK_DIR="$CANDIDATE"
        read_state
        [ "$STATE" = "0" ] || exit 10
        query /bin/ps -o lstart= -p "$APP_PID"
        APP_START="$OUT"
        [ -n "$APP_START" ] || exit 12
        query /bin/date +%s
        case "$OUT" in *[0-9]*) ;; *) exit 15 ;; esac
        BASE_EPOCH="${OUT//[!0-9]/}"
        SECONDS=0
        # 從這裡開始可能已改動系統設定；任何結束路徑都要還原。
        ARMED=1
        set_disabled 1 || exit 13
        read_state
        [ "$STATE" = "1" ] || exit 14
        loops=0
        power_fails=0
        while :; do
          [ -e "$STOP_FILE" ] && exit 0
          now=$((BASE_EPOCH + SECONDS))
          [ "$now" -ge "$DEADLINE" ] && exit 0
          loops=$((loops + 1))
          [ "$loops" -gt "$MAX_LOOPS" ] && exit 0
          query /bin/ps -o lstart= -p "$APP_PID" || exit 0
          [ "$OUT" = "$APP_START" ] || exit 0
          query /usr/bin/stat -f %m "$HEARTBEAT" || exit 0
          hb="${OUT//[[:space:]]/}"
          case "$hb" in ''|*[!0-9]*) exit 0 ;; esac
          [ $((now - hb)) -gt "$HB_MAX" ] && exit 0
          power_ok=0
          query q_batt
          power_rc=$?
          if [ "$power_rc" -eq 0 ]; then
            case "$OUT" in
              *"Battery Power"*)
                if [[ "$OUT" =~ ([0-9]+)% ]]; then
                  pct="${BASH_REMATCH[1]}"
                  case "$pct" in
                    [0-9]|[0-9][0-9]|100)
                      power_ok=1
                      [ "$pct" -lt "$MIN_BATT" ] && exit 0
                      ;;
                  esac
                fi
                ;;
              *"AC Power"*)
                power_ok=1
                ;;
            esac
          fi
          if [ "$power_ok" = "1" ]; then
            power_fails=0
          elif [ "$power_rc" -ge 124 ] && [ "$power_rc" -le 126 ]; then
            # 查詢卡住比讀到怪輸出嚴重：最多容許約 3 次，避免累積等待太久。
            power_fails=$((power_fails + (POWER_MAX_FAILS + 2) / 3))
          else
            power_fails=$((power_fails + 1))
          fi
          [ "$power_fails" -ge "$POWER_MAX_FAILS" ] && exit 0
          read_state
          [ "$STATE" = "1" ] || exit 0
          /bin/sleep "$POLL"
        done
        """
    }

    /// 參數陣列（位置參數 $1…$16）。
    public func arguments(_ p: Parameters) -> [String] {
        [
            String(p.appPID),
            String(Int(p.deadline.timeIntervalSince1970.rounded(.down))),
            String(p.maxLoops),
            p.stopFile,
            p.heartbeatFile,
            String(p.heartbeatMaxAge),
            String(format: "%.2f", p.pollInterval),
            String(p.minimumBatteryPercent),
            String(p.powerReadMaxFailures),
            String(p.timing.queryMs),
            String(p.timing.writeMs),
            String(p.timing.termGraceMs),
            String(p.timing.killGraceMs),
            String(p.timing.settleMs),
            String(p.timing.stragglerHoldMs),
            String(p.timing.restoreAttempts),
        ]
    }

    /// 在背景啟動看守程序並印出其 PID 的 shell 命令。
    public func launchCommand(_ p: Parameters) -> String {
        let args = ([Self.processTag] + arguments(p)).map(ShellQuote.single).joined(separator: " ")
        return "/bin/bash -c \(ShellQuote.single(body)) \(args) </dev/null >/dev/null 2>&1 & echo $!"
    }
}

public enum ShellQuote {
    /// POSIX 單引號跳脫。
    public static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AppleScriptQuote {
    /// AppleScript 字串常值跳脫。
    public static func string(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func doShellScript(_ command: String, administrator: Bool, prompt: String?) -> String {
        var script = "do shell script \(string(command))"
        if administrator {
            script += " with administrator privileges"
            if let prompt { script += " with prompt \(string(prompt))" }
        }
        return script
    }
}
