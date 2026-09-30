//
// AiSeeSequencing.swift — AiSeeGlassKit
//
// The still-photo rules from FINDINGS.md (SDK 1.6.4) as a pure function, so
// they are unit-tested without hardware. AiSeeDeviceCoordinator executes the
// plan; nothing else decides when the mic or camera opens.
//
//   F1  mic open across snapshot() wedges the device → close mic 400 ms before,
//       settle 300 ms, reopen after.
//   F2  stills right after a livestream time out → 1 s settle after stop.
//   —   a still during a livestream is served from the latest decoded frame.
//   —   the glasses serve ONE livestream; its users (the camera consumer and a
//       clip recording) share it, and it stops only when the last one leaves.
//
// Foundation only.
//

import Foundation

enum AiSeeSequencing {
    struct State: Equatable {
        var micOpen: Bool
        var streaming: Bool
        var lastStreamStop: Date?
    }

    enum Step: Equatable {
        case closeMic
        case wait(ms: Int)
        case shoot
        case reopenMic
        case serveLatestFrame
    }

    static let micCloseLeadMs = 400
    static let micSettleMs = 300
    static let postStreamSettleMs = 1000

    static func stillPhotoPlan(state: State, now: Date) -> [Step] {
        if state.streaming { return [.serveLatestFrame] }

        var plan: [Step] = []
        if let stop = state.lastStreamStop {
            let elapsedMs = Int(round(now.timeIntervalSince(stop) * 1000))
            // Clamped: a clock change can put `lastStreamStop` in the future, and
            // waiting more than the settle itself is never right.
            let remaining = min(postStreamSettleMs, postStreamSettleMs - elapsedMs)
            if remaining > 0 { plan.append(.wait(ms: remaining)) }
        }
        if state.micOpen {
            plan += [.closeMic, .wait(ms: micCloseLeadMs), .wait(ms: micSettleMs), .shoot, .reopenMic]
        } else {
            plan.append(.shoot)
        }
        return plan
    }

    /// Longest clip before the coordinator stops it by itself. A forgotten
    /// recording otherwise runs until the battery or the phone's disk gives out.
    static let maxClipSeconds = 300

    /// Who is holding the one livestream.
    struct StreamUsers: Equatable {
        enum User: Hashable { case vision, clip }
        private(set) var users: Set<User> = []

        var isEmpty: Bool { users.isEmpty }
        func contains(_ user: User) -> Bool { users.contains(user) }

        /// Returns true when the stream was idle, i.e. the caller must open it.
        mutating func add(_ user: User) -> Bool {
            let wasIdle = users.isEmpty
            users.insert(user)
            return wasIdle
        }

        /// Returns true when `user` was the last one, i.e. the caller must stop
        /// the stream. Removing a user who was not holding it changes nothing.
        mutating func remove(_ user: User) -> Bool {
            guard users.remove(user) != nil else { return false }
            return users.isEmpty
        }

        mutating func removeAll() { users.removeAll() }
    }
}
