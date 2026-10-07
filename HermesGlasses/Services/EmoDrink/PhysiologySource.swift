//
// PhysiologySource.swift
//
// Where today's body data comes from: a JSON document at a URL (the repo's
// own mock feed by default, so a fresh install already has "data from the
// internet"), or one of three fixed mock profiles for an offline demo.
// Foundation only; tested in tests/emodrink-source.
//

import Foundation

protocol PhysiologySource {
    /// Short label for the card ("Garmin Venu 3S", "sample: short night").
    var label: String { get }
    func fetch() async throws -> PhysiologySnapshot
}

enum PhysiologyError: LocalizedError, Equatable {
    case badStatus(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "The physiology feed answered HTTP \(code)."
        case .empty: return "The physiology feed was empty."
        }
    }
}

/// UserDefaults keys and defaults for the EmoDrink settings.
enum EmoDrinkDefaults {
    static let sourceURLKey = "emodrink_source_url"
    static let useMockKey = "emodrink_use_mock"
    static let mockProfileKey = "emodrink_mock_profile"
    static let lowSugarKey = "emodrink_low_sugar"
    static let intervalKey = "emodrink_drink_mode_interval"

    static let defaultSourceURL = "https://raw.githubusercontent.com/mayaokonkwo/emodrink-glasses/main/mock/physiology.json"
    static let defaultMockProfile = MockProfile.shortNight
    static let defaultIntervalSeconds = 4
}

enum MockProfile: String, CaseIterable, Identifiable {
    case rested
    case shortNight = "short_night"
    case stressed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rested: return "Rested"
        case .shortNight: return "Short night"
        case .stressed: return "Stressed"
        }
    }

    /// Spec section 3 table.
    func snapshot(date: String) -> PhysiologySnapshot {
        let label = "sample: \(title.lowercased())"
        switch self {
        case .rested:
            return PhysiologySnapshot(date: date, source: label, sleep: SleepSummary(hours: 7.8, score: 86),
                                      hrvMs: 58, hrvBaselineMs: 52, restingHR: 52, restingHRBaseline: 54,
                                      steps: 3000, stress: 22)
        case .shortNight:
            return PhysiologySnapshot(date: date, source: label, sleep: SleepSummary(hours: 5.1, score: 48),
                                      hrvMs: 43, hrvBaselineMs: 52, restingHR: 57, restingHRBaseline: 54,
                                      steps: 2500, stress: 38)
        case .stressed:
            return PhysiologySnapshot(date: date, source: label, sleep: SleepSummary(hours: 6.4, score: 63),
                                      hrvMs: 36, hrvBaselineMs: 52, restingHR: 61, restingHRBaseline: 54,
                                      steps: 4000, stress: 71)
        }
    }
}

struct MockPhysiologySource: PhysiologySource {
    let profile: MockProfile
    /// Injected so tests pin the date; the app passes `EmoDrinkDay.string`.
    var today: () -> String = { EmoDrinkDay.string() }

    var label: String { "sample: \(profile.title.lowercased())" }

    func fetch() async throws -> PhysiologySnapshot {
        profile.snapshot(date: today())
    }
}

struct RemoteJSONPhysiologySource: PhysiologySource {
    let url: URL
    var timeout: TimeInterval = 6

    init(url: URL, timeout: TimeInterval = 6) {
        self.url = url
        self.timeout = timeout
    }

    /// Nil when the string is not an http(s) URL.
    init?(urlString: String, timeout: TimeInterval = 6) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        self.init(url: url, timeout: timeout)
    }

    var label: String { url.host ?? "remote" }

    func fetch() async throws -> PhysiologySnapshot {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PhysiologyError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw PhysiologyError.empty }
        return try PhysiologySnapshot.decode(data)
    }
}
