//
// Standalone tests for the app registry. No XCTest target, so build via:
//   xcrun swiftc \
//     HermesGlasses/Services/HermesApp.swift \
//     tests/apps/main.swift -o /tmp/apps-tests && /tmp/apps-tests
//
// These are the invariants a fifth app has to satisfy. They exist so that
// adding one is a matter of filling in a row and running this, rather than
// discovering at runtime that the drawer shows a blank tile or that two
// apps claim the same voice trigger.
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}

let all = HermesAppRegistry.all

// MARK: - The registry is well-formed

expect(!all.isEmpty, "registry is not empty")

let ids = all.map(\.id)
expect(Set(ids).count == ids.count, "app ids are unique (\(ids))")
expect(ids.allSatisfy { !$0.isEmpty }, "no empty ids")
expect(ids.allSatisfy { $0 == $0.lowercased() }, "ids are lowercase, for stable storage keys")

expect(all.allSatisfy { !$0.title.isEmpty }, "every app has a title")
expect(all.allSatisfy { !$0.systemImage.isEmpty }, "every app has an icon")
expect(all.allSatisfy { !$0.summary.isEmpty }, "every app has a one-line summary")

// A summary is shown on one line in the drawer.
expect(all.allSatisfy { $0.summary.count <= 80 },
       "summaries fit a drawer row: \(all.filter { $0.summary.count > 80 }.map(\.id))")

// A title has to fit a quick-action tile.
expect(all.allSatisfy { $0.title.count <= 12 },
       "titles fit a tile: \(all.filter { $0.title.count > 12 }.map(\.id))")

// MARK: - Capabilities are stated, not implied

expect(all.allSatisfy { !$0.capabilities.isEmpty },
       "every app declares at least one capability")

for app in all {
    let unique = Set(app.capabilities).count == app.capabilities.count
    expect(unique, "\(app.id) lists each capability once")
}

// Anything that draws on the glasses must say so - the lens is a single
// serialized resource and the arbitration policy reads this.
expect(HermesAppRegistry.emoDrink.capabilities.contains(.lens), "emodrink declares .lens")

// Anything holding a live camera goes full screen: a stray drag-dismiss
// would tear the stream down mid-use. (Lens and Lookup did; neither is
// listed in the gift build, so this guards any that come back.)
for app in all where app.capabilities.contains(.vision)
    && ["lens", "lookup"].contains(app.id) {
    expect(app.presentation == .fullScreen,
           "\(app.id) is full screen because it holds a live stream")
}

// MARK: - Voice ownership does not collide

let voiceGroups = all.flatMap(\.voiceGroupIDs)
expect(Set(voiceGroups).count == voiceGroups.count,
       "no two apps claim the same voice group (\(voiceGroups))")

expect(HermesAppRegistry.emoDrink.isVoiceLaunchable, "EmoDrink is voice-launchable")

// MARK: - Phone mode

// Nothing may hard-require glasses: phone mode exists precisely so that a
// user without them is not locked out.
expect(all.allSatisfy { !$0.requiresGlasses },
       "no app locks out phone mode: \(all.filter(\.requiresGlasses).map(\.id))")

// MARK: - Pinned vs drawer

expect(HermesAppRegistry.pinned.count <= HermesAppRegistry.pinnedCount,
       "pinned row holds at most \(HermesAppRegistry.pinnedCount)")
expect(HermesAppRegistry.pinned.allSatisfy { all.contains($0) },
       "pinned apps all come from the registry")
expect(HermesAppRegistry.pinned == Array(all.prefix(HermesAppRegistry.pinnedCount)),
       "pinned preserves registry order")
expect(HermesAppRegistry.hasOverflow == (all.count > HermesAppRegistry.pinnedCount),
       "overflow flag matches the count")

// The gift build lists one app: the row shows it alone, with no More tile
// and no drawer.
expect(all.map(\.id) == ["emodrink"], "the gift build lists EmoDrink alone")
expect(HermesAppRegistry.pinned.map(\.id) == ["emodrink"], "the row holds EmoDrink alone")
expect(!HermesAppRegistry.hasOverflow, "one app → no overflow, no More tile, no drawer")

// MARK: - Lookup

expect(HermesAppRegistry.app(id: "emodrink") == HermesAppRegistry.emoDrink, "lookup by id")
expect(HermesAppRegistry.app(id: "lens") == nil, "hidden apps are not found by id")
expect(HermesAppRegistry.app(id: "nope") == nil, "unknown id returns nil")

// MARK: - Capability metadata is total

for capability in HermesAppCapability.allCases {
    expect(!capability.label.isEmpty, "\(capability.rawValue) has a label")
    expect(!capability.systemImage.isEmpty, "\(capability.rawValue) has an icon")
}

// MARK: - What's new

expect(HermesAppRegistry.newAppIDs.allSatisfy { HermesAppRegistry.app(id: $0) != nil },
       "every 'new' id names a registered app")
expect(HermesAppRegistry.newAppIDs.isEmpty, "nothing is announced as new in a one-app build")
expect(HermesAppRegistry.unseenNew(opened: []).isEmpty, "nothing opened yet → still nothing unseen")
expect(HermesAppRegistry.whatsNew(opened: [], dismissed: []) == nil,
       "the one-time What's new card never appears")
expect(HermesAppRegistry.whatsNew(opened: ["emodrink"], dismissed: ["emodrink"]) == nil,
       "no card whatever is stored")
expect(HermesAppRegistry.idSet(from: "") == [], "empty storage → empty set")
expect(HermesAppRegistry.idSet(from: "a,b,,a") == ["a", "b"], "storage parses, drops blanks and duplicates")
expect(HermesAppRegistry.idSet(from: HermesAppRegistry.idString(["lens", "buildcheck"])) == ["lens", "buildcheck"],
       "storage round-trips")

expect(HermesAppRegistry.app(id: "emodrink") != nil, "emodrink is registered")
expect(HermesAppRegistry.emoDrink.capabilities == [.vision, .microphone, .lens], "emodrink declares vision, microphone, lens")
expect(HermesAppRegistry.emoDrink.voiceGroupIDs == ["emodrink", "emodrink-replies"], "emodrink owns its two voice groups")
expect(!HermesAppRegistry.emoDrink.requiresGlasses, "emodrink works in phone mode")
expect(HermesAppRegistry.pinned.contains(HermesAppRegistry.emoDrink), "emodrink sits in the quick-action row")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
