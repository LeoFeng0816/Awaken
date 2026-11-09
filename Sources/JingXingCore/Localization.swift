import Foundation

/// App 介面語言：繁體中文（靜醒）或英文（Awaken）。
///
/// 依 macOS 的語言設定決定，包含「系統設定 › 一般 › 語言與地區 › App」的個別 App 語言
/// （該設定寫入本 App 的 `AppleLanguages`，Foundation 會在 `Bundle.main.preferredLocalizations` 反映）。
/// 在 .app 內以 bundle 的 `zh-Hant.lproj`／`en.lproj` 為準，讓介面與 Finder、選單中顯示的 App 名稱一致；
/// 沒有 lproj 的執行環境（swift run、測試）改用相同的 Foundation 比對規則。變更語言後需重新開啟 App。
public enum AppLanguage: String, CaseIterable, Sendable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    /// 測試用：在目前 task 範圍內固定語言，不影響其他平行執行的測試。
    @TaskLocal public static var override: AppLanguage?

    public static var current: AppLanguage { override ?? resolved }

    private static let resolved: AppLanguage = resolve(bundle: .main, preferences: Locale.preferredLanguages)

    /// 以 bundle 的語系資源與使用者的語言偏好選出介面語言。
    public static func resolve(bundle: Bundle, preferences: [String]) -> AppLanguage {
        if bundle.localizations.contains(where: { match($0) != nil }),
           let chosen = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: preferences)
               .lazy.compactMap(match).first {
            return chosen
        }
        return resolve(preferences: preferences)
    }

    /// 只依語言偏好選擇；都不符合時用英文（與 Foundation 對沒有相符語系時的選擇一致）。
    public static func resolve(preferences: [String]) -> AppLanguage {
        let chosen = Bundle.preferredLocalizations(from: allCases.map(\.rawValue), forPreferences: preferences)
        return chosen.lazy.compactMap(match).first ?? .english
    }

    /// 把語系代碼（例如 en-GB、zh-Hant-TW、zh_TW）對應到支援的語言；簡體中文等不支援的回傳 nil。
    public static func match(_ identifier: String) -> AppLanguage? {
        let id = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if id == "en" || id.hasPrefix("en-") { return .english }
        if id.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains(where: { id == $0 || id.hasPrefix($0 + "-") }) {
            return .traditionalChinese
        }
        return nil
    }

    public var isEnglish: Bool { self == .english }

    /// 用於日期與數字格式：語言跟隨 App，地區沿用系統設定。
    public var locale: Locale {
        switch self {
        case .traditionalChinese:
            return Locale(identifier: "zh_Hant_TW")
        case .english:
            if let region = Locale.current.region?.identifier {
                return Locale(identifier: "en_\(region)")
            }
            return Locale(identifier: "en_US")
        }
    }

    /// App 名稱：繁中為「靜醒」，英文為「Awaken」。
    public var appName: String { self == .english ? "Awaken" : "靜醒" }
}

/// 使用者可見文字一律經過這裡，包括核心模組產生的錯誤與提示。
public func L(_ traditionalChinese: @autoclosure () -> String,
              _ english: @autoclosure () -> String) -> String {
    AppLanguage.current.isEnglish ? english() : traditionalChinese()
}
