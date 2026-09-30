//
// Standalone tests for ProcedureStore + BuildRunStore (temp directories).
//   xcrun swiftc \
//     HermesGlasses/Services/BuildCheck/BuildCheckJSON.swift \
//     HermesGlasses/Services/BuildCheck/Procedure.swift \
//     HermesGlasses/Services/BuildCheck/BuildCheckPrompt.swift \
//     HermesGlasses/Services/BuildCheck/AlertPolicy.swift \
//     HermesGlasses/Services/BuildCheck/ChangeGate.swift \
//     HermesGlasses/Services/BuildCheck/BuildRun.swift \
//     HermesGlasses/Services/BuildCheck/ProcedureStore.swift \
//     HermesGlasses/Services/BuildCheck/BuildRunStore.swift \
//     tests/buildcheck-stores/main.swift -o /tmp/bc-stores && /tmp/bc-stores
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("bc-stores-\(UUID().uuidString)")
defer { try? fm.removeItem(at: root) }
let t0 = Date(timeIntervalSince1970: 1_000_000)

// ProcedureStore
let ps = ProcedureStore(directory: root.appendingPathComponent("procedures"))
expect(ps.all().isEmpty, "empty store")
let photo = try! ps.addPhoto(Data([0xFF, 0xD8, 0x01]))
expect(fm.fileExists(atPath: ps.photoURL(photo).path), "photo written")
let src = try! ps.addSource(Data("1. a\n2. b".utf8), fileExtension: "txt")
expect(src.hasSuffix(".txt") && fm.fileExists(atPath: ps.sourceURL(src).path), "source written")
var p1 = Procedure(title: "Older", steps: [ProcedureStep(text: "a", referencePhotoFilenames: [photo])],
                   sourceFilename: src, now: t0)
let p2 = Procedure(title: "Newer", steps: [ProcedureStep(text: "b")], now: t0 + 10)
ps.save(p1); ps.save(p2)
expect(ps.all().map(\.title) == ["Newer", "Older"], "newest first")
p1.edit(now: t0 + 20) { $0.title = "Edited" }
ps.save(p1)
expect(ps.all().count == 2 && ps.all().first?.title == "Edited", "save upserts")
let reopened = ProcedureStore(directory: root.appendingPathComponent("procedures"))
expect(reopened.all().count == 2, "persists across instances")
ps.delete(id: p1.id)
expect(ps.all().map(\.title) == ["Newer"], "delete removes the entry")
expect(!fm.fileExists(atPath: ps.photoURL(photo).path), "delete removes its photos")
expect(!fm.fileExists(atPath: ps.sourceURL(src).path), "delete removes its source")

// BuildRunStore
let refStore = ProcedureStore(directory: root.appendingPathComponent("refs"))
let ref = try! refStore.addPhoto(Data([0xFF, 0xD8, 0x02]))
let proc = Procedure(title: "P", steps: [ProcedureStep(text: "a", referencePhotoFilenames: [ref])], now: t0)
let rs = BuildRunStore(directory: root.appendingPathComponent("buildruns"))
var run = BuildRun(id: UUID(), procedure: proc, operatorName: "Sam", startedAt: t0, endedAt: nil,
                   settings: BuildRunSettings(intervalSeconds: 5, gate: .init(), checksEnabled: true),
                   events: [])
try! rs.begin(run, referencePhoto: refStore.photoURL)
expect(fm.fileExists(atPath: rs.referenceURL(runID: run.id, filename: ref).path), "reference photo copied into run")
try? fm.removeItem(at: refStore.photoURL(ref))
expect(fm.fileExists(atPath: rs.referenceURL(runID: run.id, filename: ref).path), "run copy survives procedure photo deletion")
let f = try! rs.addFrame(Data(repeating: 7, count: 100), runID: run.id, at: t0 + 1)
expect(fm.fileExists(atPath: rs.frameURL(runID: run.id, filename: f).path), "frame written")
run.events.append(.frame(t: t0 + 1, step: 0, filename: f, sentToAI: false))
try! rs.write(run)
expect(rs.all().first?.events.count == 1, "write + all round trip")
expect(rs.diskSize(runID: run.id) >= 100, "disk size counts frames")
var second = run; second.id = UUID(); second.startedAt = t0 + 100
try! rs.begin(second, referencePhoto: refStore.photoURL)
expect(rs.all().map(\.id) == [second.id, run.id], "runs newest first")
try! "not json".write(to: rs.folderURL(runID: UUID()).appendingPathComponent("run.json"), atomically: true, encoding: .utf8)
expect(rs.all().count == 2, "a corrupt run folder is skipped, not fatal")
rs.delete(id: run.id)
expect(!fm.fileExists(atPath: rs.folderURL(runID: run.id).path), "delete removes the run folder")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
