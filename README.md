# EmoDrink Glasses

One drink, picked from how you slept, offered the moment you reach the
vending machine. On **Meta Ray-Ban Display** glasses, or an iPhone alone in
phone mode.

EmoDrink Glasses continues the [EmoDrink](https://dl.acm.org/doi/full/10.1145/3795011.3797399)
work (Augmented Humans 2026, AHLab with Asahi as the study's industry
partner): a physiological signal is only useful at the moment a person can
act on it. The study did that in a Quest 3 with a room-anchored virtual
machine. This does it on glasses, in the real world, hands-free, in a few
seconds. Built as a thank-you for Taka, who ran the study and lent the
glasses.

It is a fork of [Hermes Glasses](https://github.com/prasanthsasikumar/hermes-glasses),
MIT licensed, cut down to EmoDrink alone: navigation, people, Lens, Build
Check, AiSee and the Mac bridge are deleted from this repo. They live on in
the Hermes Glasses repo.

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

Point the feed URL (the EmoDrink tile on the home screen) at a JSON document of this shape,
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

- **The assistant key is built in.** This copy talks to OpenRouter with
  Gemini 2.5 Flash Lite, a cheap model that also handles the vending
  machine check, so nobody has to type a key. Settings › Assistant shows it
  as included; "Use my own key" replaces it, and a key you add always wins.
- **The key never lives in the repo.** It is injected at build time from
  the gitignored `Config/Secrets.xcconfig` (`BUNDLED_AI_PROVIDER`,
  `BUNDLED_AI_MODEL`, `BUNDLED_AI_KEY`; see `Config/Secrets.example.xcconfig`).
  Without it the app builds as before and asks for a key in Settings.
- **No Mac bridge in this build.** Direct mode is the only mode: the phone
  calls the provider itself.
- **Glasses still need a Meta Wearables app id** in `Config/Secrets.xcconfig`.
  Phone mode (the iPhone camera as the eye) works without it.

Tap the **EmoDrink** tile on the home screen to see today's numbers, switch
to sample data, change the feed URL, or toggle drink mode. The build uses the bundle id
`com.flowsxr.hermesglasses`, because the Meta Wearables Developer Center
ties the app id to that bundle id; the glasses only link to a bundle id
that is registered there. To ship under another id, register it in the
Developer Center first and change `PRODUCT_BUNDLE_IDENTIFIER` in the
project. EmoDrink therefore replaces Hermes Glasses on a phone that has it.

## Design

- Spec: `docs/superpowers/specs/2026-10-07-emodrink-glasses-design.md`
  (the implementation plan lives beside it locally; `docs/superpowers/plans` is gitignored, as in Hermes)

Tests: the EmoDrink units are pure Swift with standalone suites under
`tests/emodrink-*` (compile lines in each `main.swift`).

---

# What it is built on

The phone does everything; there is no server:

```
┌─────────────┐   Bluetooth    ┌──────────────┐     HTTPS      ┌─────────────────────┐
│  Ray-Ban    │ ─────────────▶ │  iPhone app  │ ─────────────▶ │  Your AI provider   │
│  Display    │  (DAT SDK:     │  (SwiftUI)   │  pick phrasing │  OpenRouter, Claude,│
│  glasses    │   camera, lens)│  on-device   │  + one photo   │  OpenAI, Gemini     │
└─────────────┘                │  STT + TTS   │ ◀───────────── │                     │
                               └──────────────┘   reply text   └─────────────────────┘
```

- **iOS app** (`HermesGlasses/`): SwiftUI, the
  [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios)
  for registration, sessions, camera and the lens, `SFSpeechRecognizer` for
  on-device speech, `AVSpeechSynthesizer` for the voice.

## Testing

Settings › Glasses › Developer has the test panel (works from a cold start):

| Button | Verifies |
|---|---|
| Display | Attaches the lens if needed and shows a test card, or says why it cannot |
| Sound | Plays a tone on the current output |
| Photo | Glasses (or iPhone) camera capture alone |
| Query | A text round trip to the provider |
| Visual | Photo plus vision round trip |

Standalone suites: one folder per unit under `tests/`, each with its
`xcrun swiftc` line in the header of `main.swift`.

```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build
```

## Project layout

```
HermesGlasses/
├── Services/
│   ├── HermesSpeechRecognizer.swift   # on-device live STT
│   ├── HermesSpeechSynthesizer.swift  # the voice
│   ├── HermesAudioManager.swift       # mic capture + playback + mic switching
│   ├── HermesCameraManager.swift      # glasses camera (DAT)
│   ├── PhoneCameraManager.swift       # iPhone camera (phone mode)
│   ├── HermesDisplayManager.swift     # the lens on Ray-Ban Display
│   ├── DirectClient.swift             # provider calls and conversation memory
│   ├── Providers/                     # AIProvider seam
│   └── EmoDrink/                      # physiology feed, picker, persona, gate, intents
├── Resources/EmoDrink/asahi-drinks.json   # the drink catalogue
├── ViewModels/                        # session (+Glasses, +Developer), EmoDrink
└── Views/                             # the home screen, Settings, onboarding
mock/physiology.json                   # default feed (a fixed sample document)
tests/                                 # standalone swiftc suites, one dir per unit
tools/                                 # pbx-register.py, pbx-unregister.py, make-app-icon.swift
```

## Status / known limitations

- The glasses mic is Bluetooth HFP, and an active HFP link makes the glasses
  show their call screen over the lens: mic or lens, not both. Headset mode
  (AirPods) keeps both.
- Glasses photos may arrive rotated (EXIF orientation not yet normalized).

## Discussion

Write-ups and demos, with questions answered in the comments:

- [r/SideProject - "I built an app that lets you talk to your own AI…"](https://www.reddit.com/r/SideProject/comments/1uvhx6l/i_built_an_app_that_lets_you_talk_to_your_own_ai/)
- [r/augmentedreality - "My AI agent lives on my Meta Ray-Bans. I asked it…"](https://www.reddit.com/r/augmentedreality/comments/1v0dbcy/my_ai_agent_lives_on_my_meta_raybans_i_asked_it/)
