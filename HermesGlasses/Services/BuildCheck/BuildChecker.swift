//
// BuildChecker.swift
//
// THE seam for every Build Check AI call. Today it is the user's direct
// provider via askOneShot (images never enter conversation memory). A
// future "local only" procedure flag routes here, and nowhere else.
//

import Foundation

final class BuildChecker: @unchecked Sendable {
    static let checkTimeout: TimeInterval = 20
    static let splitTimeout: TimeInterval = 120
    static let splitMaxTokens = 8192

    private let client: DirectClient

    init(client: DirectClient = DirectClient()) { self.client = client }

    func check(kind: CheckKind, step: ProcedureStep, number: Int, total: Int,
               imageJPEG: Data, tileLabels: [String]) async throws -> CheckResult {
        let prompt = kind == .quick
            ? BuildCheckPrompt.quickPrompt(step: step, number: number, total: total)
            : BuildCheckPrompt.fullPrompt(step: step, number: number, total: total, tileLabels: tileLabels)
        let reply = try await client.askOneShot(
            systemPrompt: BuildCheckPrompt.systemPrompt, userText: prompt,
            photoJPEG: imageJPEG, timeout: Self.checkTimeout)
        return BuildCheckPrompt.parseVerdict(reply)
    }

    func splitProcedure(_ text: String) async throws -> ProcedureParser.Split {
        let reply = try await client.askOneShotText(
            systemPrompt: ProcedureParser.splitSystemPrompt,
            userText: ProcedureParser.splitUserPrompt(document: text),
            maxTokens: Self.splitMaxTokens, timeout: Self.splitTimeout)
        return try ProcedureParser.split(fromAIReply: reply)
    }

    /// Preflight for a run: the same two checks `askOneShot` makes before
    /// every call (vision support, key present), asked once up front so a
    /// run that can't check says so at the start instead of failing each time.
    static var canRunVisionChecks: (ok: Bool, reason: String?) {
        let provider = DirectClient.provider
        guard provider.supportsVision else {
            return (false, "\(provider.displayName) can't read images")
        }
        if provider.requiresKey, (DirectClient.loadKey(for: provider.id) ?? "").isEmpty {
            return (false, "no \(provider.displayName) API key")
        }
        return (true, nil)
    }

    /// Auth / config failures end checking for the run (same rule as badge assist).
    static func isFatal(_ error: Error) -> Bool { BadgeAssist.isFatal(error) }
}
