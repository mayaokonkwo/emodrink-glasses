//
// Standalone tests for the physiology sources and store. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     HermesGlasses/Services/EmoDrink/PhysiologySource.swift \
//     HermesGlasses/Services/EmoDrink/PhysiologyStore.swift \
//     tests/emodrink-source/main.swift -o /tmp/ed-source && /tmp/ed-source
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

// Mock profiles land on the states the spec table promises.
let rested = MockProfile.rested.snapshot(date: "2026-10-07")
let shortNight = MockProfile.shortNight.snapshot(date: "2026-10-07")
let stressed = MockProfile.stressed.snapshot(date: "2026-10-07")
expect(rested.bodyState == BodyState(recovery: .high, arousal: .mid), "rested -> high/mid")
expect(shortNight.bodyState == BodyState(recovery: .low, arousal: .mid), "short night -> low/mid")
expect(stressed.bodyState == BodyState(recovery: .low, arousal: .high), "stressed -> low/high")
expect(rested.date == "2026-10-07" && rested.source == "sample: rested", "mock carries the date and a sample label")
expect(MockProfile(rawValue: "short_night") == .shortNight, "stored raw value is short_night")
expect(MockProfile.allCases.count == 3, "three profiles")

// The repo's mock feed decodes and is today-shaped.
let feed = FileManager.default.contents(atPath: "mock/physiology.json")
expect(feed != nil, "mock/physiology.json exists")
let feedSnap = try? PhysiologySnapshot.decode(feed ?? Data())
expect(feedSnap != nil && feedSnap?.source == "Garmin Venu 3S", "mock feed decodes")

// Defaults.
expect(EmoDrinkDefaults.defaultSourceURL == "https://raw.githubusercontent.com/mayaokonkwo/emodrink-glasses/main/mock/physiology.json", "default URL points at the repo's mock feed")
expect(URL(string: EmoDrinkDefaults.defaultSourceURL) != nil, "default URL parses")

// Remote source: a bad URL string is rejected up front.
expect(RemoteJSONPhysiologySource(urlString: "") == nil, "empty URL string gives nil source")
expect(RemoteJSONPhysiologySource(urlString: "https://example.com/x.json")?.label == "example.com", "label is the host")

// Store round trip in a temp directory.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emodrink-test-\(UUID().uuidString)")
let store = PhysiologyStore(directory: dir)
expect(store.load() == nil, "empty store loads nil")
let cached = CachedSnapshot(snapshot: shortNight, fetchedAt: Date(timeIntervalSince1970: 1_000_000), sourceLabel: "Garmin, 07:12")
try! store.save(cached)
let back = store.load()
expect(back == cached, "save then load round-trips")
expect(back?.snapshot.isToday("2026-10-07") == true && back?.snapshot.isToday("2026-10-08") == false, "a cached snapshot from yesterday is not today's")
store.clear()
expect(store.load() == nil, "clear empties the store")
try? FileManager.default.removeItem(at: dir)

// Mock source fetch is async but immediate.
let group = DispatchGroup(); group.enter()
Task {
    let s = try? await MockPhysiologySource(profile: .stressed, today: { "2026-10-07" }).fetch()
    expect(s == stressed, "mock source fetch returns the profile for today")
    group.leave()
}
group.wait()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
