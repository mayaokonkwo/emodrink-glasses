//
// BundledAIKey.swift
//
// The EmoDrink gift build carries its own assistant key, so the person who
// receives it never has to find or type one. The key, provider and model
// come from the gitignored Config/Secrets.xcconfig at build time, through
// Info.plist's `EmoDrinkBundledAI` dict; nothing is in the repo.
//
// `seedIfNeeded()` runs first thing in `HermesGlassesApp.init()`, before the
// session view model reads its provider state. It never overwrites a key the
// user typed: the Keychain is written only when that provider has no key.
//

import Foundation

enum BundledAIKey {
    static let infoKey = "EmoDrinkBundledAI"
    /// Set once the bundled provider and model have been selected, so a
    /// provider or model the user picks afterwards is not reset on the next
    /// launch.
    static let seededKey = "emodrink_bundled_ai_seeded"

    struct Config: Equatable {
        let provider: String
        let model: String
        let key: String
    }

    /// The bundled values, or nil when this copy was built without them
    /// (an empty key, or an unexpanded `$(BUNDLED_AI_KEY)` placeholder).
    static func config(bundle: Bundle = .main) -> Config? {
        guard let dict = bundle.object(forInfoDictionaryKey: infoKey) as? [String: Any] else {
            return nil
        }
        func value(_ name: String) -> String {
            let raw = (dict[name] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.hasPrefix("$(") ? "" : raw
        }
        let key = value("Key")
        let provider = value("Provider")
        guard !key.isEmpty, !provider.isEmpty else { return nil }
        return Config(provider: provider, model: value("Model"), key: key)
    }

    /// Selects the bundled provider and model on first launch, and stores the
    /// bundled key only when that provider has no key yet.
    static func seedIfNeeded(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        guard let config = config(bundle: bundle) else { return }
        if !defaults.bool(forKey: seededKey) {
            defaults.set(config.provider, forKey: "direct_provider_id")
            if !config.model.isEmpty {
                defaults.set(config.model, forKey: "direct_model_\(config.provider)")
            }
            defaults.set(true, forKey: seededKey)
        }
        if !DirectClient.hasKey(for: config.provider) {
            DirectClient.storeKey(config.key, for: config.provider)
        }
    }

    /// True while the bundled key is the one in use for the bundled provider,
    /// so Settings shows "included" instead of a key field.
    static var isActive: Bool {
        guard let config = config() else { return false }
        return DirectClient.providerID == config.provider
            && DirectClient.loadKey(for: config.provider) == config.key
    }
}
