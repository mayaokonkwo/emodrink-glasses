//
// BuildRunPDF.swift
//
// The run report: procedure + version, operator, times, one line per step,
// then every flag with its photos and reply. And the raw bundle: the run
// folder zipped by NSFileCoordinator's .forUploading (no zip library).
//

import UIKit

enum BuildRunPDF {
    static func make(run: BuildRun, store: BuildRunStore) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 40
        let body = UIFont.systemFont(ofSize: 11)
        let bold = UIFont.boldSystemFont(ofSize: 11)
        let title = UIFont.boldSystemFont(ofSize: 18)
        let statuses = BuildRunSummary.stepStatuses(run)
        let flags = BuildRunSummary.flags(in: run)
        let framesForCheck: [UUID: [String]] = Dictionary(uniqueKeysWithValues: run.events.compactMap { e in
            guard e.kind == .check, let id = e.id, let f = e.frames, !f.isEmpty else { return nil }
            return (id, f)
        })
        let checkForAlert: [UUID: UUID] = Dictionary(uniqueKeysWithValues: run.events.compactMap { e in
            guard e.kind == .alert, let id = e.id, let c = e.checkID else { return nil }
            return (id, c)
        })

        return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            var y: CGFloat = 0
            func newPage() { ctx.beginPage(); y = margin }
            func line(_ text: String, _ font: UIFont, color: UIColor = .black) {
                let rect = CGRect(x: margin, y: y, width: page.width - 2 * margin, height: .greatestFiniteMagnitude)
                let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                let h = ceil(s.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], context: nil).height)
                if y + h > page.height - margin { newPage() }
                s.draw(with: CGRect(x: margin, y: y, width: rect.width, height: h), options: [.usesLineFragmentOrigin], context: nil)
                y += h + 4
            }
            newPage()
            line("Build Check - \(run.procedure.title) (v\(run.procedure.version))", title)
            line("Operator: \(run.operatorName.isEmpty ? "-" : run.operatorName)", body)
            line("Started: \(run.startedAt.formatted(date: .abbreviated, time: .standard))", body)
            line("Ended: \(run.endedAt?.formatted(date: .abbreviated, time: .standard) ?? "not finished")", body)
            line(BuildRunSummary.spokenSummary(run), bold)
            y += 8
            for (i, step) in run.procedure.steps.enumerated() {
                let status = statuses[i]
                let mark: String
                let color: UIColor
                switch status {
                case .passed: mark = "PASS"; color = .systemGreen
                case .flagResolved: mark = "FLAG (resolved)"; color = .systemOrange
                case .unresolved: mark = "UNRESOLVED"; color = .systemRed
                case .unchecked: mark = "not checked"; color = .gray
                }
                line("\(i + 1). [\(mark)] \(step.critical ? "(critical) " : "")\(step.text)", body, color: color)
            }
            for flag in flags {
                newPage()
                line("Step \(flag.step + 1) - \(flag.level == .speak ? "spoken warning" : "note")", title)
                line(flag.issue.isEmpty ? "(no detail)" : flag.issue, body)
                line("Reply: \(flag.reply?.rawValue ?? "unresolved")", bold,
                     color: flag.reply == nil || flag.reply == .override ? .systemRed : .black)
                if let checkID = checkForAlert[flag.alertID], let frames = framesForCheck[checkID] {
                    for frame in frames {
                        guard let image = UIImage(contentsOfFile: store.frameURL(runID: run.id, filename: frame).path),
                              image.size.width > 0, image.size.height > 0 else { continue }
                        if page.height - y - margin < 160 { newPage() }
                        let maxW = page.width - 2 * margin, maxH = max(page.height - y - margin, 1)
                        let k = max(min(maxW / image.size.width, maxH / image.size.height, 1), 0.01)
                        let size = CGSize(width: image.size.width * k, height: image.size.height * k)
                        image.draw(in: CGRect(origin: CGPoint(x: margin, y: y), size: size))
                        y += size.height + 8
                    }
                }
            }
        }
    }

    /// The whole run folder (run.json + frames + reference) as a .zip in tmp.
    static func zip(runID: UUID, store: BuildRunStore) -> URL? {
        let folder = store.folderURL(runID: runID)
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &error) { zipURL in
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("buildrun-\(runID.uuidString).zip")
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.copyItem(at: zipURL, to: target)) != nil { result = target }
        }
        if error != nil { return nil }
        return result
    }
}
