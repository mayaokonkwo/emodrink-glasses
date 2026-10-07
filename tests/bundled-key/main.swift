//
// Standalone tests for BundledAIKey's Keychain decision (seed, rotate,
// never overwrite a user key). No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/BundledAIKey.swift \
//     HermesGlasses/Services/DirectClient.swift \
//     HermesGlasses/Services/Providers/AIProvider.swift \
//     HermesGlasses/Services/Providers/AnthropicProvider.swift \
//     HermesGlasses/Services/Providers/OpenAICompatibleProvider.swift \
//     HermesGlasses/Services/Providers/GeminiProvider.swift \
//     tests/bundled-key/main.swift -o /tmp/bundled-key-tests && /tmp/bundled-key-tests
//
// Only the pure `keychainAction` and `sha256Hex` run here; nothing touches
// the Keychain.
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let oldKey = "bundled-old"
let newKey = "bundled-new"
let userKey = "typed-by-user"
let oldHash = BundledAIKey.sha256Hex(oldKey)
let newHash = BundledAIKey.sha256Hex(newKey)

expect(BundledAIKey.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
       "sha256Hex matches the known vector")
expect(oldHash.count == 64 && oldHash != oldKey, "the hash is hex, never the key")

typealias A = BundledAIKey.KeychainAction
expect(BundledAIKey.keychainAction(stored: nil, bundled: newKey, seededHash: nil) == A.write,
       "no key yet: seed")
expect(BundledAIKey.keychainAction(stored: nil, bundled: newKey, seededHash: oldHash) == A.write,
       "key deleted later: seed again")
expect(BundledAIKey.keychainAction(stored: newKey, bundled: newKey, seededHash: newHash) == A.leave,
       "already seeded with this key: nothing to do")
expect(BundledAIKey.keychainAction(stored: newKey, bundled: newKey, seededHash: nil) == A.recordHash,
       "seeded before hashes existed: only record the hash")
expect(BundledAIKey.keychainAction(stored: oldKey, bundled: newKey, seededHash: oldHash) == A.write,
       "our old seeded key + a new bundled key: rotate")
expect(BundledAIKey.keychainAction(stored: userKey, bundled: newKey, seededHash: oldHash) == A.leave,
       "a user key is never overwritten")
expect(BundledAIKey.keychainAction(stored: userKey, bundled: newKey, seededHash: nil) == A.leave,
       "a user key with no seed history is never overwritten")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
