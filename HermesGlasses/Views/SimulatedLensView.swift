//
// SimulatedLensView.swift
//
// The lens, on the phone's screen. Renders the same `LensContent` the
// glasses render (design 5b), inside a framed box labelled with the real
// lens resolution - so what you see here is what a wearer would see.
//
// Read-only: it takes a value and draws it. Everything about what SHOULD be
// on the lens is decided by HermesDisplayManager, exactly as for glasses.
//

import SwiftUI

struct SimulatedLensView: View {
    let content: LensContent
    /// Drawn on the frame's tag. Ray-Ban Display's usable HUD area.
    var resolutionLabel: String = "640×200"
    /// Compact rendering for the home stage: fewer lines, the choices on one
    /// row that shrinks to fit, so the card never outgrows the stage.
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HermesScreenTitle(
                text: "EMODRINK", size: 13, tint: HermesTheme.accentLight.opacity(0.9)
            )

            if let label = content.label {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(HermesTheme.accentLight.opacity(0.8))
            }

            if !content.body.isEmpty {
                Text(content.body)
                    .font(.system(size: 19, weight: .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(HermesTheme.cream)
                    .lineLimit(compact ? 2 : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = content.statusLine {
                HStack(spacing: 8) {
                    if content.isLive {
                        Circle()
                            .fill(HermesTheme.online)
                            .frame(width: 7, height: 7)
                    }
                    Text(status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HermesTheme.cream.opacity(0.55))
                        .lineLimit(1)
                }
            }

            if !content.choices.isEmpty {
                let choices = Array(content.choices.prefix(3))
                if compact {
                    // One row of equal chips that shrink, so the stage never clips.
                    HStack(spacing: 6) {
                        ForEach(choices) { choiceChip($0).frame(maxWidth: .infinity) }
                    }
                } else {
                    // Three drink names rarely fit on one row: fall back to a column.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { ForEach(choices) { choiceChip($0) } }
                        VStack(alignment: .leading, spacing: 6) { ForEach(choices) { choiceChip($0) } }
                    }
                }
            }

            if content.isBlank {
                Text("Lens is idle")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(HermesTheme.cream.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            HermesTheme.lensChrome.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .background(.ultraThinMaterial.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(HermesTheme.accent.opacity(0.55), lineWidth: 1.5)
        }
        .overlay(alignment: .topLeading) {
            // The tag is the honesty label: this is a stand-in, at the real
            // lens's aspect, not a Hermes screen invented for the phone.
            Text("SIMULATED LENS · \(resolutionLabel)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .kerning(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(HermesTheme.accent,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .offset(x: 12, y: -9)
        }
        .animation(.easeOut(duration: 0.2), value: content)
    }

    /// Mirrors a button the wearer sees on the real lens.
    private func choiceChip(_ choice: ReplyChoice) -> some View {
        Text(choice.shortLabel)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .truncationMode(.tail)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(HermesTheme.accent, in: Capsule())
    }
}
