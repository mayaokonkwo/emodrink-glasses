//
// BuildCheckVision.swift
//
// The image side of Build Check. Feature prints feed ChangeGate (all on the
// phone - no frame leaves it for this). The composite puts reference and
// current tiles in ONE labelled JPEG, because askOneShot carries a single
// image and every provider must be able to run an end-of-step check.
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

enum BuildCheckComposer {
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

    /// Up to 3 columns of square tiles, each aspect-fit with its label on a
    /// dark bar across the top.
    static func composite(_ tiles: [(label: String, image: UIImage)], tileSide: CGFloat = 512) -> Data? {
        guard !tiles.isEmpty else { return nil }
        let columns = min(3, tiles.count)
        let rows = Int(ceil(Double(tiles.count) / Double(columns)))
        let size = CGSize(width: CGFloat(columns) * tileSide, height: CGFloat(rows) * tileSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 26),
                .foregroundColor: UIColor.white,
            ]
            for (i, tile) in tiles.enumerated() {
                let cell = CGRect(x: CGFloat(i % columns) * tileSide, y: CGFloat(i / columns) * tileSide,
                                  width: tileSide, height: tileSide)
                let s = tile.image.size
                let k = min(cell.width / max(s.width, 1), cell.height / max(s.height, 1))
                let fitted = CGRect(x: cell.midX - s.width * k / 2, y: cell.midY - s.height * k / 2,
                                    width: s.width * k, height: s.height * k)
                tile.image.draw(in: fitted)
                let bar = CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: 40)
                UIColor.black.withAlphaComponent(0.65).setFill()
                ctx.fill(bar)
                (tile.label as NSString).draw(at: CGPoint(x: bar.minX + 10, y: bar.minY + 5), withAttributes: attrs)
            }
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}
