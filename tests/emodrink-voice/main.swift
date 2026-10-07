//
// Standalone tests for VoicePicker. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/VoicePicker.swift \
//     tests/emodrink-voice/main.swift -o /tmp/ed-voice && /tmp/ed-voice
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

func v(_ name: String, _ lang: String, _ quality: Int, novelty: Bool = false) -> VoiceDescriptor {
    VoiceDescriptor(identifier: "com.apple.voice.\(quality).\(lang).\(name)", name: name, language: lang, quality: quality, isNovelty: novelty)
}
let samantha = v("Samantha", "en-US", 1)
let avaEnhanced = v("Ava", "en-US", 2)
let zoePremium = v("Zoe", "en-US", 3)
let avaPremium = v("Ava", "en-US", 3)
let danielPremium = v("Daniel", "en-GB", 3)
let fredDefault = v("Fred", "en-US", 1)
let bahh = v("Bahh", "en-US", 3, novelty: true)
let kyoko = v("Kyoko", "ja-JP", 1)
let orenEnhanced = v("O-ren", "ja-JP", 2)
let hattori = v("Hattori", "ja-JP", 1)

// Quality first, then the preferred list, then the exact locale.
expect(VoicePicker.pick(for: .en, available: [samantha, avaEnhanced, zoePremium, danielPremium]) == zoePremium, "premium beats enhanced; preferred Zoe beats Daniel")
expect(VoicePicker.pick(for: .en, available: [zoePremium, avaPremium]) == avaPremium, "within premium, Ava before Zoe")
expect(VoicePicker.pick(for: .en, available: [samantha, avaEnhanced]) == avaEnhanced, "enhanced beats default")
expect(VoicePicker.pick(for: .en, available: [fredDefault, samantha]) == samantha, "within default, Samantha before Fred")
expect(VoicePicker.pick(for: .en, available: [danielPremium, v("Zoe", "en-AU", 3)]) == v("Zoe", "en-AU", 3), "preferred name beats exact locale at equal quality")
expect(VoicePicker.pick(for: .en, available: [v("Nora", "en-GB", 2), v("Nora", "en-US", 2)]) == v("Nora", "en-US", 2), "exact locale breaks a remaining tie")
expect(VoicePicker.pick(for: .en, available: [bahh, fredDefault]) == fredDefault, "novelty voices never")
expect(VoicePicker.pick(for: .en, available: []) == nil, "nothing installed")

// Japanese.
expect(VoicePicker.pick(for: .ja, available: [kyoko, orenEnhanced, zoePremium]) == orenEnhanced, "ja: enhanced O-ren beats default Kyoko")
expect(VoicePicker.pick(for: .ja, available: [hattori, kyoko]) == kyoko, "ja: Kyoko preferred among defaults")
expect(VoicePicker.pick(for: .ja, available: [hattori, zoePremium]) == hattori, "ja: any ja-JP voice before nothing")

// Fallback stays in language (Review Focus 3).
expect(VoicePicker.pick(for: .ja, available: [kyoko, zoePremium]) == kyoko, "fallback stays in language: ja default, never the English premium")
let onlyEnglish = VoicePicker.choose(for: .ja, available: [zoePremium, samantha])
expect(onlyEnglish.voice == zoePremium && onlyEnglish.language == .en, "no ja voice at all: speak English, and say so")
let japanese = VoicePicker.choose(for: .ja, available: [kyoko, zoePremium])
expect(japanese.voice == kyoko && japanese.language == .ja, "a ja voice exists: speak Japanese")

// Install hint.
expect(VoicePicker.needsEnhancedHint(for: .en, available: [samantha]), "only a default English voice: hint")
expect(!VoicePicker.needsEnhancedHint(for: .en, available: [samantha, avaEnhanced]), "enhanced English installed: no hint")
expect(VoicePicker.needsEnhancedHint(for: .ja, available: [kyoko, zoePremium]), "only a default Japanese voice: hint")
expect(VoicePicker.needsEnhancedHint(for: .ja, available: [zoePremium]), "no Japanese voice: hint")
expect(!VoicePicker.needsEnhancedHint(for: .ja, available: [orenEnhanced]), "enhanced Japanese installed: no hint")

// Pace.
expect(VoicePicker.rate == 0.47 && VoicePicker.pitch == 1.0, "rate 0.47, pitch 1.0")
expect(VoicePicker.preferredNames(for: .en) == ["Ava", "Zoe", "Samantha"] && VoicePicker.preferredNames(for: .ja) == ["Kyoko", "O-ren"], "preferred lists")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
