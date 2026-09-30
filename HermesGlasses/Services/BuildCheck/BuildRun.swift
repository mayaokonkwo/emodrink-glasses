//
// BuildRun.swift
//
// One Build Check run as stored: the procedure frozen at start, the
// settings used, and an append-only event log. Events are a flat struct
// with a `kind` tag rather than an enum with payloads so that an event
// kind a later version adds is DROPPED on decode instead of failing the
// whole run - a log you can't open is worse than one missing a line.
// Replies are their own events (append-only); a flag's reply is the latest
// `reply` event pointing at it, and no reply means unresolved.
// Foundation only; tested in tests/buildcheck-run.
//

import Foundation

struct BuildRunSettings: Codable, Equatable {
    var intervalSeconds: Int
    var gate: ChangeGate.Config
    var checksEnabled: Bool
}

enum AlertReply: String, Codable { case confirmed, ignore, fixed, override }

enum StepChangeVia: String, Codable { case voice, button, override }

struct BuildRunEvent: Codable, Equatable {
    enum Kind: String, Codable { case frame, speech, stepChange, check, alert, reply }

    var kind: Kind
    var t: Date
    var step: Int
    var filename: String? = nil
    var sentToAI: Bool? = nil
    var text: String? = nil
    var toStep: Int? = nil
    var via: StepChangeVia? = nil
    var id: UUID? = nil
    var checkKind: CheckKind? = nil
    var frames: [String]? = nil
    var result: CheckResult? = nil
    var error: String? = nil
    var checkID: UUID? = nil
    var level: AlertLevel? = nil
    var askedToConfirm: Bool? = nil
    var alertID: UUID? = nil
    var reply: AlertReply? = nil

    static func frame(t: Date, step: Int, filename: String, sentToAI: Bool) -> Self {
        Self(kind: .frame, t: t, step: step, filename: filename, sentToAI: sentToAI)
    }
    static func speech(t: Date, step: Int, text: String) -> Self {
        Self(kind: .speech, t: t, step: step, text: text)
    }
    static func stepChange(t: Date, from: Int, to: Int, via: StepChangeVia) -> Self {
        Self(kind: .stepChange, t: t, step: from, toStep: to, via: via)
    }
    static func check(id: UUID, t: Date, step: Int, kind: CheckKind, frames: [String],
                      result: CheckResult?, error: String?) -> Self {
        Self(kind: .check, t: t, step: step, id: id, checkKind: kind, frames: frames,
             result: result, error: error)
    }
    static func alert(id: UUID, t: Date, step: Int, checkID: UUID, level: AlertLevel,
                      askedToConfirm: Bool) -> Self {
        Self(kind: .alert, t: t, step: step, id: id, checkID: checkID, level: level,
             askedToConfirm: askedToConfirm)
    }
    static func reply(t: Date, step: Int, alertID: UUID, reply: AlertReply) -> Self {
        Self(kind: .reply, t: t, step: step, alertID: alertID, reply: reply)
    }
}

struct BuildRun: Codable, Equatable, Identifiable {
    var id: UUID
    var procedure: Procedure
    var operatorName: String
    var startedAt: Date
    var endedAt: Date?
    var settings: BuildRunSettings
    var events: [BuildRunEvent]

    init(id: UUID, procedure: Procedure, operatorName: String, startedAt: Date,
         endedAt: Date?, settings: BuildRunSettings, events: [BuildRunEvent]) {
        self.id = id
        self.procedure = procedure
        self.operatorName = operatorName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.settings = settings
        self.events = events
    }

    private struct LossyEvent: Decodable {
        let event: BuildRunEvent?
        init(from decoder: Decoder) throws { event = try? BuildRunEvent(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        procedure = try c.decode(Procedure.self, forKey: .procedure)
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName) ?? ""
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        settings = try c.decodeIfPresent(BuildRunSettings.self, forKey: .settings)
            ?? BuildRunSettings(intervalSeconds: 5, gate: ChangeGate.Config(), checksEnabled: true)
        events = (try c.decodeIfPresent([LossyEvent].self, forKey: .events) ?? []).compactMap(\.event)
    }
}

/// At most one write per `interval`, except a forced one (alert, step change).
struct SaveThrottle {
    static let interval: TimeInterval = 10
    private var last: Date?

    mutating func shouldSave(now: Date, force: Bool) -> Bool {
        if !force, let last, now.timeIntervalSince(last) < Self.interval { return false }
        last = now
        return true
    }
}

enum StepStatus: String { case passed, flagResolved, unresolved, unchecked }

enum BuildRunSummary {
    struct Flag: Equatable {
        let alertID: UUID
        let step: Int
        let level: AlertLevel
        let issue: String
        /// Latest reply; nil = unresolved.
        let reply: AlertReply?
        /// Still needs attention: no reply, an override, or "confirmed"
        /// (the wearer says something IS wrong) with no later passing full
        /// check on the same step.
        let open: Bool
    }

    /// Alerts that reached the wearer (speak/chime), with their check's issue.
    static func flags(in run: BuildRun) -> [Flag] {
        var issues: [UUID: String] = [:]
        var replies: [UUID: (reply: AlertReply, index: Int)] = [:]
        for (i, e) in run.events.enumerated() {
            if e.kind == .check, let id = e.id { issues[id] = e.result?.issue ?? e.error ?? "" }
            if e.kind == .reply, let a = e.alertID, let r = e.reply { replies[a] = (r, i) }
        }
        func passedAfter(_ index: Int, step: Int) -> Bool {
            run.events[(index + 1)...].contains {
                $0.kind == .check && $0.step == step && $0.checkKind == .full && $0.result?.verdict == .match
            }
        }
        return run.events.compactMap { e in
            guard e.kind == .alert, let id = e.id, let level = e.level, level != .log else { return nil }
            let issue = e.checkID.flatMap { issues[$0] } ?? ""
            let latest = replies[id]
            let open: Bool
            switch latest?.reply {
            case nil, .override?: open = true
            case .confirmed?: open = !passedAfter(latest!.index, step: e.step)
            case .ignore?, .fixed?: open = false
            }
            return Flag(alertID: id, step: e.step, level: level,
                        issue: e.askedToConfirm == true && issue.isEmpty ? "could not verify" : issue,
                        reply: latest?.reply, open: open)
        }
    }

    private static func isOpen(_ flag: Flag) -> Bool { flag.open }

    static func stepStatuses(_ run: BuildRun) -> [StepStatus] {
        let flags = flags(in: run)
        return run.procedure.steps.indices.map { step in
            let stepFlags = flags.filter { $0.step == step }
            if stepFlags.contains(where: isOpen) { return .unresolved }
            if !stepFlags.isEmpty { return .flagResolved }
            let passed = run.events.contains {
                $0.kind == .check && $0.step == step && $0.checkKind == .full && $0.result?.verdict == .match
            }
            return passed ? .passed : .unchecked
        }
    }

    static func spokenSummary(_ run: BuildRun) -> String {
        let flags = flags(in: run)
        guard !flags.isEmpty else { return "Run saved. No flags." }
        let open = flags.filter(isOpen).count
        return "Run saved. \(flags.count) flag\(flags.count == 1 ? "" : "s"), \(open) unresolved."
    }
}
