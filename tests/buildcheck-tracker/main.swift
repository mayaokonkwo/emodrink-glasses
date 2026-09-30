//
// Standalone tests for BuildRunTracker. Build + run:
//   xcrun swiftc HermesGlasses/Services/BuildCheck/BuildRunTracker.swift \
//     tests/buildcheck-tracker/main.swift -o /tmp/bc-tracker && /tmp/bc-tracker
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

var t = BuildRunTracker(stepCount: 4, criticalSteps: [1, 3])
expect(t.current == 0 && t.phase == .working && !t.isCurrentCritical, "starts on step 0, working")
expect(t.stepDone() == .advanced(to: 1), "non-critical advances at once")
expect(t.isCurrentCritical, "step 1 is critical")
expect(t.stepDone() == .awaitingCheck && t.phase == .checking, "critical waits for its check")
expect(t.stepDone() == .refused, "second 'step done' while checking is refused")
expect(t.current == 1, "still on step 1")
expect(t.criticalCheckFinished(step: 0, blocking: false) == .refused, "stale verdict for another step ignored")
expect(t.criticalCheckFinished(step: 1, blocking: true) == .refused && t.phase == .blocked, "confident mismatch blocks")
expect(t.stepDone() == .refused, "blocked refuses step done")
expect(t.fixed() && t.phase == .checking, "fixed → re-check")
expect(t.criticalCheckFinished(step: 1, blocking: false) == .advanced(to: 2), "re-check passes → advance")
expect(!t.fixed(), "fixed does nothing when not blocked")
expect(t.override() == .refused, "override does nothing when not blocked")
expect(t.stepDone() == .advanced(to: 3), "step 2 non-critical")
expect(t.stepDone() == .awaitingCheck, "last step critical")
_ = t.criticalCheckFinished(step: 3, blocking: true)
expect(t.override() == .finished && t.phase == .finished, "override on last step finishes")
expect(t.stepDone() == .refused, "finished refuses everything")

var z = BuildRunTracker(stepCount: 0, criticalSteps: [])
expect(z.phase == .finished, "empty procedure is finished")
var one = BuildRunTracker(stepCount: 1, criticalSteps: [])
expect(one.stepDone() == .finished, "single non-critical step finishes")
var f = BuildRunTracker(stepCount: 3, criticalSteps: [])
f.finish()
expect(f.phase == .finished && f.stepDone() == .refused, "finish() ends early")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
