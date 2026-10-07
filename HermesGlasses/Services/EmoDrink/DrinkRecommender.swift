//
// DrinkRecommender.swift
//
// Snapshot + hour + preferences -> one drink, two alternates, and the rule
// fragments the reason is built from. Deterministic: the same inputs give
// the same pick, which is what makes a demo repeatable and what EmoDrink's
// method needed (hold the recommendation constant). The AI never chooses;
// it only phrases. Foundation only; tested in tests/emodrink-recommender.
//

import Foundation

struct Recommendation: Equatable {
    let pick: Drink
    /// The next two distinct drinks in rank order.
    let alternates: [Drink]
    /// Every drink, best first. "Something else" walks this list.
    let ranked: [Drink]
    let state: BodyState
    /// Short rule fragments, e.g. "slept 5.1 h". The AI phrases them; the
    /// lens shows `reasonLine` when the AI is unavailable.
    let reasons: [String]

    var reasonLine: String { reasons.prefix(2).joined(separator: ", ") }

    /// The drink after `drink` in rank order, wrapping around. An unknown
    /// drink restarts at the top. Never returns `drink` itself unless the
    /// catalogue has one entry.
    func next(after drink: Drink) -> Drink {
        guard let index = ranked.firstIndex(of: drink) else { return ranked[0] }
        return ranked[(index + 1) % ranked.count]
    }
}

enum DrinkRecommender {
    /// From this hour on, `energise` is dropped and caffeine costs points.
    static let caffeineCutoffHour = 15
    static let caffeinePenaltyThresholdMg = 30
    static let hydrateStepsThreshold = 8000

    /// Spec section 5, step 2.
    static func wantedFunctions(state: BodyState, hour: Int, steps: Int?) -> [DrinkFunction] {
        var wants: [DrinkFunction]
        switch (state.recovery, state.arousal) {
        case (.low, .high): wants = [.calm, .hydrate]
        case (.low, _): wants = [.energise, .recover, .hydrate]
        case (.mid, .high): wants = [.calm, .refresh]
        case (.mid, _): wants = [.hydrate, .refresh]
        case (.high, _): wants = [.refresh, .hydrate]
        }
        if hour >= caffeineCutoffHour { wants.removeAll { $0 == .energise } }
        if let steps, steps > hydrateStepsThreshold {
            wants.removeAll { $0 == .hydrate }
            wants.insert(.hydrate, at: 0)
        }
        return wants
    }

    /// Spec section 5, step 3. 3 / 2 / 1 for the first three wants, minus 2
    /// for caffeine after the cutoff, minus 2 for regular sugar when the
    /// wearer asked for low sugar.
    static func score(_ drink: Drink, wants: [DrinkFunction], hour: Int, lowSugar: Bool) -> Int {
        var total = 0
        for (rank, want) in wants.prefix(3).enumerated() where drink.functions.contains(want) {
            total += 3 - rank
        }
        if hour >= caffeineCutoffHour, drink.caffeineMg > caffeinePenaltyThresholdMg { total -= 2 }
        if lowSugar, drink.sugar == .regular { total -= 2 }
        return total
    }

    static func recommend(snapshot: PhysiologySnapshot, catalog: DrinkCatalog, hour: Int, lowSugar: Bool) -> Recommendation? {
        guard !catalog.drinks.isEmpty else { return nil }
        let state = snapshot.bodyState
        let wants = wantedFunctions(state: state, hour: hour, steps: snapshot.steps)
        // Stable sort: ties keep catalogue order, so the result never flickers.
        let scored = catalog.drinks.enumerated().map { (index: $0.offset, drink: $0.element,
                                                        score: score($0.element, wants: wants, hour: hour, lowSugar: lowSugar)) }
        let ranked = scored.sorted { a, b in a.score != b.score ? a.score > b.score : a.index < b.index }.map(\.drink)
        return Recommendation(
            pick: ranked[0],
            alternates: Array(ranked.dropFirst().prefix(2)),
            ranked: ranked,
            state: state,
            reasons: reasons(snapshot: snapshot, hour: hour))
    }

    /// Plain-words fragments in priority order, at most five. Only facts the
    /// snapshot actually carries: no baselines, no HRV or heart rate line.
    static func reasons(snapshot s: PhysiologySnapshot, hour: Int) -> [String] {
        var out: [String] = []
        out.append("slept \(formatHours(s.sleep.hours)) h")
        if let score = s.sleep.score { out.append("sleep score \(score)") }
        if let d = s.hrvDelta {
            if d <= -5 { out.append("HRV \(Int((-d).rounded())) ms under your usual") }
            else if d >= 5 { out.append("HRV \(Int(d.rounded())) ms above your usual") }
        }
        if let d = s.restingHRDelta, d >= 5 {
            out.append("resting heart rate \(Int(d.rounded())) over your usual")
        }
        if let stress = s.stress, stress >= 65 { out.append("stress \(stress)") }
        if let steps = s.steps, steps > hydrateStepsThreshold { out.append("\(formatThousands(steps)) steps already") }
        if hour >= caffeineCutoffHour { out.append("it is after 3 pm") }
        return Array(out.prefix(5))
    }

    private static func formatHours(_ hours: Double) -> String {
        String(format: "%.1f", hours)
    }

    private static func formatThousands(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}
