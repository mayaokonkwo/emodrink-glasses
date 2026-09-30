//
// ChimeTone.swift
//
// The soft "note for later" cue: two short sine notes as an in-memory
// 16-bit mono WAV, played through the same audio route as speech so it
// reaches whatever the wearer hears Hermes on. Generated, not bundled - no
// asset to register. Foundation only; tested in tests/chime.
//

import Foundation

enum ChimeTone {
    static func wav(sampleRate: Int = 24_000) -> Data {
        let notes: [(frequency: Double, seconds: Double)] = [(880, 0.14), (1318.5, 0.2)]
        let amplitude = 0.5 * Double(Int16.max)
        var samples: [Int16] = []
        for note in notes {
            let count = Int(note.seconds * Double(sampleRate))
            for i in 0..<count {
                let t = Double(i) / Double(sampleRate)
                // 5 ms attack, linear release over the note: no clicks.
                let attack = min(1, t / 0.005)
                let release = 1 - Double(i) / Double(count)
                let value = sin(2 * .pi * note.frequency * t) * amplitude * attack * release
                samples.append(Int16(value))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for s in samples { append(s) }
        return data
    }
}
