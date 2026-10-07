# EmoDrink Glasses

One drink, picked from how you slept, offered the moment you reach the
vending machine. On **Meta Ray-Ban Display** glasses (and AiSee or other
Realtek-based glasses, or an iPhone alone in phone mode).

EmoDrink Glasses continues the [EmoDrink](https://dl.acm.org/doi/full/10.1145/3795011.3797399)
work (Augmented Humans 2026, AHLab with Asahi as the study's industry
partner): a physiological signal is only useful at the moment a person can
act on it. The study did that in a Quest 3 with a room-anchored virtual
machine. This does it on glasses, in the real world, hands-free, in a few
seconds. Built as a thank-you for Taka, who ran the study and lent the
glasses.

It is a fork of [Hermes Glasses](https://github.com/prasanthsasikumar/hermes-glasses),
MIT licensed; everything Hermes does (voice, vision, navigation, people,
Build Check, phone mode) is still here and described in that repo's README.

## What it does

- **Reads your morning.** Last night's sleep hours and score, HRV and
  resting heart rate against your usual, steps and stress, from a small
  JSON document at a URL you control (the repo's own `mock/physiology.json`
  by default, so it works out of the box). That default is a fixed sample
  document, not a watch; the card says so. Three sample profiles (rested,
  short night, stressed) for an offline demo.
- **Picks one drink, on the phone.** A small deterministic rule maps the
  numbers to a coarse recovery and arousal state, the way EmoDrink did, and
  ranks a catalogue of twelve public Asahi Group soft drinks (water,
  sparkling, Calpis, teas, canned coffee, isotonic). The pick is
  reproducible; the AI never chooses.
- **Offers it on the lens.** Drink name, Japanese name, a one-line reason,
  and three buttons: Why, Something else, Thanks. Tap or just say them.
- **Talks about it.** Anything else you say goes to your AI provider in a
  drink persona that knows your numbers and the catalogue, and follows the
  study's rule: suggestive, never diagnostic. No emotion labels, no health
  claims.
- **Drink mode.** Say "start drink mode" and the glasses watch quietly. A
  frame goes to the vision provider only when the scene changes and
  settles (at most 150 small calls an hour), with one yes or no question:
  is there a vending machine? Yes shows the pick. Two minutes of quiet
  follow every pick.
- **Works without the camera.** "What should I drink" picks anywhere.
  Without an API key the pick still appears, spoken from the rules.

## Say

| Say | What happens |
|---|---|
| "What should I drink" | The pick, now |
| "Start drink mode" / "Stop drink mode" | Camera watching on / off |
| "Why" | The reason, in the persona |
| "Something else" | The next drink in rank order |
| "Thanks" | Ends the moment |

## Your own data

Point the feed URL (More › EmoDrink) at a JSON document of this shape,
for example one a watch sync writes:

```json
{
  "date": "2026-10-07",
  "source": "Garmin Venu 3S",
  "sleep": { "hours": 6.2, "score": 61 },
  "hrv_ms": 38,
  "hrv_baseline_ms": 52,
  "resting_hr": 58,
  "resting_hr_baseline": 54,
  "steps": 4200,
  "stress": 46
}
```

`stress`, `steps` and the baselines are optional; unknown keys are ignored.
An https URL is recommended; plain http also works. The app keeps the last
fetch and fetches again when that copy is older than 30 minutes, or when you
tap "Fetch again". The
three sample profiles under "Use sample data" work offline.

## Setup for EmoDrink

Same as Hermes Glasses (below): a Meta Wearables app id in
`Config/Secrets.xcconfig`, and an AI provider key in Settings for the
conversation and drink mode. Open **More › EmoDrink** on the phone to see
today's numbers, switch to sample data, change the feed URL, or toggle
drink mode. The bundle id is `com.flowsxr.emodrinkglasses`; register it in
the Meta Wearables Developer Center or build with the Hermes bundle id to
reuse an existing registration.

## Design

- Spec: `docs/superpowers/specs/2026-10-07-emodrink-glasses-design.md`
  (the implementation plan lives beside it locally; `docs/superpowers/plans` is gitignored, as in Hermes)

Tests: the EmoDrink units are pure Swift with standalone suites under
`tests/emodrink-*` (compile lines in each `main.swift`).

---

# What it is built on: Hermes Glasses

## Architecture

There are two runtime paths. **Direct (your API)** needs no server - the phone
calls your provider itself:

```
┌─────────────┐   Bluetooth    ┌──────────────┐     HTTPS      ┌─────────────────────┐
│  Ray-Ban    │ ─────────────▶ │  iPhone app  │ ─────────────▶ │  Your AI provider   │
│  glasses    │  (DAT SDK:     │  (SwiftUI)   │  query +       │  Claude · OpenAI ·  │
│             │   camera)      │  on-device   │  base64 photo  │  Gemini · Ollama    │
└─────────────┘                │  STT + TTS   │ ◀───────────── │                     │
                               └──────────────┘   reply text   └─────────────────────┘
```

**Hermes agent (bridge)** routes through a Mac running the agent (tools +
memory), over a WebSocket:

```
┌─────────────┐   Bluetooth    ┌──────────────┐    WebSocket     ┌──────────────────┐
│  Ray-Ban    │ ─────────────▶ │  iPhone app  │ ───────────────▶ │  Mac bridge      │
│  glasses    │  (DAT SDK:     │  (SwiftUI)   │  text queries +  │  (Python)        │
│             │   camera)      │              │  base64 photos   │                  │
└─────────────┘                │  on-device   │ ◀─────────────── │  hermes chat CLI │
                               │  live STT    │  responses + TTS │  + edge-tts      │
                               └──────────────┘    (PCM 24 kHz)  └──────────────────┘
```

- **iOS app** (`HermesGlasses/`) - SwiftUI app using the
  [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios)
  0.8.0 for glasses registration, sessions, and camera capture, plus
  `SFSpeechRecognizer` for live on-device transcription. In Direct mode,
  `HermesGlasses/Services/Providers/` calls the provider API directly; in
  bridge mode, `HermesAPIClient` talks to the Mac bridge over WebSocket.
- **Bridge** (`bridge/hermes_bridge.py`) - a small Python WebSocket server on
  the Mac. Receives text queries, detects visual questions by keyword, requests
  a photo from the app when needed, invokes `hermes chat -q ... [--image ...]`
  (or calls a provider API directly), and streams back the reply text plus TTS
  audio (Edge TTS with macOS `say` fallback).

### WebSocket protocol (app ⇄ bridge, port 8765)

Only used in **Hermes agent (bridge)** mode - Direct mode never opens this
connection.

| Direction | Message | Meaning |
|---|---|---|
| app → bridge | `{"type":"query","text":...}` | Transcribed utterance (STT is on-device) |
| bridge → app | `{"type":"capture_photo"}` | Take a photo with the glasses now |
| app → bridge | `{"type":"photo","data":"<base64 jpeg>"}` | Captured photo |
| app → bridge | `{"type":"photo_error","message":...}` | Capture failed - answer text-only |
| bridge → app | `{"type":"response","text":...}` | Hermes's answer |
| bridge → app | `audio_start` / binary PCM16 24 kHz / `audio_end` | Spoken reply |

Binary frames from the app are reserved for mic audio (legacy server-side STT
path, still supported by the bridge). The bridge's `HERMES_BRIDGE_BRAIN` env
var now supports `anthropic` / `openai` / `gemini` (direct provider call) in
addition to the default `hermes` (agentic CLI with tools + memory).

## Setup

### Requirements

- iPhone with iOS 17+, Xcode 16+
- Meta Ray-Ban glasses paired with the Meta AI app
- A **Meta App ID + Client Token** for the glasses SDK, from the
  [Meta Wearables Developer Center](https://wearables.developer.meta.com/)
  (create a project → Configuration → the *Application ID* section
  auto-generates them). Copy `Config/Secrets.example.xcconfig` to
  `Config/Secrets.xcconfig` (gitignored) and fill in `META_APP_ID` /
  `CLIENT_TOKEN` - they're injected into `Info.plist`'s `MWDAT` dict at build
  time, so nothing sensitive is committed. In the Developer Center also
  register your app's **Bundle ID** (Meta rejects hyphens) and **Team ID**.
  See the [iOS DAT integration docs](https://wearables.developer.meta.com/docs/develop/dat/build-integration-ios/).
- **Path A (Direct):** an API key from your chosen provider - nothing else.
- **Path B (Hermes bridge):** additionally, macOS with Python 3.11+ and a
  working Hermes Agent install (`hermes chat` on PATH).

Pick one of the two paths below - you don't need both.

### Path A - Direct (your API), zero infrastructure

Build the app to your iPhone, then in the app go to
**Settings → Assistant → Backend: Direct (your API)**, pick a **Provider**
(Claude / OpenAI / Gemini / Local (Ollama)), paste your API key (or set a
**Base URL** instead, for Ollama or an OpenAI-compatible proxy), pick a
**Model**, and start talking. No Mac, no bridge - everything runs from the
phone, and keys are stored in the iPhone Keychain, one per provider.

1. Open `HermesGlasses.xcodeproj`, set your signing team, build to your iPhone.
2. In the app: **Connect Glasses** → complete registration in the Meta AI app.
3. **Settings → Assistant → Backend: Direct (your API)** → choose a Provider,
   Model, and paste your key.
4. Start a session. First run prompts for microphone + speech recognition
   permissions. The **glasses camera permission is granted via the Meta AI
   app** - Hermes asks for it right after pairing, and it can also be granted
   later from Settings → Devices or the test panel's Photo button.

### Path B - Hermes agent (bridge), full agentic assistant

For tool use and cross-turn memory, run a [Hermes Agent](https://hermes-agent.nousresearch.com)
on your Mac and point the app at it over WebSocket.

1. Install Hermes:
   ```bash
   curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
   ```
   (or use the desktop installer - see the
   [installation docs](https://hermes-agent.nousresearch.com/docs/getting-started/installation)).
   This puts the `hermes` CLI on your PATH.
2. Run the bridge:
   ```bash
   cd bridge
   pip install websockets edge-tts
   python hermes_bridge.py
   # → listens on ws://0.0.0.0:8765/voice
   ```
   Copy `bridge/.env.example` to `bridge/.env` to configure it - in
   particular, `HERMES_BRIDGE_TOKEN` is **required** if the bridge is
   reachable from the internet (clients then connect with
   `ws://host:8765/voice?token=<value>`).
3. In the app: build to your iPhone, **Connect Glasses**, then
   **Settings → Assistant → Backend: Bridge (server)** and set the endpoint
   to `ws://<your-mac-ip>:8765/voice`. The "Bridge" chip in the banner turns
   green when the bridge is reachable.

The bridge's `HERMES_BRIDGE_BRAIN` env var can also be set to `anthropic`,
`openai`, or `gemini` to skip the Hermes CLI and call that provider's API
directly from the bridge - but **those direct-provider brains are
single-turn only (no conversation memory)**; use the default `hermes` brain
for cross-turn history and tool access. If you do use a direct-provider
brain, make sure `HERMES_BRIDGE_MODEL` matches the chosen brain's provider
(e.g. a Claude model id only works with `anthropic`, an OpenAI model id only
works with `openai`).

### Comparison

| | Direct (your API) | Hermes agent (bridge) |
|---|---|---|
| Infra needed | none - just the app | a Mac running the bridge + Hermes |
| Providers | Claude, OpenAI, Gemini, local (Ollama) | Hermes agent (or bridge-side provider) |
| Tools / agentic | no | yes |
| Vision | yes | yes |
| Keys live in | iPhone Keychain | bridge environment |

## Testing

Use the built-in test panel (**Settings → Developer**). It works from a cold
start - no session needs to be running, except for the bridge tests, which
need the socket:

| Button | Verifies |
|---|---|
| Bridge | WebSocket connectivity + welcome handshake |
| Photo | Glasses camera capture alone (also runs the permission grant) |
| Query | Bridge → Hermes → response → TTS round trip |
| Visual | Full photo + vision pipeline |
| Display | Renders a test card on the lens HUD |

Bridge-side unit tests:

```bash
cd bridge && python -m unittest test_hermes_bridge -v
```

### Build for device and simulator

```bash
# iOS device
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build

# iOS simulator
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS Simulator' build
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the standalone Swift provider
test suite and the full build/test workflow.

## Project layout

```
HermesGlasses/
├── Models/yolo11n.mlpackage           # bundled on-device object detector
├── Services/
│   ├── HermesSpeechRecognizer.swift   # on-device live STT
│   ├── HermesAudioManager.swift       # mic capture + TTS playback + mic switching
│   ├── HermesCameraManager.swift      # glasses camera (DAT): photos + live stream
│   ├── PhoneCameraManager.swift       # iPhone camera (phone mode)
│   ├── HermesDisplayManager.swift     # lens HUD on Ray-Ban Display
│   ├── HermesAPIClient.swift          # WebSocket client (bridge mode)
│   ├── DirectClient.swift             # Direct-mode conversation loop
│   ├── Providers/                     # AIProvider seam (Claude/OpenAI/Gemini/Ollama)
│   ├── Navigation/                    # voice intents, routing, bearing, lens maps, Wikipedia
│   ├── Social/                        # encounters, conversation capture, badge OCR
│   ├── Lens/                          # object detection, dwell tracking, object log
│   └── EmoDrink/                      # physiology feed, drink picker, persona, vending machine gate
├── Resources/EmoDrink/asahi-drinks.json   # the drink catalogue
├── ViewModels/                        # session orchestration, registration
│   └── EmoDrinkViewModel.swift        # the EmoDrink moment and drink mode
└── Views/                             # SwiftUI screens (design system: HermesDesign.swift)
    └── EmoDrinkView.swift             # More › EmoDrink sheet
mock/physiology.json                   # default EmoDrink feed (a fixed sample document)
bridge/
├── hermes_bridge.py                   # WebSocket bridge on the Mac
├── .env.example                       # bridge configuration template
└── test_hermes_bridge.py              # unit tests
tests/                                 # standalone swiftc test suites, one dir per unit
docs/superpowers/                      # design specs and implementation plans
```

## Status / known limitations

- Voice loop and vision loop are working end-to-end on device, in both
  Direct and bridge modes.
- The microphone is switchable (iPhone / glasses / headset), but the glasses
  mic is Bluetooth HFP, and an active HFP link makes the glasses firmware
  show its call screen over the lens - so it's **mic or HUD, not both**.
  Headset mode is the workaround: mic + TTS in the earbuds, HUD on the lens.
- Someone speaking quietly across the table may be missed by conversation
  capture - the phone mic is tuned for the wearer. The recording is kept so
  a better transcription can recover it later.
- Glasses photos may arrive rotated (EXIF orientation not yet normalized).
- Visual-query detection is keyword-based ("look", "what is this", …).

## Discussion

Write-ups and demos, with questions answered in the comments:

- [r/SideProject - "I built an app that lets you talk to your own AI…"](https://www.reddit.com/r/SideProject/comments/1uvhx6l/i_built_an_app_that_lets_you_talk_to_your_own_ai/)
- [r/augmentedreality - "My AI agent lives on my Meta Ray-Bans. I asked it…"](https://www.reddit.com/r/augmentedreality/comments/1v0dbcy/my_ai_agent_lives_on_my_meta_raybans_i_asked_it/)
