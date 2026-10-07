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
// user typed: the Keychain is written when that provider has no key, or when
// the stored key is still the one we seeded (its SHA-256 matches the hash we
// kept) and a new build carries a different bundled key (key rotation).
//

import CryptoKit
import Foundation

enum BundledAIKey {
    static let infoKey = "EmoDrinkBundledAI"
    /// Set once the bundled provider and model have been selected, so a
    /// provider or model the user picks afterwards is not reset on the next
    /// launch.
    static let seededKey = "emodrink_bundled_ai_seeded"
    /// SHA-256 hex of the key last written by `seedIfNeeded`, never the key
    /// itself. Tells "still our seeded key" apart from "a key the user typed".
    static let keyHashKey = "emodrink_bundled_ai_key_hash"

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

    /// Selects the bundled provider and model on first launch. Stores the
    /// bundled key when that provider has no key, or replaces our own
    /// earlier seeded key when a new build bundles a different one. A key
    /// the user typed is never touched (see `keychainAction`).
    static func seedIfNeeded(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        guard let config = config(bundle: bundle) else { return }
        if !defaults.bool(forKey: seededKey) {
            defaults.set(config.provider, forKey: "direct_provider_id")
            if !config.model.isEmpty {
                defaults.set(config.model, forKey: "direct_model_\(config.provider)")
            }
            defaults.set(true, forKey: seededKey)
        }
        let stored = DirectClient.loadKey(for: config.provider)
        switch keychainAction(stored: stored, bundled: config.key,
                              seededHash: defaults.string(forKey: keyHashKey)) {
        case .write:
            if DirectClient.storeKey(config.key, for: config.provider) {
                defaults.set(sha256Hex(config.key), forKey: keyHashKey)
            }
        case .recordHash:
            defaults.set(sha256Hex(config.key), forKey: keyHashKey)
        case .leave:
            break
        }
    }

    enum KeychainAction: Equatable {
        /// Store the bundled key and remember its hash.
        case write
        /// The Keychain already holds the bundled key; only remember its
        /// hash (installs seeded before the hash existed).
        case recordHash
        /// A key the user typed: never touched.
        case leave
    }

    /// Pure decision, kept apart from the Keychain so it can be tested.
    static func keychainAction(stored: String?, bundled: String, seededHash: String?) -> KeychainAction {
        guard let stored else { return .write }
        if stored == bundled {
            return seededHash == sha256Hex(bundled) ? .leave : .recordHash
        }
        // A different key: ours from an older build (rotate), or the user's.
        if let seededHash, seededHash == sha256Hex(stored) { return .write }
        return .leave
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True while the bundled key is the one in use for the bundled provider,
    /// so Settings shows "included" instead of a key field.
    static var isActive: Bool {
        guard let config = config() else { return false }
        return DirectClient.providerID == config.provider
            && DirectClient.loadKey(for: config.provider) == config.key
    }
}
