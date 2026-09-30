# Build Check — live assembly logging with AI procedure checks

Date: 2026-10-01 · Status: approved design, awaiting spec review

## 1. Intent

**Who:** a technician assembling safety-critical hardware (the motivating
example: rocket assembly at a company like SpaceX), wearing Hermes glasses.

**Problem:** an assembly mistake (a missing bolt, a reversed bracket, a
skipped step) can stay invisible until the hardware fails in service, when
it is expensive or catastrophic.

**Outcome:** while the technician works, the glasses photograph the work
every few seconds (the interval is configurable). An AI model compares what
it sees against the written procedure and what the technician says, and
flags a likely mistake *while it can still be fixed*. Every run also leaves
a timestamped photo + speech log, so a build can be reviewed afterwards even
when nothing was flagged.

**What the user decided (brainstorm, 2026-09-30):**

| Question | Decision |
|---|---|
| What the AI checks against | A written procedure (B), with the plain log always recording underneath (C) |
| How the procedure gets in | Import a document, with optional reference photos per step; typed or pasted text too |
| When the AI checks | Tiered: on-device change detection gates quick checks, plus a full check at every step boundary |
| How a suspected mistake reaches the wearer | Graded by severity; voice replies confirmed / ignore / fixed |
| Where photos may go | The app's existing AI provider (direct mode). Local-only routing is deferred, but the design keeps room for it |

**Success criteria**

- A procedure imported from a PDF can be reviewed and run end to end with
  voice + glasses button only.
- A deliberate mistake on a critical step with a reference photo (e.g. one
  bolt omitted) is spoken to the wearer before they can advance past that step.
- A false alarm costs the wearer one word ("ignore") and is never repeated
  within 2 minutes.
- A 1-hour run leaves a complete log (frames, speech, checks, replies) and a
  PDF report, even if checks failed or the network dropped.
- AI calls per hour stay within the configured budget (default 120 quick checks).

## 2. Architecture

**Approach: the phone runs everything.** Capture, gating, checking, alerting
and storage all run in the app, through the existing vision routing
(`VisionSource`: AiSee / Meta / iPhone) and the existing one-shot provider
path (`DirectClient.askOneShot`, which keeps images out of conversation
memory). Rejected alternatives: orchestrating on the Mac bridge (needs a
second camera pipeline, contradicts the provider decision) and streaming
video to a realtime model (cost per hour, poor fit for graded, per-step
verdicts).

A new Hermes app, **Build Check**, registered in `HermesAppRegistry`
(capabilities: vision, microphone, storage, export; `requiresGlasses: false`
so phone mode works).

| Unit | File (proposed) | Responsibility | Pure + tested |
|---|---|---|---|
| `Procedure`, `ProcedureStep` | `Services/BuildCheck/Procedure.swift` | Value types: title, version, steps (`text`, `critical`, `expectedLook`, `referencePhotoFilenames`) | yes |
| `ProcedureParser` | `Services/BuildCheck/ProcedureParser.swift` | Deterministic numbered-list split; decode/validate the AI's JSON step list | yes |
| `ProcedureImporter` | `Services/BuildCheck/ProcedureImporter.swift` | File → text (PDFKit, OCR fallback) → parser or AI split | device |
| `ProcedureStore` | `Services/BuildCheck/ProcedureStore.swift` | JSON index + reference photos + source doc under Application Support/`procedures/` | codec yes |
| `BuildRunTracker` | `Services/BuildCheck/BuildRunTracker.swift` | Current step, advancing, the critical-step gate, override | yes |
| `ChangeGate` | `Services/BuildCheck/ChangeGate.swift` | Decide whether a frame goes to a quick check (from distances + timing + budget) | yes |
| `BuildChecker` | `Services/BuildCheck/BuildChecker.swift` | Build quick/full prompts + composite image; parse verdict JSON. The ONE interface every AI call goes through | parsing yes |
| `AlertPolicy` | `Services/BuildCheck/AlertPolicy.swift` | Verdict + context → speak / chime / log | yes |
| `BuildRun`, `BuildRunStore` | `Services/BuildCheck/BuildRun*.swift` | Append-only event log + frames under Application Support/`buildruns/<id>/` | codec yes |
| `BuildCheckViewModel` | `ViewModels/BuildCheckViewModel.swift` | Wires capture, gate, checker, policy, voice, store | device |
| Views | `Views/BuildCheck*.swift` | Procedure list, importer/review, live run, run review | device |
| Probe | `tools/changegate-probe.swift` | Replays a saved run to print what the gate would send | tool |

Each new `.swift` file needs the four manual `project.pbxproj` edits.

## 3. Procedures and import

**Ways in** (all three end on the same review screen):

1. **Import a file**: PDF, `.txt`, `.md` via `fileImporter`. PDF text comes from
   PDFKit on the phone. A page with no text layer is rendered and read with
   `VNRecognizeTextRequest`, also on the phone.
2. **Paste or type** text.
3. **Splitting into steps**: if the text is a clean numbered list (`1.`, `1)`,
   `Step 1:`, consecutive from 1), `ProcedureParser` splits it with no AI.
   Otherwise the AI splits it once, via `DirectClient.askOneShotText`, into
   strict JSON:
   `{"steps":[{"text":…, "critical":bool, "expected_look":…}]}`.
   Input is capped at ~60,000 characters. Anything longer fails with "split
   this document" rather than being truncated.

**Step fields**

- `text`: the instruction, verbatim from the source where possible.
- `critical`: suggested by the AI (torque, safety wire, orientation,
  connectors, fluids, "verify", "caution") or the parser (the same keywords),
  and confirmed by the user.
- `expectedLook`: one line describing what "done" looks like. Drafted by the
  AI, editable, and optional for parsed lists.
- `referencePhotoFilenames`: 0–3 photos, from the glasses, the iPhone camera,
  or the photo library.

**Review is mandatory.** The user can edit, reorder, merge, split and delete
steps, toggle `critical`, and add reference photos. A procedure is marked
`ready` only after review, and only ready procedures can start a run. An
AI-split procedure is never used without a person checking it.

**Versioning.** Any edit increments `version`. A run stores a frozen copy of
the procedure, and **copies** its reference photos into the run folder
(`buildruns/<id>/reference/`), so later edits never change what a past run
was checked against. The source document is kept next to the procedure.

## 4. The run loop

**Start / stop.** Start from the Ready procedure's screen, or say "start
build check" (whole-utterance). Say "end build check" to stop. A run holds
the mic and camera the way conversation capture does, and can start from a
cold start (no bridge, no chat). The start screen takes an optional
**operator name** (remembered from the last run, `buildcheck_operator_name`),
which is recorded in the run and printed on the report. **During a run every utterance is claimed**:
a command, or narration logged against the current step. Nothing is
dispatched to the general brain.

**Capture.** Interval `buildcheck_interval_seconds` (default 5, range 2–60).
The run holds a **live stream** as a stream user and samples its latest frame
on each tick. It never fires a separate still per tick, because on AiSee a
still closes and reopens the mic for ~700 ms (FINDINGS §F1), which would
chop every voice command. Phone mode observes the shared session through
`addVisionFrameObserver`. On AiSee, the run and a video clip share the
stream (`AiSeeSequencing.StreamUsers`). Every sampled frame is downscaled
to ~1024 px on the long side and written to the log with its time and step.

**ChangeGate** (pure). Inputs per frame: `dChecked` (feature-print distance
from the last frame that was quick-checked), `dPrev` (distance from the
previous frame), seconds since the last quick check, and budget used this
hour. A frame is sent when:

- `dChecked > changeThreshold` (the scene changed), **and**
- `dPrev < settleThreshold` (it has settled; not mid-motion), **and**
- ≥ 15 s since the last quick check, **and**
- the quick-check budget (`buildcheck_quick_budget_per_hour`, default 120)
  is not used up.

Distances come from `VNGenerateImageFeaturePrintRequest`, on the phone. The
thresholds are **provisional** until measured with `tools/changegate-probe.swift`
on real glasses footage.

**Checks** (all through `BuildChecker`, all JSON):

- **Quick check.** One image (the current frame) plus the step `text` and
  `expectedLook`: "Does this still match step N?"
- **End-of-step check.** Triggered by "step done" / "next step" or the glasses
  key action. One **composite JPEG** holds the reference photo(s) next to the
  last 2–3 settled frames of the step, each tile labelled
  ("REFERENCE", "NOW −4 s", …). A single image works with every provider's
  `askOneShot`.
- Reply schema: `{"verdict":"match|mismatch|unclear","confidence":0..1,"observed":"…","issue":"…"}`.
  Parsing tolerates code fences and surrounding prose. A missing or invalid
  field makes the verdict `unclear`.
- **Critical steps block**: "Checking step N…" is spoken and the tracker
  holds the step until the verdict (timeout 20 s → `unclear`).
  **Non-critical steps advance at once**, and the verdict lands in the
  background, attributed to the step it checked.
- **Concurrency:** at most one quick check in flight. An end-of-step check
  takes priority, and a quick check is skipped while one is pending.

**Failures never stop logging.** A failed or unparseable reply is logged as
`failed` / `unclear`. Three failures in a row give a chime plus a "Checks
offline, still logging" banner. The first authentication failure disables
checks for the rest of the run (same rule as `BadgeAssist`). The live run
screen shows the count of AI calls.

**End of run.** A spoken summary, e.g. "Run saved. 2 flags, 1 unresolved."

## 5. Alerts and replies

**AlertPolicy** (pure):

| Result | Critical step | Non-critical step |
|---|---|---|
| mismatch, confidence ≥ 0.75 | speak now | chime, raise at step end |
| mismatch, 0.5–0.75 | chime, raise at step end | log |
| unclear on an end-of-step check | chime + "Couldn't verify step N, can you confirm?" | log |
| match, or confidence < 0.5 | log | log |

- A **quick-check** mismatch needs **two consecutive** quick mismatches on the
  same step before it escalates. An end-of-step result escalates on its own.
- The same step and a similar issue are not raised again within 120 s.
- Spoken wording is always seen vs expected: "Check step 3: I see three
  bolts, the procedure says four."

**Replies** (whole-utterance, heard for 20 s after a spoken warning, or when a
chimed flag is read out at "step done"):

- `confirmed`: a real issue.
- `ignore`: a false alarm.
- `fixed`: re-run the end-of-step check now.
- no reply: `unresolved`.

**Critical-step gate.** If an end-of-step check on a critical step is a
confident mismatch, the tracker **refuses to advance** until either "fixed"
triggers a re-check that passes, or the wearer says **"override"**. An
override is logged with the frames that were in view and rendered red in
review.

**Surfaces.** New `GlassesKeyAction` cases: `buildStepDone` and
`buildRepeatWarning`. On Ray-Ban Display, a `LensContent` case shows the
step number, the short step text, and any open flag (best-effort, like every
display call). AiSee is voice only.

Speech goes through the existing speak-with-recognizer-suspended pattern
(`speakCue` in `HermesSessionViewModel`), so Hermes never transcribes its own
warnings.

## 6. Run log, review, export

**Storage:** Application Support/`buildruns/<id>/run.json` plus `frames/*.jpg`.
`run.json` holds the frozen procedure, the operator name, the start and end times, the settings
used (interval, thresholds, budget), and an append-only `events` array:

- `frame {t, step, filename, sentToAI}`
- `speech {t, step, text}`
- `stepChange {t, from, to, via: voice|button|override}`
- `check {t, step, kind: quick|full, frames[], verdict, confidence, observed, issue, error?}`
- `alert {t, step, checkRef, level: speak|chime|log, reply: confirmed|ignore|fixed|override|unresolved}`

The file is saved incrementally, at most every 10 s and on every alert or
step change, so a crash loses at most the last few frames. The decoder
migrates unknown/old keys the way `Encounter` does.

**Review screen:** a timeline grouped by step, with the step status ✅ (end-of-step
check passed), ⚠️ (flag resolved), ❌ (unresolved or override), or ⏭ (never
checked). Tapping a step scrubs its frames, with each check and the AI's
`observed`/`issue` beside the frame it judged.

**Export:** a PDF report (procedure + version, operator, times, a per-step
line, each flag with its photos and reply), plus a raw zip of the frames +
`run.json`. This reuses the existing PDF export pattern.

**Disk:** ~720 frames/hour at 5 s ≈ 70–100 MB. Review shows the size, and
runs are deleted manually. Nothing is deleted automatically.

**Settings keys:** `buildcheck_enabled` (default true),
`buildcheck_interval_seconds` (5), `buildcheck_quick_budget_per_hour` (120),
`buildcheck_checks_enabled` (true; off = log-only runs, zero AI calls),
`buildcheck_operator_name` (empty).

## 7. Testing

Standalone `swiftc` suites under `tests/buildcheck/`, written before the
code. New assertions go **above** the final `print`/`exit` lines.

- `ProcedureParser`: numbered-list styles, non-consecutive numbers rejected,
  AI JSON decode (valid, fenced, missing fields, empty).
- `BuildRunTracker`: advance, block on a critical pending check, gate on a
  critical mismatch, `fixed` re-check pass/fail, `override`.
- `ChangeGate`: each clause of the rule, the budget rollover per hour, first frame.
- `AlertPolicy`: every cell of the table, the two-consecutive rule, 120 s
  suppression, unclear-on-critical.
- `BuildChecker` reply parsing: fences, prose around the JSON, confidence
  out of range, unknown verdict → unclear.
- `BuildRun` codec: round-trip and old-key migration.
- `IntentDetector` (extend `tests/intent/`): start/end build check, step done /
  next step, confirmed, ignore, fixed, override, and the fact that these are
  NOT matched as substrings of ordinary narration.
- Tool: `tools/changegate-probe.swift` for threshold measurement.

Suites that touch `AIProviderError` must list all four provider sources (see
CLAUDE.md). Device verification (camera paths per vendor, cue audio, the
critical gate with a real missing bolt) is a manual checklist in the plan.

## 8. Out of scope for v1

- Local-only / bridge routing of checks. `BuildChecker` is the single seam
  where this will go, and a per-procedure "local only" flag would force it.
- Multiple operators, or syncing and uploading runs.
- The AI detecting or advancing the current step on its own. The wearer
  always advances.
- Editing a procedure mid-run.
- Video-based (rather than frame-based) checking.
