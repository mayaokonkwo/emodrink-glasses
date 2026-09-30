//
// Standalone tests for ChimeTone. Build + run:
//   xcrun swiftc HermesGlasses/Services/BuildCheck/ChimeTone.swift \
//     tests/chime/main.swift -o /tmp/chime && /tmp/chime
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
let wav = ChimeTone.wav(sampleRate: 24_000)
expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF", "RIFF header")
expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE", "WAVE tag")
let dataSize = wav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
expect(Int(dataSize) == wav.count - 44, "data chunk size matches")
let seconds = Double(dataSize) / 2 / 24_000
expect(seconds > 0.25 && seconds < 0.5, "about a third of a second (\(seconds))")
let samples = wav[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
expect(samples.map { abs(Int($0)) }.max()! < 20_000, "soft: peak below ~60% full scale")
expect(abs(Int(samples.last!)) < 200, "fades out (no click)")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
