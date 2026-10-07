# EmoDrink Glasses - notes for Claude

A standalone, MIT-licensed project. See README.md for architecture and setup.

## Current state (2026-10-08)

EmoDrink is the whole app: one screen that starts watching for a vending
machine on open, three drinks on the lens, Japanese or English speech both
ways. Voice loop: on-device STT, `DirectClient` to the provider, on-device
TTS. Vision: the Ray-Ban camera through DAT, or the iPhone camera in phone
mode.

## Key facts that are easy to get wrong

- **EmoDrink only: one screen, Meta only, no bridge, bundled key.** Every
  Hermes feature (people, Lens, Map, Build Check, AiSee, the bridge, the app
  drawer) is DELETED, not hidden: no file, project entry, model, test or
  tool remains. `BundledAIKey.seedIfNeeded()` runs FIRST in
  `HermesGlassesApp.init()` (before the session view model reads provider
  state), takes provider, model and key from Info.plist `EmoDrinkBundledAI`
  (fed by the gitignored `Config/Secrets.xcconfig`), and never overwrites a
  user key: the Keychain is written only when that provider has none.
- **STT is on-device.** `SFSpeechRecognizer`, on-device when supported. There
  is no server path.
- **Audio session uses mode `.default`, not `.voiceChat`** - voiceChat's DSP
  gates speech to the noise floor (~20 dB down). There is therefore NO echo
  cancellation: the recognizer is suspended while Hermes speaks and resumes
  0.7 s after playback ends.
- **Never detach the TTS player node** - `AVAudioEngine.detachNode` on a live
  node raises NSException (SIGABRT). The player is attached once and reused.
- **SFSpeechRecognizer:** `task.cancel()` fires the old task's handler with an
  error. Restart cycles are guarded by a generation counter or the recognizer
  goes deaf after the first suspend/resume.
- **Glasses camera needs a separate permission** granted through the Meta AI
  app: `wearables.requestPermission(.camera)` (the Photo test button runs it).
  Streams fail with `permissionDenied` otherwise.
- **Camera streams are one-shot:** fresh `addStream()` per capture, stopped
  via `defer` on every path. Config matches Meta's CameraAccess sample
  (`.raw`, `.low`, 24 fps).
- **Display HUD (Ray-Ban Display):** `HermesDisplayManager` attaches
  `addDisplay()` to the SAME DeviceSession as the camera. Every display
  call is best-effort - errors are logged, never surfaced. Settings keys:
  `display_hud_enabled` (default true), `display_silent_mode`.
- **Glasses mic and the HUD are mutually exclusive.** The glasses mic is
  Bluetooth HFP (the DAT SDK has no audio capability); an active HFP/SCO
  link makes the glasses firmware show its CALL SCREEN on the lens, which
  covers all DAT display content. iPhone mic = HUD visible; glasses mic =
  call screen. Firmware behavior - cannot be overridden from the app.
- **Headset mode is the pocket setup:** `MicSource.headset` routes HFP to
  earbuds (never to the glasses - port chosen by name heuristic in
  `HermesAudioManager.looksLikeGlasses`), so the lens keeps the HUD while
  mic + TTS live in the ears. Falls back to the iPhone mic (with a notice)
  when no non-glasses HFP device is present.
- **Device context:** every query carries a context line (time, location,
  motion, connectivity, battery, weather) as a SECOND, uncached system block
  (persona block stays first + cached). History stores raw user text only.
  Keys: `context_enabled` / `context_precise_location` (both default true).
- **On-device intents (`IntentDetector`, `Services/EmoDrink/`):** the
  finalized transcript is classified BEFORE the assistant, as a WHOLE
  utterance: "what should I drink", "start/stop drink mode". Anything longer
  is a question for the assistant.
- **Settings is four pages** (`Views/SettingsView.swift`): Glasses (with the
  Developer test panel under it), Assistant, Language and voice, Drinks. A
  typed API key is owned by the ROOT SettingsView and committed on Done *and*
  swipe-dismiss.
- **Replies with options become buttons** (`ChoiceDetector`, pure, tested in
  `tests/choices/`). "A) Sydney, B) Melbourne, …" turns into lens buttons,
  chat chips, and a line on the simulated lens; tapping one submits the
  option's WORDS, not its letter. Deliberately conservative - two or more
  markers, ascending from A/1, each with text - because a false positive
  replaces Stop/Repeat on a display the wearer can't easily escape. A reply
  carrying options never auto-dwells away.
- **Mic tap-to-switch cannot pre-filter by device.** HFP ports only appear
  in `availableInputs` once the audio category allows Bluetooth, and the
  iPhone-mic path deliberately doesn't (it stops iOS hijacking the input).
  Enumerating anyway made connected glasses report "not available", so
  `toggleMicSource` walks to the next route that actually takes and
  `setMicSource` returns whether it did.
- **The Meta AI camera grant is requested AT PAIRING**
  (`ensureGlassesCameraAfterPairing`, fired from `ContentView.onChange` of
  `registrationState`), offered again in onboarding, and shown on the
  Settings Glasses page under the "Glasses camera" header. It used to be
  requested in exactly one place - the Photo test button - so anyone who
  never pressed it hit "camera unavailable" in drink mode, with nothing
  explaining why. Never gate a feature on this grant without offering the
  interactive request; `ensureCameraPermission(interactive: false)` alone is
  a dead end.
- **The test panel must work from a cold start.** It exists to diagnose a
  broken setup, so requiring a running session is backwards. `testPhoto`
  borrows a camera-only session via `withCameraSession` and releases it;
  `testVisualQuery` warms one first; `testDisplay` makes its own.
- **Stream resolution is negotiated, never assumed.** `addStream` returns a
  bare `nil` (no thrown error, no reason) when the firmware won't serve the
  config you asked for. A live stream that demanded `.high` failed on device
  while every path that works - one-shot capture, and Meta's own
  CameraAccess sample - uses `.low`. `startLiveStream` now walks
  `.high → .medium → .low`, twice, and logs which one opened. The one
  persistent stream is drink mode's: started in `EmoDrinkViewModel.startStream`,
  stopped in `stopStream`. If you add a config knob, ladder it.
- **Display callbacks are wired in `init`, not `startSession`.** `wireDisplay()`
  must stay in the initialiser: the lens is reachable (display test, a pick by
  voice) before any session-scoped wiring exists.
- **Camera permission is TWO different grants.** The glasses camera is
  authorised through the Meta AI companion app
  (`wearables.checkPermissionStatus(.camera)`); the iPhone camera through
  iOS (`AVCaptureDevice`). Capture paths must gate on
  `ensureVisionPermission(interactive:)` and `hasVisionSource`, never on
  `ensureCameraPermission` / `isGlassesConnected` directly - those are the
  glasses answers, and in phone mode they are always no. Gating on
  those once silently disabled every phone-mode capture.
- **One AVCaptureSession per camera.** In phone mode the session already
  streams for drink mode, so a second consumer must observe rather than
  start its own: `addVisionFrameObserver(_:_:)` (the only observer today is
  `EmoDrinkViewModel.frameObserverKey`, "emodrink") and
  `visionStreamIsShared`. Never call `vision.stopLiveStream()` for a stream
  you didn't start - it blanks the screen the user is looking at.
- **Never offer "Connect Glasses" to registered glasses.** `startRegistration`
  on an already-registered user throws "User is already registered", which
  is a dead end. The Glasses page in Settings handles pairing and re-pair.
- **"Are glasses paired" is NOT "can a glasses session start".**
  `registrationState == .registered` and a non-empty `wearables.devices`
  both stay true for glasses that are paired but out of range, while
  `createSession` throws `DeviceSessionError.noEligibleDevice`. The only
  honest predicate is the SDK's own selector:
  `deviceSelector.activeDevice != nil` (`HermesSessionViewModel.glassesAvailable`).
  Getting this wrong made Auto phone-mode never fall back, so Start
  insisted on absent glasses.
  Route selection itself is pure and tested in `tests/vision-routing/`.
- **Never predict hardware without a fallback.** Eligibility can lapse
  between the check and the start, so the glasses path falling through to
  the phone is handled at two points: `startSession()`
  and `captureVisionPhoto()`. `PhoneCameraManager.capturePhoto()` will spin
  the camera up for a single frame if nothing is streaming, so either eye
  can serve a still. `logVisionDiagnostics(_:)` prints registration, device
  link states, `activeDevice`, and the chosen route - use it before
  theorising about which eye was picked.
- **The vision route is pinned for the life of a session.** `visionRoute`
  is recomputed only while nothing is pinned; the running session calls `pinVisionRoute`
  (`startSession`) and `unpinVisionRoute` on teardown. Without this, a momentary SDK flap redirected a
  capture to a camera that wasn't running.
- **The visual language lives in `Views/HermesDesign.swift`**. ONE accent -
  terracotta `#C4622D` and its shades; warm neutrals (cream `#F7F5F2`
  canvas, warm black `#1C1B1A`), never stock iOS greys or per-row rainbow
  icons. Build screens out of the primitives there (`HermesSection`,
  `HermesCard`, `HermesRow`, `HermesIconTile`, `HermesChip`,
  `HermesStatusPill`, `HermesDeviceCard`, `HermesScrollPage`) rather than
  re-styling a `List`; pages that keep a stock `Form` (Language and
  voice, Glasses status) call the local `hermesFormStyle()` so the canvas matches.
  `HermesMark` is the winged logo as a `Shape` (SVG polygons on a 140x72
  canvas); the wordmark is system `.heavy` + wide tracking, since no
  Montserrat file ships with the app.
- **The test panel lives in Settings › Glasses › Developer**, with the
  diagnostics rows. Nothing floats over the home screen.
- **`VoiceCommandCatalog` reads phrases from the detectors** (`IntentDetector`,
  `EmoDrinkCommands`, `VisualQueryDetector`), never hand-copied.
- **ChangeGate thresholds are provisional** (0.35 change / 0.12 settle);
  `VendingMachineGate` wraps them for drink mode.
- **Project files: `tools/pbx-register.py`** adds a new file's four pbxproj
  entries; **`tools/pbx-unregister.py <basename> ...`** removes every entry for a
  deleted one (never hand-edit the pbxproj for a deletion).
- **EmoDrink:** the pick is on-device (`DrinkRecommender`, pure, tested) and
  the AI only phrases and converses. `EmoDrinkViewModel` is owned by the App
  struct and borrows the session through hooks (`emoDrinkClaimer`,
  `onEmoDrinkIntent`, `onEmoDrinkSessionEnding`, `emoDrinkLensIdle`). While a
  drink is on the lens the claimer takes only its replies; everything else
  goes to the assistant with `DirectClient.systemPromptOverride` set to the
  persona. `askPersona` detaches the claimer for one query so the generated
  "why" question cannot loop. Drink mode reuses `ChangeGate` through
  `VendingMachineGate` (8 s spacing, 150/h, 120 s cooldown after a pick) and
  `FrameTools.canRunVisionChecks` as its preflight. The default physiology
  feed is this repo's `mock/physiology.json` on raw.githubusercontent.com:
  pushing a change to that file changes what every install reads.

## Build & run

```bash
# iOS (from repo root; use your own device ID from `xcrun devicectl list devices`)
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build

```

### Two traps in the standalone test suites

- **`tests/*/main.swift` end in `print(...)` then `exit(...)`.** New assertions
  must be INSERTED ABOVE those two lines. Appended to the bottom they sit
  after `exit()`, never run, and the suite still reports all-green - so the
  tests look like they pass when they were never executed.
- **`AIProvider.swift` does not compile alone.** `AIProviderRegistry`
  references `AnthropicProvider`, `OpenAICompatibleProvider` and
  `GeminiProvider`, so any suite needing `AIProviderError` (or anything else
  from that file) must list all four provider sources on the `swiftc` line.
  `tests/providers/main.swift`'s header carries the canonical command.

## Next milestones

- Translate the Settings labels (lens and speech are already bilingual).
- Apple Health as a physiology source.
- Detect which drinks the machine actually sells.
