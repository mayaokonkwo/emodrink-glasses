//
// FrameTools.swift
//
// The image helpers drink mode uses, moved out of Build Check: a Vision
// feature print per frame (fed to VendingMachineGate's change gate, all on
// the phone, no frame leaves it for this) and a downscaled JPEG for the
// one vision call that asks "is there a vending machine".
//

import UIKit
import Vision

enum FramePrint {
    static func observation(for image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first
    }

    static func distance(_ a: VNFeaturePrintObservation?, _ b: VNFeaturePrintObservation?) -> Float? {
        guard let a, let b else { return nil }
        var d: Float = 0
        do { try a.computeDistance(&d, to: b) } catch { return nil }
        return d
    }
}

enum FrameTools {
    static func downscaledJPEG(_ image: UIImage, maxSide: CGFloat = 1024, quality: CGFloat = 0.7) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: quality)
    }

    /// Preflight for drink mode: the same two checks `askOneShot` makes
    /// before every call (vision support, key present), asked once up front
    /// so drink mode that cannot check says so at the start.
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
}
