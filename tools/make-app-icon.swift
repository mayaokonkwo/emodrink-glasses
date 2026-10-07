// Renders the EmoDrink Glasses app icon: a white morning sun rising over a
// deep-blue horizon, with three small bubbles drifting up past its right
// shoulder, on a deep-to-sky blue gradient. No alpha channel - iOS app
// icons must be fully opaque.
//
//   swift tools/make-app-icon.swift <output.png>

import AppKit
import CoreGraphics
import Foundation

let size = 1024
let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "icon-1024.png"

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("context") }

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: 1)
}

let s = CGFloat(size)
let deep = rgb(0x0D, 0x2F, 0x75)
let white = rgb(0xFF, 0xFF, 0xFF)

// Sky: deep blue #0D2F75 at the bottom-left, through the accent #1446A0,
// up to sky #3E7BD6 at the top-right. CoreGraphics' origin is bottom-left.
let gradient = CGGradient(
    colorsSpace: space,
    colors: [deep, rgb(0x14, 0x46, 0xA0), rgb(0x3E, 0x7B, 0xD6)] as CFArray,
    locations: [0.0, 0.5, 1.0])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: s, y: s),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Morning sun: about 44 percent of the width, centred horizontally, its
// centre at about 58 percent of the height measured from the top.
let sunD = s * 0.44
let sunCenter = CGPoint(x: s / 2, y: s * (1 - 0.58))
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: sunCenter.x - sunD / 2, y: sunCenter.y - sunD / 2,
                           width: sunD, height: sunD))

// Horizon: a filled deep-blue hill over the bottom 38 percent, its top edge
// a gentle convex arc (higher in the middle than at the sides), hiding the
// lower part of the sun.
let horizonEdge = s * 0.38
let rise = s * 0.05
let horizon = CGMutablePath()
horizon.move(to: CGPoint(x: 0, y: 0))
horizon.addLine(to: CGPoint(x: 0, y: horizonEdge - rise))
horizon.addQuadCurve(to: CGPoint(x: s, y: horizonEdge - rise),
                     control: CGPoint(x: s / 2, y: horizonEdge + rise))
horizon.addLine(to: CGPoint(x: s, y: 0))
horizon.closeSubpath()
ctx.setFillColor(deep)
ctx.addPath(horizon)
ctx.fillPath()

// Bubbles: three small white circles (3, 4 and 5 percent of the width)
// rising diagonally above the sun's right shoulder, smallest highest.
ctx.setFillColor(white)
let bubbles: [(x: CGFloat, y: CGFloat, d: CGFloat)] = [
    (0.72, 0.33, 0.05),
    (0.78, 0.25, 0.04),
    (0.83, 0.18, 0.03),
]
for b in bubbles {
    let d = s * b.d
    let cx = s * b.x
    let cy = s * (1 - b.y)
    ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
}

guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(png.count / 1024) KB)")
