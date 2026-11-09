import Testing
@testable import JingXingCore

/// 在測試（或整個 suite）範圍內固定 App 語言。以 task-local 實作，不影響平行執行的其他測試，
/// 也不依賴這台 Mac 的系統語言。
struct LanguageTrait: TestTrait, SuiteTrait, TestScoping {
    let language: AppLanguage
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await AppLanguage.$override.withValue(language) {
            try await function()
        }
    }
}

extension Trait where Self == LanguageTrait {
    static func language(_ language: AppLanguage) -> Self { LanguageTrait(language: language) }
}
