//
// CloudSpeechCodec.swift
//
// The pure half of the natural cloud voice (Gemini text-to-speech): the
// endpoint, the request body, the voice per language, the response's
// audio, and a WAV header for raw PCM. Foundation only; tested in
// tests/emodrink-cloud-speech. `CloudSpeech` does the networking.
//

import Foundation

enum CloudSpeechError: Error, Equatable, LocalizedError {
    case badEndpoint
    case http(Int)
    case noAudio
    case timedOut
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .badEndpoint: return "Cloud voice endpoint could not be built"
        case .http(let status): return "Cloud voice HTTP \(status)"
        case .noAudio: return "Cloud voice returned no audio"
        case .timedOut: return "Cloud voice timed out"
        case .playbackFailed: return "Cloud voice audio did not play"
        }
    }
}

enum CloudSpeechCodec {
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/"
    /// Gemini returns 16-bit mono PCM at 24 kHz when it does not say otherwise.
    static let defaultSampleRate = 24000

    /// Gemini prebuilt voices: Kore for Japanese, Aoede for English.
    static func voiceName(for language: Language) -> String {
        language == .ja ? "Kore" : "Aoede"
    }

    /// `POST .../models/<model>:generateContent?key=<key>`.
    static func endpoint(model: String, key: String) -> URL? {
        guard !model.isEmpty, !key.isEmpty,
              var components = URLComponents(string: baseURL + model + ":generateContent")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        return components.url
    }

    /// The generateContent body asking for audio only, in the language's voice.
    static func requestBody(text: String, language: Language) throws -> Data {
        let body: [String: Any] = [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": voiceName(for: language)]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    enum AudioFormat: Equatable {
        case wav
        case pcm16(sampleRate: Int, channels: Int)
    }

    /// `audio/wav` (or `audio/x-wav`, `audio/wave`) is a WAV file; anything
    /// else is raw 16-bit PCM, e.g. `audio/L16;codec=pcm;rate=24000`.
    static func audioFormat(mimeType: String) -> AudioFormat {
        let parts = mimeType.lowercased().split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let type = parts.first ?? ""
        if ["audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave"].contains(type) { return .wav }
        func parameter(_ name: String) -> Int? {
            parts.dropFirst().first { $0.hasPrefix(name + "=") }.flatMap { Int($0.dropFirst(name.count + 1)) }
        }
        return .pcm16(sampleRate: parameter("rate") ?? defaultSampleRate, channels: parameter("channels") ?? 1)
    }

    /// A 44-byte RIFF/WAVE header in front of 16-bit little-endian PCM.
    static func wavData(fromPCM16 pcm: Data, sampleRate: Int, channels: Int) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let blockAlign = channels * 2
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(le32(UInt32(36 + pcm.count)))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(le32(16))                                  // fmt chunk size
        wav.append(le16(1))                                   // PCM
        wav.append(le16(UInt16(channels)))
        wav.append(le32(UInt32(sampleRate)))
        wav.append(le32(UInt32(sampleRate * blockAlign)))     // byte rate
        wav.append(le16(UInt16(blockAlign)))
        wav.append(le16(16))                                  // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        wav.append(le32(UInt32(pcm.count)))
        wav.append(pcm)
        return wav
    }

    /// The first inline audio part of a generateContent response, as WAV.
    static func wavAudio(fromResponse data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { throw CloudSpeechError.noAudio }
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any],
                  let base64 = inline["data"] as? String,
                  let audio = Data(base64Encoded: base64), !audio.isEmpty
            else { continue }
            let mime = inline["mimeType"] as? String ?? ""
            switch audioFormat(mimeType: mime) {
            case .wav where audio.starts(with: Array("RIFF".utf8)):
                return audio
            case .wav:
                // Labelled WAV but headerless: treat as the default PCM.
                return wavData(fromPCM16: audio, sampleRate: defaultSampleRate, channels: 1)
            case .pcm16(let rate, let channels):
                return wavData(fromPCM16: audio, sampleRate: rate, channels: channels)
            }
        }
        throw CloudSpeechError.noAudio
    }
}
