# EmoDrink Focus: one screen, always watching, three drinks, Japanese, nothing else

Date: 2026-10-08 · Status: approved design (brainstorm 2026-10-08), awaiting plan

Builds on `2026-10-07-emodrink-glasses-design.md` and the gift build of 2026-10-08
(Asahi theme, bundled OpenRouter key, Meta Ray-Ban Display only, bundle id
`com.flowsxr.hermesglasses`).

## 1. Intent

**Who:** Taka, wearing Meta Ray-Ban Display glasses, iPhone in his pocket, in
front of a Japanese vending machine, thinking in Japanese.

**Problem:** the gift build still carries Hermes: a chat-style home, hidden
apps and their code, a 3000-line session model, English-only speech, a
robotic voice, and a drink mode he has to switch on by hand.

**Outcome:** the app opens straight into EmoDrink and starts watching by
itself. When a machine is in view the lens offers three drinks; he taps or
says one, hears a warm one-liner in his language, and can ask why. Nothing
unrelated to that remains in the app.

**Decisions (brainstorm, 2026-10-08):**

| Question | Decision |
|---|---|
| What the lens shows on detection | Three drinks (best pick first with its reason, two alternates) as buttons; choose by tap, by "one / two / three" or "first / second / third", or by the drink's name; then that drink's card with Why and Thanks |
| Japanese scope | Speech both ways, lens text and spoken lines in Japanese, Auto by iPhone language with a manual switch; Settings labels stay English |
| Camera | "Watch for vending machines" setting, default on: opening the app starts the session and drink mode; a "Check now" button for testing with a photo |
| Hermes features | Deleted from code, project and bundle, not hidden |
| Developer panel display test | Must attach the display itself (or say why it cannot) |

**Success criteria**

- Cold launch after onboarding: within 5 s the lens (or the simulated lens)
  shows "Watching" with no tap.
- Pointing the camera at a photo of a vending machine shows three drinks on
  the lens within 10 s; saying "two" or the second drink's name speaks a
  one-line rationale and narrows the card to that drink.
- With the iPhone language set to Japanese: 「何を飲めばいい」 shows the three
  drinks with Japanese names large; 「二番目」 picks the second; the spoken
  lines and the Why answer are Japanese.
- The spoken lines use an enhanced or premium system voice when installed,
  at a measured rate, and read as one or two friendly sentences.
- The app bundle no longer contains `faceid.mlpackage` or `yolo11n.mlpackage`;
  `HermesSessionViewModel.swift` is under 1200 lines; no source file,
  test, tool or doc for a removed feature remains; the Xcode build and every
  remaining standalone suite pass.
- Developer panel › Display test either shows the test card on the glasses
  or reports one of: no glasses connected, display session failed (with the
  SDK error), glasses mic in use (HUD hidden by the call screen).

## 2. Architecture

Same shape as before: the phone runs everything through `HermesSessionViewModel`
(now EmoDrink-sized), `EmoDrinkViewModel`, the DAT display, and `DirectClient`.
Three new pure units carry the new behaviour and are swiftc-tested:

| Unit | File | Responsibility |
|---|---|---|
| `EmoDrinkLanguage` | `Services/EmoDrink/EmoDrinkLanguage.swift` | `enum Language { en, ja }`, the Auto/en/ja setting, resolution from `Locale.preferredLanguages`, STT locale id, TTS language code, and `EmoDrinkStrings` (every lens/spoken string in both languages) |
| `DrinkChoiceParser` | `Services/EmoDrink/DrinkChoiceParser.swift` | Spoken or tapped text to an index 0..2: ordinals and numbers in en and ja, drink names in either language (whole word match on a distinctive token), fuzzy enough for STT |
| `VoicePicker` | `Services/EmoDrink/VoicePicker.swift` | Chooses the `AVSpeechSynthesisVoice` identifier for a language: premium over enhanced over default, a preferred list per language (en: Ava, Zoe, Samantha; ja: Kyoko, O-ren), and the rate 0.47; pure selection over a list of voice descriptors so it tests without AVFoundation |

Existing units change: `DrinkRecommender.reasons` and `EmoDrinkPersona`
take a `Language`; `EmoDrinkCommands` and `IntentDetector` gain Japanese
phrase sets; `LensContent` gains `.emoDrinkChoices`; `HermesSpeechRecognizer`
takes a locale at session start; `HermesSpeechSynthesizer` takes a voice and
rate from `VoicePicker`.

## 3. Home screen

`ContentView` becomes the EmoDrink screen. Top to bottom:

1. **Lens stage.** Phone mode: the live camera with the simulated lens over
   it, as the old phone-mode stage. Glasses mode: a dark stage with the
   "Glasses connected" badge and the same simulated lens mirroring what the
   Ray-Ban shows. The stage is always present; there is no separate chat
   screen.
2. **Today card.** Sleep h, score, HRV, resting HR tiles; a source line
   (feed name and time, or "sample: short night", or "feed dated …").
3. **Pick card.** Empty state "Watching for a vending machine" / "Say
   「何を飲めばいい」 any time" (per language); after a moment, the chosen drink,
   Japanese and English names, the reason line, and the Why / Thanks chips;
   during the three-drink step, the three options as chips.
4. **Start / Stop.** One large button. Start = session + drink mode (when
   the watch setting is on) in one tap. Stop ends both. A "Check now" text
   button beside it while watching.

Toolbar: Settings (gear) and Transcript (list icon, opens the existing
transcript sheet). The quick-action row, the app drawer, the What's-new
card, the hero card and the chat list are deleted. The screen is a plain
`VStack` inside the safe area with 16 pt side padding; the previous edge
clipping must not reproduce (measure on the iPhone 17 Pro).

Onboarding keeps its three steps with EmoDrink copy, and gains one line per
language about installing the enhanced voice (Settings › Accessibility ›
Spoken Content › Voices) when `VoicePicker` finds only the default.

## 4. Always watching

- Setting `emodrink_auto_watch` (bool, default true), shown in Settings ›
  Drinks as "Watch for vending machines when the app opens".
- On `ContentView` appear, once onboarding is complete and the setting is on:
  `startSession()` then `startDrinkMode()`. If the session cannot start
  (no mic permission) the pick card says so; voice picks still work once it
  can.
- Start/Stop button: Start runs the same pair; Stop runs `stopDrinkMode()`
  then `endSession()`.
- "Check now": sends the latest frame to the detector immediately, bypassing
  the change gate but not the budget; if the answer is NO, the pick card
  shows "No vending machine in view" for 3 s.
- Backgrounding: when the app goes to the background drink mode keeps
  running only while the glasses stream is the source (the DAT stream
  survives; the iPhone camera does not). Returning to the foreground
  restarts the phone stream if it was lost.

## 5. Three drinks on the lens

`Recommendation` already has `ranked`. The moment now has two steps.

**Step A: choices.** Lens card `LensContent.emoDrinkChoices(options: [(title, subtitle, reason)], source)`:
heading per language ("Pick one" / 「どれにする？」), three buttons labelled
`1 <name>`, `2 <name>`, `3 <name>` (name in the active language), the first
option's reason as the status line. Spoken: one sentence naming the three
("How about Rokujo Mugicha, Calpis Water, or Wilkinson?" / 「六条麦茶、カルピスウォーター、ウィルキンソンはどうですか」),
AI-phrased with the 4 s one-shot and a fixed fallback.

**Choosing.** `DrinkChoiceParser.index(for: text, options:, language:)`:
"one/two/three", "first/second/third", "the first one", "number two",
「一番目/二番目/三番目」「一/二/三」「最初の」「二つ目」, or a distinctive token of
the drink's English or Japanese name (longest-token match, case-insensitive;
"water" alone is not distinctive when two options contain it). A tap submits
the button's label, which the parser also reads.

**Step B: the chosen drink.** Card as today (name, other-language name,
reason, source) with Why and Thanks. Spoken: the AI one-liner for that drink
(same first-line path, now told "the wearer chose X; say one warm sentence
about why it fits, in <language>"), fallback from the rule fragments.
"Something else" is replaced by saying another option's number or name, or
"back" / 「戻る」 to see the three again.

**Ending.** Thanks / 「ありがとう」, "stop" / 「停止」, 120 s silence, or a new
detection after the cooldown. Unchanged otherwise.

## 6. Natural voice and Japanese

- `EmoDrinkLanguage.setting`: `auto` (default), `en`, `ja`; key
  `emodrink_language`. `resolved` = setting, or for auto the first of
  `Locale.preferredLanguages` starting with "ja" gives `.ja`, else `.en`.
- Speech recognition: `HermesSpeechRecognizer` is created per session with
  `Locale(identifier: language.sttLocale)` (`en-US` / `ja-JP`); on-device
  recognition is requested when supported.
- Speech output: `HermesSpeechSynthesizer.configure(voice:rate:)` from
  `VoicePicker.pick(for: language, available: AVSpeechSynthesisVoice.speechVoices())`,
  rate 0.47, pitch 1.0. A missing Japanese voice falls back to any `ja-JP`
  voice; a missing enhanced English voice falls back to the default.
- Persona: the system prompt ends with "Reply only in Japanese, in plain
  spoken form (です・ます), one or two short sentences, warm, like a friend at
  the machine. No lists, no bullet points." or the English equivalent
  ("Sound like a friend standing at the machine, one or two short sentences,
  no lists"). The summary of the snapshot stays English inside the prompt
  (the model translates), but drink names are given in both scripts.
- Lens text: `EmoDrinkStrings` provides heading, watching text, status hints,
  camera-lost line, no-machine line, choice heading, the three fallback
  spoken lines, and the reason fragments (`DrinkRecommender.reasons(…, language:)`
  renders 「睡眠5.1時間」「睡眠スコア48」「HRVがいつもより14ms低い」「安静時心拍がいつもより7高い」「ストレス71」「もう15時過ぎ」「すでに8,400歩」).
- Commands: `IntentDetector` gains 「何を飲めばいい」「何飲もう」「おすすめの飲み物」「見守りを開始」「見守りを停止」「ドリンクモード開始/停止」;
  `EmoDrinkCommands` gains 「なぜ」「どうして」「理由は」「他には」「別のもの」「次」「ありがとう」「どうも」「オッケー」「戻る」.
  `normalizeCommand` also strips Japanese punctuation (、。？！) and the
  particles-free whole-utterance match works as for English because the
  phrase sets are whole utterances.
- Lens card layout per language: Japanese active → Japanese name large,
  English small; English active → the reverse.

## 7. Delete the Hermes features

Removed entirely (files, project entries, tests, tools, docs, bundle
resources):

- People / encounters: `Services/Social/*` except nothing, `Services/People/*`,
  `faceid.mlpackage`, `PeopleView`, `RosterView`, `RegistrationView`,
  `LookupView`, `LookupViewModel`, `PersonLookupGate`, badge tools and tests
  (`tests/badge*`, `tests/encounters`, `tests/timeline`, `tests/roster`,
  `tests/face-*`, `tests/lookup`, `tests/conversation`, `tests/recording`,
  `tools/badge-probe.swift`, `tools/face-probe.swift`, `tools/ocr-probe.swift`,
  `tools/train-badge.md`, `tools/export-face.md`).
- Build Check: `Services/BuildCheck/*` except `ChangeGate.swift` and the
  image helpers EmoDrink uses (`FramePrint`, `downscaledJPEG` move to
  `Services/EmoDrink/FrameTools.swift`), `BuildCheckViewModel`,
  `BuildCheckView`, `ProcedureEditorView`, `tests/buildcheck-*` except the
  gate test (renamed `tests/change-gate`), `tools/changegate-probe.swift`.
- Lens object snap and Object Log: `Services/Lens/*`, `yolo11n.mlpackage`,
  `LensView`, `LensViewModel`, `ObjectLogView`, `tests/dwell`, `tests/lenslog`,
  `tests/lens-sessions`, `tools/export-yolo.md`.
- Navigation and definitions: `Services/Navigation/*` except `IntentDetector.swift`
  and the `HermesIntent` enum (moved to `Services/EmoDrink/Intents.swift`),
  `NavigationMapView`, `tests/bearing`, `tests/polyline`, `tests/mapbox`,
  `tests/wikipedia`; the `.navigate`, `.stopNavigation`, `.define`,
  `.rememberPerson`, `.startConversationCapture`, `.startBuildCheck` intents
  and their phrase sets; `LensContent` cases `.personSighted`, `.personLookup`,
  `.definition`, `.navigation`, `.encounterPrompt`, `.recording`,
  `.encounterSaved`, `.buildCheck`; the matching `HermesDisplayScreens` and
  `HermesDisplayManager` methods.
- AiSee: `Services/AiSee/*`, `GlassesVendor.swift`, `GlassesKeyMap.swift`,
  `tests/glasses-vendor`, `tests/glasses-keys`, the AiSee settings pages,
  `VisionSource` implementations other than Meta and phone, clip recording.
- Bridge: `HermesAPIClient.swift`, `AssistantBackend`, bridge settings,
  `bridge/` folder, the WebSocket section of the README, `tests/` suites that
  exist only for the bridge path.
- `HermesApp.swift` / `HermesAppRegistry` / `AppDrawerView` / quick actions
  / What's new: deleted (one screen, no apps). `VoiceCommandCatalog` keeps
  only EmoDrink groups and the visual-query group.
- Device context stays. `ChoiceDetector` stays (the lens buttons use
  `ReplyChoice`). `VisualQueryDetector` stays ("what am I looking at" is a
  natural question at the machine).

Each deletion step must leave the Xcode build green; the pbxproj is edited
with a small script that removes every entry for a deleted path.

## 8. Developer panel display test

`HermesDisplayManager.sendTest()` is reached from the Developer panel. It
must: if no `DeviceSession` is running, create one for the display only
(`attachDisplayToCameraSession` path) and wait up to 5 s for `.connected`;
then send the test card; then report. Failure texts: "No glasses connected",
"Display session failed: <error>", "The glasses microphone is in use, so the
glasses show their call screen instead of the HUD. Switch the mic to iPhone
and try again." Success: "Test card sent" and the card stays 4 s.

## 9. Settings (four pages)

- **Glasses:** connection card, Re-pair, camera access, phone-mode
  preference, the display test (Developer).
- **Assistant:** the managed-key row, "Use my own key", model.
- **Language and voice:** Auto/English/Japanese; the voice in use with a hint
  to install the enhanced one; mic source.
- **Drinks:** watch on open, check interval, low sugar, sample data toggle
  and profile, feed URL, the catalogue list.

## 10. Errors

As before, plus: STT unavailable for the chosen locale → notice "Japanese
speech recognition is not available on this iPhone; using English" and fall
back to en; no `ja-JP` voice installed → speak with the default `ja-JP`
voice if any, else English, and show the install hint once.

## 11. Testing

Standalone suites: `tests/emodrink-language` (resolution, string tables
complete for both languages), `tests/emodrink-choice` (ordinals, numbers,
Japanese, names, ambiguity), `tests/emodrink-voice` (picker preference
order and fallbacks over fixtures), `tests/emodrink-recommender` (reasons in
ja), `tests/emodrink-commands` and `tests/intent` (Japanese phrases),
`tests/lens-content` (choices card). Xcode build after every task. Device
checklist at the end: cold launch watching; photo detection; choose by
number, by name, by tap; Why; Thanks; Japanese run of the same; display test
with and without a session; background and return.

## 12. Deferred

Translating Settings labels; Apple Health; detecting which drinks the
machine sells; a Japanese UI font pass on the lens beyond the system default.
