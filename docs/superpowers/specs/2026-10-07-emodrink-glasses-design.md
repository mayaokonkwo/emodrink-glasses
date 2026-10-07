# EmoDrink Glasses: a physiology-informed drink pick on smart glasses

Date: 2026-10-07 · Status: approved design, awaiting spec review

## 1. Intent

**Who:** Taka (Takahiro, AHLab), who ran the EmoDrink study with Asahi and
lent the Ray-Ban Display glasses and material this app was built with. The
app is a thank-you gift, and a continuation of EmoDrink on glasses instead
of a Quest 3.

**Problem:** EmoDrink showed that a physiological signal becomes useful only
at the moment a person can act on it, standing in front of a vending
machine. The study needed a headset, a room-anchored virtual machine and a
watch sitting still for a minute. Glasses can deliver the same moment in
the real world, hands-free, in a few seconds.

**Outcome:** the wearer walks up to any beverage vending machine. The lens
shows one drink and a one-line reason grounded in last night's sleep and
this morning's physiology. They can tap or ask why, ask for something else,
or talk it through with the agent. Everything the study cared about stays:
the pick is suggestive, never diagnostic, and the body data is the point.

**What the user decided (brainstorm, 2026-10-07):**

| Question | Decision |
|---|---|
| How the glasses know a machine is near | The camera sees it: a frame every few seconds goes to the vision provider with a yes or no question, only while "drink mode" is on. Voice and the glasses button also work anywhere. |
| Where sleep and physiology come from | A hosted JSON document at a URL the user controls, plus three mock profiles (rested, short night, stressed) so the demo works offline. |
| Which drinks | Public Asahi Group soft drinks sold in Japanese vending machines, tagged by function. No contract material. |
| Who picks | An on-device deterministic scorer picks; the AI only phrases the rationale and holds the conversation. |
| Name | EmoDrink Glasses, repo `mayaokonkwo/emodrink-glasses`, a fork of Hermes Glasses. |

**Success criteria**

- With a mock profile selected and no network, saying "what should I drink"
  shows a drink on the lens with a reason in under 2 seconds.
- In drink mode, walking up to a vending machine (or pointing the iPhone at
  a photo of one in phone mode) shows the pick without any voice or tap,
  and does not show it again for 2 minutes.
- "Why" and any spoken question get a reply that names the sleep or HRV
  figure the pick came from and never names an emotion or a diagnosis.
- Switching between the three mock profiles changes the pick in the way a
  reader of section 5 would predict.
- Drink mode costs at most 150 vision calls per hour and zero while nothing
  in view changes.
- All pure units pass their standalone swiftc suites; the Xcode project
  builds for iOS.

## 2. Architecture

**Approach: the phone runs everything**, exactly as Build Check does.
Physiology fetch, scoring, machine detection and the conversation all run in
the app, through the existing vision routing (`VisionSource`: AiSee / Meta /
iPhone) and the existing provider path (`DirectClient`). Rejected
alternatives: a server-side recommender (adds infrastructure for a gift that
should run from a bare phone) and letting the model choose the drink (not
reproducible on stage, and the study's whole method was holding the pick
constant).

A new Hermes app, **EmoDrink**, registered in `HermesAppRegistry` as
`emodrink` (capabilities: vision, microphone, lens; `requiresGlasses: false`
so phone mode works). Added to `newAppIDs`.

| Unit | File | Responsibility | Pure + tested |
|---|---|---|---|
| `PhysiologySnapshot` | `Services/EmoDrink/PhysiologySnapshot.swift` | The day's body data, Codable, with the JSON wire format and the derived `BodyState` | yes |
| `PhysiologySource` | `Services/EmoDrink/PhysiologySource.swift` | Protocol plus `RemoteJSONPhysiologySource` and `MockPhysiologySource` (three profiles) | mock yes, remote decode yes |
| `PhysiologyStore` | `Services/EmoDrink/PhysiologyStore.swift` | Last good snapshot cached in Application Support/`emodrink/snapshot.json`, with fetch time and source label | codec yes |
| `Drink`, `DrinkCatalog` | `Services/EmoDrink/DrinkCatalog.swift` + `Resources/EmoDrink/asahi-drinks.json` | Catalogue value types and the bundled list | decode yes |
| `DrinkRecommender` | `Services/EmoDrink/DrinkRecommender.swift` | Snapshot + time of day + preferences to one pick, two alternates, rule rationale | yes |
| `VendingMachineGate` | `Services/EmoDrink/VendingMachineGate.swift` | Reuses `ChangeGate`; adds the post-pick cooldown and the per-hour budget for detection | yes |
| `VendingMachineDetector` | `Services/EmoDrink/VendingMachineDetector.swift` | Prompt for the yes or no vision check and the strict parser of the answer | parse yes |
| `EmoDrinkPersona` | `Services/EmoDrink/EmoDrinkPersona.swift` | Builds the system prompt from snapshot, pick, alternates and catalogue | yes |
| `EmoDrinkScreens` | `Services/EmoDrink/EmoDrinkScreens.swift` | Lens cards: watching, recommendation with buttons, sample-data note | device |
| `EmoDrinkViewModel` | `ViewModels/EmoDrinkViewModel.swift` | Wires fetch, scorer, detection loop, lens, persona swap, voice | device |
| `EmoDrinkView` | `Views/EmoDrinkView.swift` | Phone sheet: snapshot card, pick card, drink mode toggle, catalogue | device |
| Mock feed | `mock/physiology.json` | The default remote document, served by raw.githubusercontent.com from this repo | n/a |

Each new `.swift` file needs the four manual `project.pbxproj` edits, as
for Build Check. The JSON catalogue and the mock feed are bundle resources.

## 3. Physiology data

**Wire format** (`mock/physiology.json`, and whatever a watch sync writes
to the configured URL):

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

`stress` (0 to 100) and `steps` are optional. Baselines are optional; when
missing, the HRV and resting heart rate comparisons are skipped and the
state leans on sleep alone. Unknown keys are ignored so a richer sync does
not break the app.

**Sources.** `PhysiologySource` has one method, `fetch() async throws ->
PhysiologySnapshot`.

- `RemoteJSONPhysiologySource(url:)`: a plain GET with a 6 second timeout.
  The default URL is this repo's `mock/physiology.json` on
  raw.githubusercontent.com, so a fresh install already has "data from the
  internet" and a watch sync can replace the file later without an app
  change.
- `MockPhysiologySource(profile:)`: three fixed snapshots.

| Profile | Sleep | HRV vs baseline | Resting HR vs baseline | Stress | What a reader expects |
|---|---|---|---|---|---|
| rested | 7.8 h, score 86 | +6 ms | −2 bpm | 22 | refresh or hydrate |
| short night | 5.1 h, score 48 | −9 ms | +3 bpm | 38 | energise before 15:00, recover after |
| stressed | 6.4 h, score 63 | −16 ms | +7 bpm | 71 | calm, caffeine-free |

**Refresh and caching.** The view model fetches when the EmoDrink app opens,
when drink mode starts, and before any pick if the cached snapshot is older
than 30 minutes or from a previous day. A successful fetch is cached by
`PhysiologyStore`. The pick always uses the most recent of: fresh fetch,
cached snapshot from today, mock profile. The lens card and the phone card
show a short source label ("Garmin, 07:12", "sample: short night").

**Settings keys** (`UserDefaults`): `emodrink_source_url` (string, default
the repo mock URL), `emodrink_use_mock` (bool, default false),
`emodrink_mock_profile` (string: `rested` / `short_night` / `stressed`,
default `short_night`), `emodrink_low_sugar` (bool, default false),
`emodrink_drink_mode_interval` (int seconds, default 4).

## 4. Drink catalogue

`asahi-drinks.json` is a bundled list of public Asahi Group soft drinks.
Each entry:

```json
{
  "id": "rokujo-mugicha",
  "name": "Asahi Rokujo Mugicha",
  "name_ja": "アサヒ 六条麦茶",
  "kind": "barley tea",
  "functions": ["calm", "hydrate"],
  "caffeine_mg": 0,
  "sugar": "none",
  "served": "cold"
}
```

`functions` are from the fixed set `hydrate`, `calm`, `energise`,
`recover`, `refresh`. `sugar` is `none`, `low` or `regular`. `served` is
`cold`, `hot` or `either`.

Initial list (12): Asahi Oishii Mizu Tennensui (water), Wilkinson Tansan
(sparkling water), Mitsuya Cider, Mitsuya Cider Zero, Calpis Water, Calpis
Soda, Juroku-cha (blended tea), Rokujo Mugicha (barley tea), Wonda Morning
Shot (canned coffee), Wonda Kin no Bito Black (black coffee), Super H2O
(isotonic), Dodekamin (energy drink). Names and tags are editable in the
JSON; the recommender reads only the fields above, so adding a drink is a
JSON edit.

## 5. Recommender

Pure, Foundation only, deterministic for a given snapshot, clock and
preferences.

**Step 1: body state.** Two coarse axes, each `low` / `mid` / `high`,
mirroring EmoDrink's arousal-valence framing without naming an emotion:

- **recovery** from sleep hours (under 6 low, 6 to 7 mid, 7 or more high),
  nudged one step down when sleep score is under 50 or HRV is more than
  10 ms under baseline, and one step up when sleep score is 80 or more and
  HRV is at or above baseline. Clamped.
- **arousal** from resting heart rate against baseline (5 bpm or more over
  is high, within 5 is mid, 5 or more under is low), overridden to high
  when `stress` is 65 or more and to low when it is 25 or less with low
  recovery. Without baselines, arousal is mid unless `stress` says
  otherwise.

**Step 2: wanted functions**, in priority order:

| recovery | arousal | wants |
|---|---|---|
| low | high | calm, hydrate |
| low | mid or low | energise (before 15:00), then recover, hydrate |
| mid | high | calm, refresh |
| mid | mid or low | hydrate, refresh |
| high | any | refresh, hydrate |

After 15:00 local time `energise` is removed and caffeine over 30 mg costs
a penalty, so a tired evening gets Super H2O, not Wonda. Steps over 8,000
add `hydrate` to the front of the list.

**Step 3: scoring.** Each drink scores 3 points for matching the first
wanted function, 2 for the second, 1 for the third. Minus 2 for caffeine
over 30 mg after 15:00. With `low sugar` on, minus 2 for `regular` sugar.
Ties break by catalogue order, so the result is stable. Output is a
`Recommendation`: the pick, the next two distinct drinks as alternates,
the body state, and a `reasons` array of short rule fragments ("slept 5.1
h", "HRV 14 ms under your usual", "it is after 3 pm"). The AI phrases these;
the lens shows the first two joined by a comma when the AI is unavailable.

"Something else" asks the recommender for the next alternate, in order,
cycling; it never calls the AI.

## 6. Vending machine detection (drink mode)

**Start and stop.** "Start drink mode" / "stop drink mode" (whole-utterance,
listed in `IntentDetector` and `VoiceCommandCatalog`), the toggle on the
phone sheet, or a glasses button mapped to the new `GlassesKeyAction
.toggleDrinkMode`. Drink mode holds the vision stream the way Build Check
holds it (`addVisionFrameObserver` in phone mode, the live glasses stream
otherwise) and ends with the session.

**Loop**, every `emodrink_drink_mode_interval` seconds (default 4): take the
latest frame, downscale with `BuildCheckComposer.downscaledJPEG`, compute a
Vision feature print, and ask `VendingMachineGate` whether to check.
`VendingMachineGate` wraps `ChangeGate` with `minInterval` 8 s,
`budgetPerHour` 150, and the same settled-and-changed logic, plus a
**cooldown of 120 s after a pick is shown** during which nothing is sent.
When the gate says send, `DirectClient.askOneShot` is called with the
`VendingMachineDetector` prompt: "Is a beverage vending machine clearly
visible and close enough to buy from in this photo? Answer with one word,
YES or NO." The parser accepts only a leading YES; anything else is NO.
A YES triggers the pick (section 7). A thrown error is logged and the loop
continues. Frames are never saved.

The lens shows a small "watching for a vending machine" card while drink
mode is on and nothing else is being shown; on the phone the sheet shows
the frame count, the sent count, and the budget used, so Taka can see the
gate working.

## 7. The moment on the lens and the conversation

**The pick.** Whether triggered by detection, by "what should I drink", by
the button or by the sheet, the view model: ensures a snapshot (section 3),
runs the recommender, swaps the persona in, and shows
`EmoDrinkScreens.recommendation`: the drink name large, the Japanese name
small, one line of reasons, the source label, and three choice buttons
rendered with the existing `ReplyChoice` mechanism so they work by tap and
by voice: **Why**, **Something else**, **Thanks**. The reply is also spoken
unless silent mode is on: "Try a Rokujo Mugicha. Short night and your HRV
is down, so something calm and caffeine-free."

That first spoken line comes from the AI when a key is set (one
`askOneShotText` with the persona and the `reasons`), with a 4 second
timeout; otherwise the rule fragments are read as they are.

**Conversation.** While the moment is active, every utterance that is not
a choice goes through the normal `submitQuery` path, but `DirectClient`
uses the EmoDrink persona instead of the Hermes prompt
(`systemPromptOverride`, set at moment start and cleared at moment end;
same-day history is shared, and a photo is still attached when the question
is visual). The persona carries: today's snapshot in plain words, the pick
and its reasons, the two alternates, the catalogue names, and these rules:
answer in 1 to 3 spoken sentences; ground every claim in the numbers given;
say "suggests" and "looks like", never a diagnosis or an emotion label; no
medical or health claims; if asked for alcohol, say this app only knows
soft drinks.

**End.** "Thanks" (button or word), "stop drink mode", 120 s without an
utterance, or a new pick. Ending clears the override and the lens, and
starts the detection cooldown. Bridge mode gets no persona swap: the moment
still shows the card and speaks the rule fragments, and questions go to the
bridge unchanged.

## 8. Phone surface and app registration

`EmoDrinkView`, a sheet: a snapshot card (the numbers, the source label, a
refresh button, a mock toggle with the profile picker and the URL field), a
pick card with a "Pick now" button and the three choices, the drink mode
toggle with the frame and budget counters, and the catalogue grouped by
function with the low-sugar toggle. Settings live on this sheet, not under
Hermes Settings, so the gift is one screen.

Registered in `HermesAppRegistry` after Build Check: id `emodrink`, title
"EmoDrink", image `cup.and.saucer`, summary "A drink that fits how you
slept, when you reach the machine", voice group ids `emodrink` and
`emodrink-replies`. The quick action row keeps its five pinned apps;
EmoDrink is found through More, with the "New" dot and the one-time card.

## 9. Voice commands and the glasses button

New `HermesIntent` cases: `.recommendDrink`, `.startDrinkMode`,
`.stopDrinkMode`. Whole-utterance phrases: "what should I drink", "what
should I get", "pick a drink", "pick me a drink", "recommend a drink",
"start drink mode", "stop drink mode". The three choices are matched by the
existing choice mechanism, with "thanks", "thank you" and "cheers" also
ending the moment. New `GlassesKeyAction` cases: `.recommendDrink`,
`.toggleDrinkMode`. `VoiceCommandCatalog` gains two groups so "What can I
say?" stays complete, and `tests/apps` and `tests/intent` cover them.

## 10. Errors

| Failure | Behaviour |
|---|---|
| Remote JSON fetch fails or decodes to nothing | Use today's cached snapshot; else the selected mock profile; the card says "sample data" |
| No vision source | Drink mode refuses to start with a one-line notice; voice and button picks still work |
| Vision check throws or returns neither word | Counted as NO, logged, loop continues |
| Budget exhausted | Gate returns overBudget; the card says "resting until HH:MM" |
| No API key or provider error on the first line | Rule fragments are spoken; "Why" answers with the fragments too; a one-line notice on the phone card |
| Catalogue JSON missing or invalid | Fatal in debug, and the app shows "catalogue missing" with picks disabled in release |

## 11. Testing

Standalone swiftc suites, in the repo convention:

- `tests/emodrink-recommender`: the three profiles at 09:00 and at 19:00
  give the expected pick; low sugar flips a regular-sugar pick; alternates
  are distinct and cycle; ties are stable.
- `tests/emodrink-snapshot`: the wire JSON decodes, optional keys may be
  absent, unknown keys are ignored, body state mapping edges (6 h, 7 h,
  HRV −10, HR +5).
- `tests/emodrink-detector`: YES, "yes.", "Yes, there is", "NO", empty, and
  garbage parse as expected; the gate's cooldown and budget.
- `tests/emodrink-persona`: the prompt contains the numbers, the pick and
  the guardrail sentences, and no emotion words from a fixed denylist.
- `tests/intent` and `tests/apps`: the new phrases and the registry entry.

Then `xcodebuild` for the iOS simulator to prove the project compiles. The
glasses walk-up and the HUD are tested by hand.

## 12. Repo, naming and delivery

- Fork: `mayaokonkwo/emodrink-glasses` from `prasanthsasikumar/
  hermes-glasses` at `95c1c97` (main, which includes Build Check). Local
  clone at `Documents/GitHub/emodrink-glasses`, commits authored as Maya
  Okonkwo, remote on the mayaokonkwo account only.
- Product name "EmoDrink Glasses", bundle id `com.flowsxr.emodrinkglasses`,
  display name on the phone "EmoDrink". The Meta Wearables Developer Center
  ties an app id to a bundle id, so the new bundle id must be registered
  there (or the Hermes bundle id reused in `Config/Hermes.xcconfig` for a
  build that replaces Hermes on the same phone). Prasanth decides at build
  time; `Config/Secrets.xcconfig` stays gitignored and is copied locally.
- The persona name on the lens stays "Hermes" for the general assistant;
  the EmoDrink moment does not introduce a second name.
- README: rewritten around EmoDrink Glasses, crediting the EmoDrink paper
  (Augmented Humans 2026), AHLab and Asahi as the study's industry partner,
  and Hermes Glasses as the base. Nothing about any contract. MIT licence
  kept, with the Hermes copyright line intact.
- Branch `main` only; no feature branches needed for a single-author gift.

## 13. Deferred

A history of picks with export, Apple Health as a source, product images on
the lens, Japanese-language replies, a real watch sync writing the JSON,
and detection of which drinks the machine in view actually sells.
