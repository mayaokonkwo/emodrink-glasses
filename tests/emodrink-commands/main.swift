//
// Standalone tests for EmoDrinkCommands. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/Intents.swift \
//     HermesGlasses/Services/EmoDrink/IntentDetector.swift \
//     HermesGlasses/Services/ChoiceDetector.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkCommands.swift \
//     tests/emodrink-commands/main.swift -o /tmp/ed-commands && /tmp/ed-commands
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

expect(EmoDrinkCommands.spoken("why") == .why, "why")
expect(EmoDrinkCommands.spoken("Why?") == .why, "Why? with punctuation")
expect(EmoDrinkCommands.spoken("why this one") == .why, "why this one")
expect(EmoDrinkCommands.spoken("something else") == .somethingElse, "something else")
expect(EmoDrinkCommands.spoken("another one") == .somethingElse, "another one")
expect(EmoDrinkCommands.spoken("next") == .somethingElse, "next")
expect(EmoDrinkCommands.spoken("thanks") == .thanks, "thanks")
expect(EmoDrinkCommands.spoken("Thank you!") == .thanks, "thank you")
expect(EmoDrinkCommands.spoken("cheers") == .thanks, "cheers")
expect(EmoDrinkCommands.spoken("is there caffeine in it") == nil, "a question is not a command")
expect(EmoDrinkCommands.spoken("Why do you suggest this drink for me right now?") == nil, "the generated why question is NOT re-claimed")
expect(EmoDrinkCommands.spoken("") == nil, "empty")

// The lens buttons: tapping one submits its label, which the claimer reads back.
expect(EmoDrinkCommands.choices.map(\.label) == ["Why", "Something else", "Thanks"], "three choices in order")
expect(EmoDrinkCommands.choices.allSatisfy { EmoDrinkCommands.spoken($0.reply) != nil }, "every button's reply is itself a recognised command")
expect(Set(EmoDrinkCommands.choices.map(\.id)).count == 3, "choice ids are distinct")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
