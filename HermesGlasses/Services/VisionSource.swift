//
// VisionSource.swift
//
// The one seam between "what Hermes sees" and which hardware it comes
// from. Five features use a camera - visual queries, "remember this
// person", conversation capture, the Lens screen, and the Photo test - and
// all five talk to this protocol, so phone mode reaches every one of them
// without a single `if phoneMode` branch at a call site.
//
// Frames arrive already reduced to what the app actually consumes: a
// UIImage to draw and a CVPixelBuffer to run vision on. That conversion used
// to live in LensViewModel; doing it here means the DAT SDK's VideoFrame
// type stops at this boundary.
//

import CoreMedia
import CoreVideo
import UIKit

/// One frame from whichever eye is active.
struct VisionFrame {
    /// Displayable frame. Nil if the decode failed - callers keep the last
    /// good image rather than flashing an empty view.
    let image: UIImage?
    /// Buffer for Vision/CoreML. Nil on sources that only decode to images.
    let pixelBuffer: CVPixelBuffer?
}

/// A camera Hermes can see through. Implementations own their own stream
/// lifecycle; the app only starts, stops, and asks for stills.
protocol VisionSource: AnyObject {
    /// How the photo card credits this source ("Ray-Ban camera").
    var sourceLabel: String { get }

    /// Whether a live stream is currently running.
    var isStreaming: Bool { get }

    /// Start a persistent stream. `onFrame` fires on a capture thread - hop
    /// to the main actor before touching UI state. Throws if the source is
    /// unavailable or already streaming.
    func startLiveStream(
        onFrame: @escaping @Sendable (VisionFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws

    /// Tear down the live stream. Safe to call when nothing is running.
    func stopLiveStream()

    /// A single JPEG. While a live stream runs, implementations serve the
    /// freshest frame rather than opening a competing capture, so a visual
    /// query never stutters the feed.
    func capturePhoto() async throws -> Data
}

// MARK: - Glasses

extension HermesCameraManager: VisionSource {
    var sourceLabel: String { "Ray-Ban camera" }

    /// Adapts the DAT SDK's `VideoFrame` callback to `VisionFrame`. The
    /// decode happens once, here, on the SDK thread that delivered it.
    func startLiveStream(
        onFrame: @escaping @Sendable (VisionFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        try await startLiveStream(
            onVideoFrame: { frame in
                onFrame(VisionFrame(
                    image: frame.makeUIImage(),
                    pixelBuffer: CMSampleBufferGetImageBuffer(frame.sampleBuffer)
                ))
            },
            onError: onError
        )
    }
}

// MARK: - Glasses through GlassesLink

enum GlassesVisionError: LocalizedError {
    case streamInUse
    case cameraUnavailable
    case noFrame

    var errorDescription: String? {
        switch self {
        case .streamInUse: return "The glasses camera is already streaming."
        case .cameraUnavailable: return "Could not open the glasses camera."
        case .noFrame: return "Timed out waiting for a glasses camera frame."
        }
    }
}

/// The Ray-Ban camera through GlassesLink, the proven path: frames are the
/// UIImages GlassesLink decodes (`frame.makeUIImage()`, as the basics
/// screen's Test 2 gets them). Drink mode's live stream is one GlassesLink
/// camera consumer; a photo is the latest frame, opening the camera for a
/// moment when nothing is streaming.
@MainActor
final class GlassesLinkVision {
    static let streamConsumer = "vision"
    /// Longest wait for the first frame (camera wake, permission redirect).
    static let firstFrameTimeout: TimeInterval = 15

    let sourceLabel = "Ray-Ban camera"
    private let link: GlassesLink
    private var streaming = false

    init(link: GlassesLink) {
        self.link = link
    }

    var isStreaming: Bool { streaming }

    func startLiveStream(
        onFrame: @escaping @Sendable (VisionFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        guard !streaming else { throw GlassesVisionError.streamInUse }
        streaming = true
        var stopped = false
        link.startCamera(
            consumer: Self.streamConsumer,
            onFrame: { image in onFrame(VisionFrame(image: image, pixelBuffer: nil)) },
            onStop: { [weak self] in
                stopped = true
                guard let self, self.streaming else { return }
                self.streaming = false
                onError("glasses camera stopped")
            }
        )
        // Wait for the stream (or its failure). A slow start is not an
        // error: frames that arrive later still reach `onFrame`, and drink
        // mode notices a camera that never delivers.
        let deadline = Date().addingTimeInterval(Self.firstFrameTimeout)
        while !stopped, streaming, !link.isCameraStreaming, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if stopped {
            throw GlassesVisionError.cameraUnavailable
        }
    }

    func stopLiveStream() {
        guard streaming else { return }
        streaming = false
        link.stopCamera(consumer: Self.streamConsumer)
    }

    /// The latest frame as JPEG. With no stream running the camera is
    /// opened for this photo and left again once a frame arrives.
    func capturePhoto() async throws -> Data {
        if link.isCameraStreaming, let frame = link.latestFrame {
            return try Self.jpeg(frame)
        }
        let consumer = "photo-\(UUID().uuidString)"
        var failed = false
        link.startCamera(consumer: consumer, onFrame: { _ in }, onStop: { failed = true })
        defer { link.stopCamera(consumer: consumer) }
        let deadline = Date().addingTimeInterval(Self.firstFrameTimeout)
        while true {
            if failed { throw GlassesVisionError.cameraUnavailable }
            if link.isCameraStreaming, let frame = link.latestFrame {
                return try Self.jpeg(frame)
            }
            if Date() >= deadline { throw GlassesVisionError.noFrame }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func jpeg(_ image: UIImage) throws -> Data {
        guard let data = image.jpegData(compressionQuality: HermesCameraManager.jpegQuality) else {
            throw GlassesVisionError.noFrame
        }
        return data
    }
}

extension GlassesLinkVision: @preconcurrency VisionSource {}
