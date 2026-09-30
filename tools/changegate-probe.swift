//
// changegate-probe.swift - tune ChangeGate's thresholds on real footage.
//
// Replays a saved run's frames (macOS, Vision feature prints like the app)
// and prints, per frame, the distance from the previous frame and from the
// last "checked" frame, and what ChangeGate would decide. Copy a run folder
// off the phone (Xcode → Devices → download the app container, then
// AppData/Library/Application Support/buildruns/<id>/).
//
//   xcrun swiftc HermesGlasses/Services/BuildCheck/ChangeGate.swift \
//     tools/changegate-probe.swift -o /tmp/changegate-probe
//   /tmp/changegate-probe <run-folder> [changeThreshold] [settleThreshold] [intervalSeconds]
//
import AppKit
import Foundation
import Vision

func featurePrint(_ url: URL) -> VNFeaturePrintObservation? {
    guard let image = NSImage(contentsOf: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let request = VNGenerateImageFeaturePrintRequest()
    request.imageCropAndScaleOption = .scaleFill
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    return request.results?.first
}

func distance(_ a: VNFeaturePrintObservation?, _ b: VNFeaturePrintObservation?) -> Float? {
    guard let a, let b else { return nil }
    var d: Float = 0
    return (try? a.computeDistance(&d, to: b)) != nil ? d : nil
}

@main
enum ChangeGateProbe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: changegate-probe <run-folder> [change=0.35] [settle=0.12] [interval=5]")
            exit(2)
        }
        let folder = URL(fileURLWithPath: args[1]).appendingPathComponent("frames")
        let change = args.count > 2 ? Float(args[2]) ?? 0.35 : 0.35
        let settle = args.count > 3 ? Float(args[3]) ?? 0.12 : 0.12
        let interval = args.count > 4 ? Double(args[4]) ?? 5 : 5

        let frames = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var gate = ChangeGate(config: .init(changeThreshold: change, settleThreshold: settle, minInterval: 15, budgetPerHour: 10_000))
        var prev: VNFeaturePrintObservation?
        var checked: VNFeaturePrintObservation?
        var sends = 0
        let t0 = Date(timeIntervalSince1970: 0)
        print("frame\tdPrev\tdChecked\tdecision")
        for (i, url) in frames.enumerated() {
            let fp = featurePrint(url)
            let dPrev = distance(fp, prev)
            let dChecked = checked == nil ? nil : distance(fp, checked)
            let now = t0.addingTimeInterval(Double(i) * interval)
            let decision = gate.evaluate(distanceFromChecked: dChecked, distanceFromPrevious: dPrev, now: now)
            if decision == .send { gate.recordSent(at: now); checked = fp; sends += 1 }
            prev = fp
            let f = { (d: Float?) in d.map { String(format: "%.3f", $0) } ?? "-" }
            print("\(url.lastPathComponent)\t\(f(dPrev))\t\(f(dChecked))\t\(decision)")
        }
        let hours = max(Double(frames.count) * interval / 3600, 1.0 / 3600)
        print("\n\(frames.count) frames, \(sends) quick checks (\(String(format: "%.0f", Double(sends) / hours))/hour) at change=\(change) settle=\(settle)")
    }
}
