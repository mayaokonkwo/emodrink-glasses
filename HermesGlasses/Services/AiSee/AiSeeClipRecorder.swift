//
// AiSeeClipRecorder.swift — AiSeeGlassKit
//
// Livestream samples → .mp4, passthrough. The glasses have no storage of
// their own, so a "clip" is the Wi-Fi livestream written to a file on the
// phone: the SDK already hands us H.264 video and AAC audio as CMSampleBuffers,
// so AVAssetWriter muxes them without re-encoding.
//
// Writing starts at the first keyframe (a clip that opens on a P-frame shows
// grey smear until the next IDR) and the session clock starts at that frame's
// timestamp; audio from before it is dropped.
//
// No vendor SDK import — compiles everywhere.
//

import AVFoundation
import CoreMedia
import Foundation

/// `@unchecked Sendable`: `append` runs on the SDK's sample thread, `finish`
/// on the coordinator's actor; all mutable state is touched only under `lock`.
final class AiSeeClipRecorder: @unchecked Sendable {
    let url: URL
    private let log: AiSeeLog
    private let lock = NSLock()
    // All of the below: `lock`-guarded.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMFormatDescription?
    private var finished = false
    private var videoFrames = 0
    private var reportedAppendFailure = false

    /// - Parameter audioFormat: the stream's audio format, if the SDK reported
    ///   one at start. The input has to exist before writing starts, so it can't
    ///   wait for the first audio sample; one seen before the first keyframe is
    ///   used if this is nil.
    init(url: URL, audioFormat: CMFormatDescription?, log: @escaping AiSeeLog) {
        self.url = url
        self.audioFormat = audioFormat
        self.log = log
    }

    /// Where a new clip goes before the host moves it somewhere permanent.
    static func makeTemporaryURL(now: Date = Date()) -> URL {
        let stamp = Int(now.timeIntervalSince1970 * 1000)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("aisee-clip-\(stamp).mp4")
    }

    // MARK: SDK thread

    func append(_ sample: CMSampleBuffer) {
        lock.withLock {
            guard !finished, let format = sample.formatDescription else { return }
            switch format.mediaType {
            case .video: appendVideo(sample, format: format)
            case .audio: appendAudio(sample, format: format)
            default: break
            }
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer, format: CMFormatDescription) {
        if writer == nil {
            guard Self.isKeyframe(sample) else { return }
            guard startWriter(video: format, at: sample.presentationTimeStamp) else {
                finished = true
                return
            }
        }
        guard let writer, writer.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData else { return }
        if input.append(sample) {
            videoFrames += 1
        } else {
            reportAppendFailure(writer)
        }
    }

    private func appendAudio(_ sample: CMSampleBuffer, format: CMFormatDescription) {
        guard let writer else {
            if audioFormat == nil { audioFormat = format }
            return
        }
        guard writer.status == .writing, let input = audioInput,
              input.isReadyForMoreMediaData else { return }
        if !input.append(sample) { reportAppendFailure(writer) }
    }

    private func reportAppendFailure(_ writer: AVAssetWriter) {
        guard !reportedAppendFailure else { return }
        reportedAppendFailure = true
        log("clip: append failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
    }

    private func startWriter(video: CMFormatDescription, at start: CMTime) -> Bool {
        guard start.isValid else {
            log("clip: first keyframe has no timestamp — cannot record")
            return false
        }
        do {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: video)
            video.expectsMediaDataInRealTime = true
            guard writer.canAdd(video) else {
                log("clip: writer rejected the video format")
                return false
            }
            writer.add(video)
            var audio: AVAssetWriterInput?
            if let audioFormat {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audio = input
                } else {
                    // A silent clip beats no clip.
                    log("clip: writer rejected the audio format — recording video only")
                }
            } else {
                log("clip: no audio format seen — recording video only")
            }
            guard writer.startWriting() else {
                log("clip: startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
                return false
            }
            writer.startSession(atSourceTime: start)
            self.writer = writer
            self.videoInput = video
            self.audioInput = audio
            log("clip: writing \(url.lastPathComponent), audio=\(audio != nil)")
            return true
        } catch {
            log("clip: cannot create writer: \(error)")
            return false
        }
    }

    // MARK: Finish

    /// Closes the file. Returns its URL, or nil when nothing usable was written
    /// (no keyframe arrived, or the writer failed) — the partial file is deleted.
    /// Idempotent: a second call returns nil.
    func finish() async -> URL? {
        let pending: (AVAssetWriter, [AVAssetWriterInput], Int)? = lock.withLock {
            guard !finished || writer != nil else { return nil }
            finished = true
            guard let writer else { return nil }
            let inputs = [videoInput, audioInput].compactMap { $0 }
            self.writer = nil
            return (writer, inputs, videoFrames)
        }
        guard let (writer, inputs, frames) = pending else {
            log("clip: finished with nothing written")
            return nil
        }
        guard writer.status == .writing, frames > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            log("clip: discarded (status \(writer.status.rawValue), \(frames) frames)")
            return nil
        }
        inputs.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else {
            log("clip: finishWriting failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        log("clip: saved \(url.lastPathComponent), \(frames) frames")
        return url
    }

    // MARK: Keyframes

    /// The sync attachment when the SDK sets one, otherwise an IDR NAL (type 5)
    /// in the AVCC payload.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        guard let format = sample.formatDescription,
              let bytes = try? sample.dataBuffer?.dataBytes() else { return false }
        var headerLength: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
        return containsIDR(avcc: bytes, lengthSize: Int(headerLength))
    }

    /// Walks length-prefixed NAL units. Pure, so it is tested without a stream.
    static func containsIDR(avcc bytes: Data, lengthSize: Int) -> Bool {
        guard (1...4).contains(lengthSize) else { return false }
        let data = [UInt8](bytes)
        var i = 0
        while i + lengthSize < data.count {
            var length = 0
            for k in 0..<lengthSize { length = (length << 8) | Int(data[i + k]) }
            let header = i + lengthSize
            if data[header] & 0x1F == 5 { return true }
            guard length > 0 else { return false }
            i = header + length
        }
        return false
    }
}
