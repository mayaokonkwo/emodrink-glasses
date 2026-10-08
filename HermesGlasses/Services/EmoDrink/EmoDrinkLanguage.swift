//
// EmoDrinkLanguage.swift
//
// Which language EmoDrink speaks, hears and shows on the lens, and every
// lens and spoken string in both languages. Settings labels stay English.
// Auto follows the FIRST of the iPhone's preferred languages. Foundation
// only; tested in tests/emodrink-language.
//

import Foundation

enum Language: String, CaseIterable, Equatable {
    case en, ja

    /// SFSpeechRecognizer locale.
    var sttLocale: String { self == .ja ? "ja-JP" : "en-US" }
    /// AVSpeechSynthesisVoice language.
    var ttsLanguage: String { self == .ja ? "ja-JP" : "en-US" }
    var other: Language { self == .ja ? .en : .ja }
}

enum EmoDrinkLanguage {
    static let settingKey = "emodrink_language"
    static let sttFallbackNotice = "Japanese speech recognition is not available on this iPhone; using English."

    enum Setting: String, CaseIterable, Identifiable {
        case auto, en, ja
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto (iPhone language)"
            case .en: return "English"
            case .ja: return "Japanese"
            }
        }
    }

    static func setting(in defaults: UserDefaults = .standard) -> Setting {
        Setting(rawValue: defaults.string(forKey: settingKey) ?? "") ?? .auto
    }

    static func setSetting(_ value: Setting, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: settingKey)
    }

    /// Manual choice wins; auto is Japanese only when the iPhone's FIRST
    /// preferred language is Japanese ("en-JP" is English).
    static func resolve(_ setting: Setting, preferredLanguages: [String]) -> Language {
        switch setting {
        case .en: return .en
        case .ja: return .ja
        case .auto:
            return (preferredLanguages.first?.lowercased().hasPrefix("ja") ?? false) ? .ja : .en
        }
    }

    static var resolved: Language {
        resolve(setting(), preferredLanguages: Locale.preferredLanguages)
    }
}

/// Every lens and spoken string, per language.
struct EmoDrinkStrings: Equatable {
    let language: Language
    private var ja: Bool { language == .ja }

    // MARK: Lens and home

    var watchingHeading: String { ja ? "ドリンクモード" : "Drink mode" }
    var watchingText: String { ja ? "自販機を探しています" : "Watching for a vending machine" }
    var watchingHint: String { ja ? "「何を飲めばいい」といつでもどうぞ" : "Say \"what should I drink\" any time" }
    var idleTitle: String { ja ? "自販機を見守り中" : "Watching for a vending machine" }
    var idleHint: String { ja ? "「何を飲めばいい」といつでもどうぞ" : "Say 「何を飲めばいい」 or \"what should I drink\" any time" }
    var choiceHeading: String { ja ? "どれにする？" : "Pick one" }
    var choiceHint: String { ja ? "タップか、番号か名前で選べます" : "Tap, or say a number or a name" }
    var stoppedTitle: String { ja ? "停止中" : "Stopped" }
    var stoppedHint: String { ja ? "「Start」をタップすると自販機を探します" : "Tap Start to watch for a vending machine" }
    var visionCheckFailed: String { ja ? "画像の確認に失敗しました" : "Vision check failed" }
    var noMachine: String { ja ? "自販機が見当たりません" : "No vending machine in view" }
    var cameraNotReady: String { ja ? "カメラの準備ができていません" : "Camera not ready yet" }
    var checkResting: String { ja ? "今の時間の確認回数を使い切りました" : "This hour's checks are used up" }
    var sessionDidNotStart: String { ja ? "セッションを開始できませんでした。" : "The session did not start." }
    var micBlocked: String {
        ja ? "声で選ぶには、マイクと音声認識を許可してください。" : "Allow the microphone and speech recognition to pick by voice."
    }
    var whyLabel: String { ja ? "なぜ？" : "Why" }
    var thanksLabel: String { ja ? "ありがとう" : "Thanks" }
    var backLabel: String { ja ? "戻る" : "Back" }
    var voiceInstallHint: String {
        ja ? "もっと自然な声にするには、設定 › アクセシビリティ › 読み上げコンテンツ › 声 で日本語の拡張音声をダウンロードしてください。"
           : "For a more natural voice, download an Enhanced English voice in Settings › Accessibility › Spoken Content › Voices."
    }

    // MARK: Spoken

    var cameraLost: String { ja ? "カメラが見えません。ドリンクモードを一時停止します。" : "Camera lost. Drink mode is paused." }
    var cameraStopped: String { ja ? "カメラが止まりました。" : "The camera stream stopped." }
    var cameraDidNotOpen: String {
        ja ? "カメラが開きませんでした。「何を飲めばいい」と言えば、カメラなしで選べます。"
           : "The camera didn't open. Say what should I drink to pick without it."
    }
    var enjoy: String { ja ? "どうぞ、楽しんで。" : "Enjoy." }

    /// Fallback for the three-drink step (the AI phrases it when it can).
    func choicesLine(names: [String]) -> String {
        if ja { return names.joined(separator: "、") + "はどうですか" }
        switch names.count {
        case 0: return "How about a drink?"
        case 1: return "How about \(names[0])?"
        case 2: return "How about \(names[0]) or \(names[1])?"
        default: return "How about \(names.dropLast().joined(separator: ", ")), or \(names[names.count - 1])?"
        }
    }

    /// Fallback after a choice: the drink, then up to two reasons.
    func chosenLine(name: String, reasons: [String]) -> String {
        let top = Array(reasons.prefix(2))
        if ja {
            let base = "\(name)、いい選択です。"
            return top.isEmpty ? base : base + top.joined(separator: "、") + "なので、ちょうどいいと思います。"
        }
        guard !top.isEmpty else { return "Good choice, \(name)." }
        let joined = top.joined(separator: ", ")
        return "Good choice, \(name). " + joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }

    /// Fallback for "why" when the AI cannot answer.
    func whyLine(reasons: [String]) -> String {
        if ja {
            guard !reasons.isEmpty else { return "昨夜の睡眠に合わせて選びました。" }
            return reasons.prefix(3).joined(separator: "、") + "ので、これを選びました。"
        }
        guard let first = reasons.first else { return "Because it fits how you slept." }
        let rest = Array(reasons.dropFirst().prefix(2))
        let nounish = rest.filter { $0 != afterCutoff }
        var sentence = "Because you \(first)"
        if !nounish.isEmpty {
            sentence += ", with " + (nounish.count > 1
                ? nounish.dropLast().joined(separator: ", ") + " and " + nounish[nounish.count - 1]
                : nounish[0])
        }
        if rest.contains(afterCutoff) { sentence += ", and \(afterCutoff)" }
        return sentence + "."
    }

    // MARK: Reason fragments (DrinkRecommender.reasons renders these)

    func slept(hours: Double) -> String {
        let h = String(format: "%.1f", hours)
        return ja ? "睡眠\(h)時間" : "slept \(h) h"
    }
    func sleepScore(_ score: Int) -> String { ja ? "睡眠スコア\(score)" : "sleep score \(score)" }
    func hrvUnder(ms: Int) -> String { ja ? "HRVがいつもより\(ms)ms低い" : "HRV \(ms) ms under your usual" }
    func hrvAbove(ms: Int) -> String { ja ? "HRVがいつもより\(ms)ms高い" : "HRV \(ms) ms above your usual" }
    func restingHROver(_ bpm: Int) -> String { ja ? "安静時心拍がいつもより\(bpm)高い" : "resting heart rate \(bpm) over your usual" }
    func stress(_ value: Int) -> String { ja ? "ストレス\(value)" : "stress \(value)" }
    func stepsAlready(_ steps: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        let n = formatter.string(from: NSNumber(value: steps)) ?? String(steps)
        return ja ? "すでに\(n)歩" : "\(n) steps already"
    }
    var afterCutoff: String { ja ? "もう15時過ぎ" : "it is after 3 pm" }
}
