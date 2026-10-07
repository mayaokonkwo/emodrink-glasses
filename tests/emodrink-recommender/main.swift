//
// Standalone tests for DrinkRecommender. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     HermesGlasses/Services/EmoDrink/DrinkRecommender.swift \
//     tests/emodrink-recommender/main.swift -o /tmp/ed-rec && /tmp/ed-rec
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)

func snap(hours: Double, score: Int? = nil, hrv: Double? = nil, base: Double? = nil,
          hr: Double? = nil, hrBase: Double? = nil, steps: Int? = nil, stress: Int? = nil) -> PhysiologySnapshot {
    PhysiologySnapshot(date: "2026-10-07", source: "t", sleep: SleepSummary(hours: hours, score: score),
                       hrvMs: hrv, hrvBaselineMs: base, restingHR: hr, restingHRBaseline: hrBase,
                       steps: steps, stress: stress)
}
// The three mock profiles, as the spec table has them.
let rested = snap(hours: 7.8, score: 86, hrv: 58, base: 52, hr: 52, hrBase: 54, steps: 3000, stress: 22)
let shortNight = snap(hours: 5.1, score: 48, hrv: 43, base: 52, hr: 57, hrBase: 54, steps: 2500, stress: 38)
let stressed = snap(hours: 6.4, score: 63, hrv: 36, base: 52, hr: 61, hrBase: 54, steps: 4000, stress: 71)

expect(rested.bodyState == BodyState(recovery: .high, arousal: .mid), "rested profile maps to high/mid")
expect(shortNight.bodyState == BodyState(recovery: .low, arousal: .mid), "short night maps to low/mid")
expect(stressed.bodyState == BodyState(recovery: .low, arousal: .high), "stressed maps to low/high")

// Wanted functions table.
expect(DrinkRecommender.wantedFunctions(state: BodyState(recovery: .low, arousal: .high), hour: 9, steps: nil) == [.calm, .hydrate], "low/high wants calm, hydrate")
expect(DrinkRecommender.wantedFunctions(state: BodyState(recovery: .low, arousal: .mid), hour: 9, steps: nil) == [.energise, .recover, .hydrate], "low/mid morning wants energise first")
expect(DrinkRecommender.wantedFunctions(state: BodyState(recovery: .low, arousal: .low), hour: 15, steps: nil) == [.recover, .hydrate], "low/low at 15:00 drops energise")
expect(DrinkRecommender.wantedFunctions(state: BodyState(recovery: .mid, arousal: .high), hour: 9, steps: nil) == [.calm, .refresh], "mid/high wants calm, refresh")
expect(DrinkRecommender.wantedFunctions(state: BodyState(recovery: .mid, arousal: .mid), hour: 9, steps: nil) == [.hydrate, .refresh], "mid/mid wants hydrate, refresh")
expect(DrinkRecommender.wantedFunctions(state: BodyState(recovery: .high, arousal: .low), hour: 9, steps: nil) == [.refresh, .hydrate], "high/any wants refresh, hydrate")
expect(DrinkRecommender.wantedFunctions(state: BodyState(recovery: .high, arousal: .mid), hour: 9, steps: 8001) == [.hydrate, .refresh], "over 8000 steps puts hydrate first, once")

// Picks.
expect(DrinkRecommender.recommend(snapshot: rested, catalog: catalog, hour: 9, lowSugar: false)?.pick.id == "wilkinson-tansan", "rested at 09:00 -> Wilkinson Tansan")
expect(DrinkRecommender.recommend(snapshot: shortNight, catalog: catalog, hour: 9, lowSugar: false)?.pick.id == "wonda-morning-shot", "short night at 09:00 -> Wonda Morning Shot")
expect(DrinkRecommender.recommend(snapshot: shortNight, catalog: catalog, hour: 19, lowSugar: false)?.pick.id == "super-h2o", "short night at 19:00 -> Super H2O (no caffeine)")
expect(DrinkRecommender.recommend(snapshot: stressed, catalog: catalog, hour: 9, lowSugar: false)?.pick.id == "rokujo-mugicha", "stressed at 09:00 -> Rokujo Mugicha")
expect(DrinkRecommender.recommend(snapshot: shortNight, catalog: catalog, hour: 9, lowSugar: true)?.pick.id == "wonda-kin-no-bito-black", "low sugar flips the coffee to the black one")

// Scoring rules.
let wonda = catalog.drink(id: "wonda-morning-shot")!
expect(DrinkRecommender.score(wonda, wants: [.energise], hour: 9, lowSugar: false) == 3, "first want scores 3")
expect(DrinkRecommender.score(wonda, wants: [.energise], hour: 15, lowSugar: false) == 1, "caffeine over 30 mg after 15:00 costs 2")
expect(DrinkRecommender.score(wonda, wants: [.energise], hour: 9, lowSugar: true) == 1, "regular sugar with low sugar on costs 2")
let h2o = catalog.drink(id: "super-h2o")!
expect(DrinkRecommender.score(h2o, wants: [.calm, .recover, .hydrate], hour: 9, lowSugar: true) == 3, "second want 2 plus third want 1, low sugar does not penalise 'low'")

// Alternates, ranking, cycling.
let rec = DrinkRecommender.recommend(snapshot: stressed, catalog: catalog, hour: 9, lowSugar: false)!
expect(rec.alternates.count == 2 && !rec.alternates.contains(rec.pick), "two alternates, neither is the pick")
expect(rec.alternates[0] != rec.alternates[1], "alternates are distinct")
expect(rec.ranked.count == catalog.drinks.count && rec.ranked.first == rec.pick, "ranked has every drink, pick first")
var cur = rec.pick
var seen: [String] = [cur.id]
for _ in 0..<4 { cur = rec.next(after: cur); expect(cur.id != seen.last, "next never repeats the current drink"); seen.append(cur.id) }
expect(rec.next(after: rec.ranked.last!) == rec.ranked.first!, "next wraps around")
expect(rec.next(after: Drink(id: "ghost", name: "", nameJa: "", kind: "", functions: [], caffeineMg: 0, sugar: .none, served: .cold)) == rec.ranked.first!, "next on an unknown drink restarts at the top")

// Stability: same input, same output.
let again = DrinkRecommender.recommend(snapshot: stressed, catalog: catalog, hour: 9, lowSugar: false)!
expect(again == rec, "deterministic")

// Reasons.
let r1 = DrinkRecommender.reasons(snapshot: shortNight, hour: 19)
expect(r1.contains("slept 5.1 h"), "reasons mention sleep hours: \(r1)")
expect(r1.contains("sleep score 48"), "reasons mention the score")
expect(r1.contains("HRV 9 ms under your usual"), "reasons mention HRV when 5 or more under")
expect(r1.contains("it is after 3 pm"), "reasons mention the cutoff after 15:00")
expect(r1.count <= 5, "at most five reasons")
let r2 = DrinkRecommender.reasons(snapshot: snap(hours: 7.5), hour: 9)
expect(r2 == ["slept 7.5 h"], "reasons without baselines or score mention only sleep: \(r2)")
let r3 = DrinkRecommender.reasons(snapshot: stressed, hour: 9)
expect(r3.contains("resting heart rate 7 over your usual") && r3.contains("stress 71"), "reasons mention heart rate and stress")
expect(DrinkRecommender.reasons(snapshot: snap(hours: 7, steps: 8400), hour: 9).contains("8,400 steps already"), "reasons mention steps over 8000")
expect(rec.reasonLine == rec.reasons.prefix(2).joined(separator: ", "), "reasonLine is the first two reasons")

// Japanese reasons (spec section 6). The language never changes the pick.
let jaReasons = DrinkRecommender.reasons(snapshot: snap(hours: 5.1, score: 48, hrv: 38, base: 52, hr: 61, hrBase: 54, stress: 71), hour: 15, language: .ja)
expect(jaReasons == ["睡眠5.1時間", "睡眠スコア48", "HRVがいつもより14ms低い", "安静時心拍がいつもより7高い", "ストレス71"], "ja reasons in priority order, at most five: \(jaReasons)")
expect(DrinkRecommender.reasons(snapshot: snap(hours: 7, steps: 8400), hour: 16, language: .ja) == ["睡眠7.0時間", "すでに8,400歩", "もう15時過ぎ"], "ja steps and the cutoff")
expect(DrinkRecommender.reasons(snapshot: snap(hours: 7.5), hour: 9, language: .ja) == ["睡眠7.5時間"], "ja reasons without baselines mention only sleep")
let recJa = DrinkRecommender.recommend(snapshot: stressed, catalog: catalog, hour: 9, lowSugar: false, language: .ja)!
expect(recJa.pick == rec.pick && recJa.ranked == rec.ranked, "language never changes the pick or the ranking")
expect(recJa.reasons.first == "睡眠6.4時間" && recJa.reasonLine == "睡眠6.4時間, 睡眠スコア63", "ja reasons ride on the recommendation")
expect(DrinkRecommender.reasons(snapshot: shortNight, hour: 19) == DrinkRecommender.reasons(snapshot: shortNight, hour: 19, language: .en), "English is the default")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
