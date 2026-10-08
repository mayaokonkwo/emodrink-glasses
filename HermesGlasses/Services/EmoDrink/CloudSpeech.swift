//
// CloudSpeech.swift
//
// The natural cloud voice: one Gemini text-to-speech call per line, WAV
// back. Every failure (offline, HTTP error, no audio, the timeout) throws,
// and HermesSpeechSynthesizer then speaks the same line on-device. The key
// rides in the URL's query, so errors are never logged with their URL.
//

import Foundation

final class CloudSpeech: Sendable {
    let model: String
    private let key: String
    private let session: URLSession

    init(key: String, model: String) {
        self.key = key
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    /// The line spoken in the language's Gemini voice, as WAV data. Throws
    /// `CloudSpeechError.timedOut` when the whole call takes over `timeout`.
    func synthesize(_ text: String, language: Language, timeout: TimeInterval = 4) async throws -> Data {
        guard let url = CloudSpeechCodec.endpoint(model: model, key: key) else {
            throw CloudSpeechError.badEndpoint
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try CloudSpeechCodec.requestBody(text: text, language: language)
        let session = self.session

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw CloudSpeechError.http(status) }
                return try CloudSpeechCodec.wavAudio(fromResponse: data)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CloudSpeechError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CloudSpeechError.noAudio }
            return first
        }
    }

    static func wavData(fromPCM16 pcm: Data, sampleRate: Int, channels: Int) -> Data {
        CloudSpeechCodec.wavData(fromPCM16: pcm, sampleRate: sampleRate, channels: channels)
    }

    /// A log-safe description: never the URL (it carries the key).
    static func describe(_ error: Error) -> String {
        if let cloud = error as? CloudSpeechError { return cloud.errorDescription ?? "cloud voice error" }
        if let url = error as? URLError { return "URLError \(url.code.rawValue)" }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }
}
