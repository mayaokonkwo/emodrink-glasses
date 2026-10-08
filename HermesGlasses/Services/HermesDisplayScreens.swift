//
// HermesDisplayScreens.swift
//
// Pure screen builders for the glasses display HUD: state → view tree.
// No session state lives here.
//

import MWDATDisplay

enum HermesDisplayScreens {
    /// User is speaking - show the partial transcript.
    static func listening(partial: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text("Listening", style: .meta, color: .secondary)
            Text(partial, style: .body)
        }
        .padding(24)
    }

    /// Query submitted, waiting for the brain.
    static func thinking(query: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text(query, style: .body, color: .secondary)
            Text("Thinking…", style: .meta, color: .secondary)
        }
        .padding(24)
    }

    /// Brief flash while a glasses photo is being captured.
    static func photoCaptured() -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Icon(name: .fourCornerFrame)
            Text("Photo captured", style: .body)
        }
        .padding(24)
    }

    /// The reply card. Stop appears only while TTS is playing.
    /// ComponentBuilder has no buildOptional, so conditional buttons are
    /// prebuilt as an array and emitted with a for-loop (buildArray).
    static func reply(
        text: String,
        speaking: Bool,
        choices: [ReplyChoice] = [],
        onStop: @escaping @Sendable () -> Void,
        onRepeat: @escaping @Sendable () -> Void,
        onNewChat: @escaping @Sendable () -> Void,
        onChoose: @escaping @Sendable (ReplyChoice) -> Void = { _ in }
    ) -> FlexBox {
        var buttons: [Button] = []

        // When the reply offered options, THOSE are the useful controls -
        // answering by tapping beats reading the letters back aloud. Stop
        // stays available while speech is playing; Repeat/New chat step
        // aside rather than crowd the lens.
        if !choices.isEmpty {
            if speaking {
                buttons.append(Button(label: "Stop", style: .secondary, onClick: onStop))
            }
            for choice in choices {
                buttons.append(Button(
                    label: choice.shortLabel,
                    style: .primary,
                    onClick: { onChoose(choice) }
                ))
            }
            return FlexBox(direction: .column, spacing: 12) {
                FlexBox(direction: .column) {
                    Text(text, style: .body)
                }
                .padding(24)
                .background(.card)

                FlexBox(
                    direction: .row, spacing: 8,
                    alignment: .center, crossAlignment: .center, wrap: true
                ) {
                    for button in buttons {
                        button
                    }
                }
            }
        }

        if speaking {
            buttons.append(Button(label: "Stop", style: .primary, onClick: onStop))
        }
        buttons.append(Button(label: "Repeat", style: .secondary, onClick: onRepeat))
        buttons.append(Button(label: "New chat", style: .secondary, onClick: onNewChat))

        return FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .column) {
                Text(text, style: .body)
            }
            .padding(24)
            .background(.card)

            FlexBox(
                direction: .row, spacing: 8,
                alignment: .center, crossAlignment: .center, wrap: true
            ) {
                for button in buttons {
                    button
                }
            }
        }
    }

    /// Confirmation flash after New chat.
    static func newConversation() -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Icon(name: .checkmarkCircle)
            Text("New conversation", style: .body)
        }
        .padding(24)
    }

    /// EmoDrink pick: name large, Japanese name small, the reason, and the
    /// three replies as buttons. No dwell: the wearer is deciding.
    static func emoDrink(
        title: String, subtitle: String, reason: String, source: String,
        choices: [ReplyChoice], onChoose: @escaping @Sendable (ReplyChoice) -> Void
    ) -> FlexBox {
        var buttons: [Button] = []
        for choice in choices {
            buttons.append(Button(label: choice.shortLabel, style: .primary, onClick: { onChoose(choice) }))
        }
        return FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .column, spacing: 6) {
                Text(title, style: .heading)
                Text(subtitle, style: .meta, color: .secondary)
                Text(reason, style: .body)
                Text(source, style: .meta, color: .secondary)
            }
            .padding(24)
            .background(.card)

            FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
                for button in buttons {
                    button
                }
            }
        }
    }

    /// Drink mode is on and nothing has been offered yet. Text arrives in
    /// the wearer's language.
    static func emoDrinkWatching(heading: String, text: String, hint: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                Icon(name: .fourCornerFrame)
                Text(heading, style: .heading)
            }
            Text(text, style: .body)
            Text(hint, style: .meta, color: .secondary)
        }
        .padding(24)
    }

    /// Step A: the heading, the first option's reason, and one button per
    /// drink ("1 Rokujo Mugicha"), stacked so long names stay readable.
    static func emoDrinkChoices(
        heading: String, status: String, choices: [ReplyChoice],
        onChoose: @escaping @Sendable (ReplyChoice) -> Void
    ) -> FlexBox {
        var buttons: [Button] = []
        for choice in choices {
            buttons.append(Button(label: choice.shortLabel, style: .primary, onClick: { onChoose(choice) }))
        }
        return FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .column, spacing: 6) {
                Text(heading, style: .heading)
                Text(status, style: .meta, color: .secondary)
            }
            .padding(24)
            .background(.card)

            FlexBox(direction: .column, spacing: 8) {
                for button in buttons {
                    button
                }
            }
        }
    }

    /// Blank the lens (idle state).
    static func blank() -> FlexBox {
        FlexBox(direction: .column) {}
    }

    /// Static screen for the test panel's Display button.
    static func testScreen() -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text("EmoDrink display", style: .heading)
            Text("Test card", style: .body, color: .secondary)
        }
        .padding(24)
    }
}
