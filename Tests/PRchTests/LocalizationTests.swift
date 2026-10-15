import Foundation
import Combine
import Testing
import ReviewCore
@testable import PRch

@Test func languageResolutionUsesPreferenceOrderAndEnglishFallback() {
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["ja-JP", "en-US"]) == "ja")
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["en-GB", "ja"]) == "en")
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["fr", "ja"]) == "ja")
    #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["fr"]) == "en")
    #expect(AppLanguage.english.resolvedCode(preferredLanguages: ["ja"]) == "en")
    #expect(AppLanguage.japanese.resolvedCode(preferredLanguages: ["en"]) == "ja")
}

@Test func translationsContainMatchingKeysAndFormatArguments() throws {
    func strings(_ code: String) throws -> [String: String] {
        let url = try #require(L10n.resources.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
    let english = try strings("en")
    let japanese = try strings("ja")
    #expect(!english.isEmpty)
    #expect(Set(english.keys) == Set(japanese.keys))
    for (key, value) in english {
        let translated = try #require(japanese[key])
        #expect(!translated.isEmpty)
        let placeholders = /%(?:[0-9]+\$)?(?:ld|@)/
        #expect(value.matches(of: placeholders).map { String($0.output) }.sorted() ==
                translated.matches(of: placeholders).map { String($0.output) }.sorted(), "Format arguments for \(key)")
    }
    for status in ReviewStatus.allCases { #expect(english[status.labelKey] != nil) }
    for error in ReviewError.allCases { #expect(english["error.\(error.rawValue)"] != nil) }
    for style in MenuBarStyle.allCases {
        #expect(english[style.titleKey] != nil)
        #expect(english[style.explanationKey] != nil)
    }
}

@Test func formattedContentAndRelativeTimesUseSelectedLanguage() {
    let en = L10n(language: .english)
    let ja = L10n(language: .japanese)
    #expect(en.text("repositories.count", 1, 3) == "Monitoring 1 / 3 repositories")
    #expect(ja.text("repositories.count", 1, 3) == "1 / 3 リポジトリを監視")
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(en.age(now, now: now) == "Just now")
    #expect(ja.age(now, now: now) == "たった今")
    for interval in [60.0, 120, 3_600, 86_400] {
        #expect(en.age(now.addingTimeInterval(-interval), now: now).contains("ago"))
        #expect(ja.age(now.addingTimeInterval(-interval), now: now).contains("前"))
    }
    let warning = ReviewWarning(reason: .tooManyResults, organization: "example-org")
    #expect(en.warning(warning).hasPrefix("example-org: Search"))
    #expect(ja.warning(warning).hasPrefix("example-org: 検索"))
    #expect(en.text("row.detailsAccessibility", "Fix 100% %@") == "Details for Fix 100% %@")
}

private actor FailingLocalizationService: ReviewService {
    var fetchCount = 0
    func fetch(scope: RepositoryScope) async throws -> ReviewSnapshot {
        fetchCount += 1
        throw ReviewError.network
    }
    func repositories(organization: String) async throws -> [Repository] { throw ReviewError.authentication }
}

@Test @MainActor func languagePersistsAndRetranslatesExistingErrorsWithoutRefetching() async throws {
    let suite = "dev.prch.tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = FailingLocalizationService()
    let store = AppStore(service: service, preferences: preferences, startsPolling: false)
    #expect(store.language == .system)
    store.language = .japanese
    let scope = RepositoryScope(organization: "example-org")
    store.save(scope)
    for await refreshing in store.$isRefreshing.values { if !refreshing { break } }
    #expect(store.error?.contains("GitHubに接続できません") == true)
    store.language = .english
    #expect(store.error?.contains("Could not connect to GitHub") == true)
    #expect(store.menuBarSummary.contains("Could not connect to GitHub"))
    #expect(store.scopes == [scope])
    #expect(await service.fetchCount == 1)
    let restarted = AppStore(service: service, preferences: preferences, startsPolling: false)
    #expect(restarted.language == .english)
    #expect(restarted.scopes == [scope])
    preferences.set("unknown", forKey: "language")
    #expect(AppStore(service: service, preferences: preferences, startsPolling: false).language == .system)
}
