//
// Standalone tests for IntentDetector. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/Intents.swift \
//     HermesGlasses/Services/EmoDrink/IntentDetector.swift \
//     tests/intent/main.swift -o /tmp/intent-tests && /tmp/intent-tests
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}

// EmoDrink intents (whole-utterance).
expectEqual(IntentDetector.detect("what should I drink"), .recommendDrink, "what should I drink")
expectEqual(IntentDetector.detect("Hey, what should I get?"), .recommendDrink, "filler + punctuation")
expectEqual(IntentDetector.detect("pick me a drink"), .recommendDrink, "pick me a drink")
expectEqual(IntentDetector.detect("recommend a drink"), .recommendDrink, "recommend a drink")
expectEqual(IntentDetector.detect("start drink mode"), .startDrinkMode, "start drink mode")
expectEqual(IntentDetector.detect("stop drink mode"), .stopDrinkMode, "stop drink mode")
expectEqual(IntentDetector.detect("What should I drink tonight with dinner"), .none, "a longer sentence is not the command")
expectEqual(IntentDetector.detect("what is a drink"), .none, "no definitions any more")
expectEqual(IntentDetector.detect("take me to the station"), .none, "no navigation any more")
expectEqual(IntentDetector.detect("remember this person"), .none, "no people any more")
expectEqual(IntentDetector.detect(""), .none, "empty")
expectEqual(IntentDetector.normalizeCommand("  Hey,  okay please   Start Drink Mode! "), "start drink mode", "normalize strips filler and collapses spaces")

// Japanese (spec section 6), punctuation stripped, whole utterance only.
expectEqual(IntentDetector.detect("何を飲めばいい"), .recommendDrink, "何を飲めばいい")
expectEqual(IntentDetector.detect("何を飲めばいい？"), .recommendDrink, "何を飲めばいい？")
expectEqual(IntentDetector.detect("何飲もう"), .recommendDrink, "何飲もう")
expectEqual(IntentDetector.detect("おすすめの飲み物は？"), .recommendDrink, "おすすめの飲み物は？")
expectEqual(IntentDetector.detect("見守りを開始"), .startDrinkMode, "見守りを開始")
expectEqual(IntentDetector.detect("ドリンクモード開始。"), .startDrinkMode, "ドリンクモード開始。")
expectEqual(IntentDetector.detect("見守りを停止"), .stopDrinkMode, "見守りを停止")
expectEqual(IntentDetector.detect("ドリンク モード 停止"), .stopDrinkMode, "spaces a recogniser inserted between Japanese words")
expectEqual(IntentDetector.detect("何を飲めばいいか迷う"), .none, "a longer Japanese sentence is not the command")
expectEqual(IntentDetector.normalizeCommand("「なぜ」？"), "なぜ", "Japanese quotes and question mark go")
for phrase in ["何を飲めば良い", "なにを飲めばいい", "何飲めばいいかな", "何を飲めばいいか", "何を飲めばいいかな",
               "何がいい", "何を飲んだらいい", "飲み物のおすすめ"] {
    expectEqual(IntentDetector.detect(phrase), .recommendDrink, phrase)
    expectEqual(IntentDetector.detect(phrase + "？"), .recommendDrink, phrase + "？")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
