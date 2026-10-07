//
// Standalone tests for PhysiologySnapshot and BodyState. Build + run:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     tests/emodrink-snapshot/main.swift -o /tmp/ed-snapshot && /tmp/ed-snapshot
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let full = """
{"date":"2026-10-07","source":"Garmin Venu 3S","sleep":{"hours":6.2,"score":61},
 "hrv_ms":38,"hrv_baseline_ms":52,"resting_hr":58,"resting_hr_baseline":54,"steps":4200,"stress":46,
 "unknown_future_key":true}
""".data(using: .utf8)!

let s = try! PhysiologySnapshot.decode(full)
expect(s.date == "2026-10-07", "date decodes")
expect(s.sleep.hours == 6.2 && s.sleep.score == 61, "sleep decodes")
expect(s.hrvDelta == -14, "hrv delta is hrv minus baseline")
expect(s.restingHRDelta == 4, "resting hr delta")
expect(s.steps == 4200 && s.stress == 46, "optional ints decode")
expect(s.isToday("2026-10-07") && !s.isToday("2026-10-08"), "isToday compares the date string")

let roundTrip = try! PhysiologySnapshot.decode(try! s.encoded())
expect(roundTrip == s, "encode/decode round trip")

// Minimal document: sleep only, no baselines, no score.
let minimal = """
{"date":"2026-10-07","source":"manual","sleep":{"hours":7.5}}
""".data(using: .utf8)!
let m = try! PhysiologySnapshot.decode(minimal)
expect(m.sleep.score == nil && m.hrvDelta == nil && m.restingHRDelta == nil, "no baselines: deltas are nil")
expect(m.bodyState == BodyState(recovery: .high, arousal: .mid), "no baselines: recovery from sleep alone, arousal mid")

expect((try? PhysiologySnapshot.decode("{}".data(using: .utf8)!)) == nil, "empty object does not decode")

func snap(hours: Double, score: Int? = nil, hrv: Double? = nil, base: Double? = nil,
          hr: Double? = nil, hrBase: Double? = nil, stress: Int? = nil) -> PhysiologySnapshot {
    PhysiologySnapshot(date: "2026-10-07", source: "t", sleep: SleepSummary(hours: hours, score: score),
                       hrvMs: hrv, hrvBaselineMs: base, restingHR: hr, restingHRBaseline: hrBase,
                       steps: nil, stress: stress)
}
expect(snap(hours: 5.9).bodyState.recovery == .low, "under 6 h is low")
expect(snap(hours: 6.0).bodyState.recovery == .mid, "6 h is mid")
expect(snap(hours: 7.0).bodyState.recovery == .high, "7 h is high")
expect(snap(hours: 7.0, score: 49).bodyState.recovery == .mid, "score under 50 nudges down")
expect(snap(hours: 7.0, hrv: 40, base: 51).bodyState.recovery == .mid, "HRV more than 10 under nudges down")
expect(snap(hours: 7.0, hrv: 42, base: 52).bodyState.recovery == .high, "HRV exactly 10 under does not nudge")
expect(snap(hours: 6.5, score: 80, hrv: 52, base: 52).bodyState.recovery == .high, "score 80 and HRV at baseline nudges up")
expect(snap(hours: 5.0, score: 40).bodyState.recovery == .low, "low clamps at low")

expect(snap(hours: 7, hr: 59, hrBase: 54).bodyState.arousal == .high, "HR 5 over is high")
expect(snap(hours: 7, hr: 58, hrBase: 54).bodyState.arousal == .mid, "HR 4 over is mid")
expect(snap(hours: 7, hr: 49, hrBase: 54).bodyState.arousal == .low, "HR 5 under is low")
expect(snap(hours: 7, hr: 54, hrBase: 54, stress: 65).bodyState.arousal == .high, "stress 65 overrides to high")
expect(snap(hours: 5, hr: 54, hrBase: 54, stress: 25).bodyState.arousal == .low, "stress 25 with low recovery is low")
expect(snap(hours: 8, hr: 54, hrBase: 54, stress: 25).bodyState.arousal == .mid, "stress 25 with high recovery stays mid")
expect(snap(hours: 7, stress: 70).bodyState.arousal == .high, "no baselines but high stress is high")

expect(BodyLevel.low < BodyLevel.mid && BodyLevel.mid < BodyLevel.high, "levels are ordered")
expect(BodyLevel.high.up == .high && BodyLevel.low.down == .low, "up/down clamp")

let day = EmoDrinkDay.string(for: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
expect(day == "1970-01-01", "day string is yyyy-MM-dd")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
