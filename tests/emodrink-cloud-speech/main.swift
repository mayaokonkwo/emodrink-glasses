//
// Standalone tests for CloudSpeechCodec (the natural cloud voice's request,
// voice, mime parsing and WAV header). Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/CloudSpeechCodec.swift \
//     tests/emodrink-cloud-speech/main.swift -o /tmp/ed-cloud-speech && /tmp/ed-cloud-speech
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

// Voices per language.
expect(CloudSpeechCodec.voiceName(for: .ja) == "Kore", "Japanese speaks with Kore")
expect(CloudSpeechCodec.voiceName(for: .en) == "Aoede", "English speaks with Aoede")

// Endpoint.
let url = CloudSpeechCodec.endpoint(model: "test-model-tts", key: "dummy")
expect(url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/test-model-tts:generateContent?key=dummy", "endpoint carries the model and the key")
expect(CloudSpeechCodec.endpoint(model: "", key: "dummy") == nil, "no model, no endpoint")
expect(CloudSpeechCodec.endpoint(model: "m", key: "") == nil, "no key, no endpoint")

// Request body.
func body(_ text: String, _ language: Language) -> [String: Any] {
    let data = try! CloudSpeechCodec.requestBody(text: text, language: language)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}
let ja = body("こんにちは", .ja)
let contents = ja["contents"] as? [[String: Any]]
let parts = contents?.first?["parts"] as? [[String: Any]]
expect(parts?.first?["text"] as? String == "こんにちは", "body carries the text")
let config = ja["generationConfig"] as? [String: Any]
expect(config?["responseModalities"] as? [String] == ["AUDIO"], "body asks for audio only")
let speech = config?["speechConfig"] as? [String: Any]
let voice = (speech?["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any]
expect(voice?["voiceName"] as? String == "Kore", "Japanese body names Kore")
let en = body("Hello", .en)
let enVoice = (((en["generationConfig"] as? [String: Any])?["speechConfig"] as? [String: Any])?["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any]
expect(enVoice?["voiceName"] as? String == "Aoede", "English body names Aoede")

// Mime types.
expect(CloudSpeechCodec.audioFormat(mimeType: "audio/L16;codec=pcm;rate=24000") == .pcm16(sampleRate: 24000, channels: 1), "L16 at 24 kHz is raw PCM, rate 24000")
expect(CloudSpeechCodec.audioFormat(mimeType: "audio/L16; codec=pcm; rate=16000") == .pcm16(sampleRate: 16000, channels: 1), "rate parsed with spaces")
expect(CloudSpeechCodec.audioFormat(mimeType: "audio/wav") == .wav, "audio/wav is WAV")
expect(CloudSpeechCodec.audioFormat(mimeType: "AUDIO/WAV") == .wav, "mime case does not matter")
expect(CloudSpeechCodec.audioFormat(mimeType: "audio/L16") == .pcm16(sampleRate: 24000, channels: 1), "no rate means 24 kHz")

// WAV header for 1 s of 24 kHz mono 16-bit PCM.
let pcm = Data(repeating: 0, count: 48000)
let wav = CloudSpeechCodec.wavData(fromPCM16: pcm, sampleRate: 24000, channels: 1)
func u32(_ at: Int) -> UInt32 { wav.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
func u16(_ at: Int) -> UInt16 { wav.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
func ascii(_ at: Int) -> String { String(decoding: wav.subdata(in: at..<at + 4), as: UTF8.self) }
expect(wav.count == 44 + 48000, "44-byte header in front of the samples")
expect(ascii(0) == "RIFF" && ascii(8) == "WAVE" && ascii(12) == "fmt " && ascii(36) == "data", "RIFF, WAVE, fmt and data chunks")
expect(u32(4) == 36 + 48000, "RIFF size is 36 + data")
expect(u32(16) == 16 && u16(20) == 1, "PCM fmt chunk")
expect(u16(22) == 1 && u32(24) == 24000, "mono, 24 kHz")
expect(u32(28) == 48000 && u16(32) == 2 && u16(34) == 16, "byte rate, block align, 16 bits")
expect(u32(40) == 48000, "data size")

// Responses.
func response(mime: String, audio: Data) -> Data {
    let json: [String: Any] = ["candidates": [["content": ["parts": [["inlineData": ["mimeType": mime, "data": audio.base64EncodedString()]]]]]]]
    return try! JSONSerialization.data(withJSONObject: json)
}
let fromPCM = try? CloudSpeechCodec.wavAudio(fromResponse: response(mime: "audio/L16;codec=pcm;rate=24000", audio: Data(repeating: 1, count: 480)))
expect(fromPCM?.count == 44 + 480 && fromPCM?.prefix(4) == Data("RIFF".utf8), "raw PCM response is wrapped in WAV")
let fromWAV = try? CloudSpeechCodec.wavAudio(fromResponse: response(mime: "audio/wav", audio: wav))
expect(fromWAV == wav, "WAV response passes through untouched")
var threw = false
do { _ = try CloudSpeechCodec.wavAudio(fromResponse: Data("{\"candidates\":[]}".utf8)) } catch { threw = (error as? CloudSpeechError) == .noAudio }
expect(threw, "no audio part throws noAudio")
expect(CloudSpeechError.http(429).errorDescription == "Cloud voice HTTP 429", "HTTP error text")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
