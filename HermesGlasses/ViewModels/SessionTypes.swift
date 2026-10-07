//
// SessionTypes.swift
//
// Value types the session view model publishes, kept out of its file so
// that file stays about the session.
//

import Foundation

/// Represents the current state of the Hermes conversation
enum HermesConnectionState: Equatable {
    case disconnected
    case connecting
    case listening
    case recording
    case processing
    case speaking
    case error(String)
}

/// Where voice is captured (and, on Bluetooth, where TTS plays - HFP is
/// bidirectional)
enum MicSource: String, CaseIterable {
    case phone
    case glasses
    case headset

    var label: String {
        switch self {
        case .phone: return "iPhone Mic"
        case .glasses: return "Glasses Mic (call screen)"
        case .headset: return "Headset Mic (AirPods etc.)"
        }
    }

    /// Compact form for the settings hub row, where the caveat in `label`
    /// doesn't fit.
    var shortLabel: String {
        switch self {
        case .phone: return "iPhone"
        case .glasses: return "Glasses"
        case .headset: return "Headset"
        }
    }

    var captureRoute: CaptureRoute {
        switch self {
        case .phone: return .phoneMic
        case .glasses: return .glassesMic
        case .headset: return .headsetMic
        }
    }
}

struct ConversationTurn: Identifiable {
    let id = UUID()
    let userText: String
    let agentText: String
    let timestamp: Date
    var photo: Data? = nil
    /// Which camera took `photo` ("Ray-Ban camera", "iPhone camera").
    var photoSource: String? = nil
}

struct TestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
