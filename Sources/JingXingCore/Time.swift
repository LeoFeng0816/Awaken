import Foundation

/// 可注入的時間來源。所有倒數都以「截止時間 − 現在」計算，不累計 timer 次數。
public protocol TimeSource: AnyObject, Sendable {
    func now() -> Date
}

public final class SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}

/// 可注入的非同步等待（測試時可立即返回）。
public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// 保持清醒的時長。
public enum AwakeDuration: Hashable, Codable, Sendable {
    case seconds(TimeInterval)
    case indefinite

    public var interval: TimeInterval? {
        if case .seconds(let s) = self { return s }
        return nil
    }

    public static let presets: [AwakeDuration] = [
        .seconds(30 * 60), .seconds(3600), .seconds(2 * 3600),
        .seconds(4 * 3600), .seconds(8 * 3600), .indefinite,
    ]

    public var label: String {
        switch self {
        case .indefinite: return L("直到手動停止", "Until stopped")
        case .seconds(let s): return TimeText.durationLabel(s)
        }
    }
}

public enum TimeText {
    /// 「30 分鐘」「1 小時」「1.5 小時」／「30 minutes」「1 hour」「1.5 hours」
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L("\(minutes) 分鐘", minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        let h = minutes / 60
        if minutes % 60 == 0 { return L("\(h) 小時", h == 1 ? "1 hour" : "\(h) hours") }
        let hours = Double(minutes) / 60
        if minutes % 30 == 0 { return L(String(format: "%.1f 小時", hours), String(format: "%.1f hours", hours)) }
        let m = minutes % 60
        return L("\(h) 小時 \(m) 分鐘",
                 "\(h == 1 ? "1 hour" : "\(h) hours") \(m == 1 ? "1 minute" : "\(m) minutes")")
    }

    /// 剩餘時間的完整說法：「1 小時 23 分」「12 分」「不到 1 分鐘」／「1 hr 23 min」「12 min」「less than 1 min」
    public static func remaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return L("不到 1 分鐘", "less than 1 min") }
        let minutesTotal = (total + 59) / 60
        let h = minutesTotal / 60
        let m = minutesTotal % 60
        if h == 0 { return L("\(m) 分", "\(m) min") }
        if m == 0 { return L("\(h) 小時", "\(h) hr") }
        return L("\(h) 小時 \(m) 分", "\(h) hr \(m) min")
    }

    /// 選單列用的簡短剩餘時間：「1:23」「45分」「<1分」／「1:23」「45m」「<1m」
    public static func compactRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return L("<1分", "<1m") }
        let minutesTotal = (total + 59) / 60
        let h = minutesTotal / 60
        let m = minutesTotal % 60
        if h == 0 { return L("\(m)分", "\(m)m") }
        return String(format: "%d:%02d", h, m)
    }

    /// 截止時間。繁中：同一天「22:45」，其他日子「明天 08:30」或「11月5日 08:30」。
    /// 英文依地區的 12／24 小時制：「10:45 PM」「tomorrow, 8:30 AM」「Nov 5, 8:30 AM」。
    /// `locale` 只供測試固定英文格式；繁中格式固定不變。
    public static func clock(_ date: Date, relativeTo now: Date, calendar: Calendar = .current,
                             locale: Locale? = nil) -> String {
        let english = AppLanguage.current.isEnglish
        let formatLocale = locale ?? AppLanguage.current.locale
        func formatter(zh zhFormat: String, enTemplate: String) -> DateFormatter {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            if english {
                f.locale = formatLocale
                f.setLocalizedDateFormatFromTemplate(enTemplate)
            } else {
                f.locale = Locale(identifier: "zh_Hant_TW")
                f.dateFormat = zhFormat
            }
            return f
        }
        let hm = formatter(zh: "HH:mm", enTemplate: "jmm").string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return hm }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return L("明天 \(hm)", "tomorrow, \(hm)")
        }
        let day = formatter(zh: "M月d日 HH:mm", enTemplate: "MMMd")
        if english { return "\(day.string(from: date)), \(hm)" }
        return day.string(from: date)
    }
}
