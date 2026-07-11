//
//  WelcomeStep.swift
//  Jot
//
//  Phase 6 — wizard panel W1.
//  Blue Jot brand mark + "Voice transcription for fast messaging —
//  dictate into any app." One mark, one sentence, one button.
//

import SwiftUI

struct WelcomeStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 0), onClose: onClose)
        ) {
            VStack(spacing: 20) {
                Spacer(minLength: 72)

                WizardBrandMark(size: 84)
                    .accessibilityHidden(true)

                WizardItalicTitle(text: "Welcome to Jot.", size: 38)
                    .accessibilityAddTraits(.isHeader)

                Text("Voice transcription for fast messaging — dictate into any app.")
                    .font(JotType.displaySerif(17))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 4)

                Text("Free, private, and fully on-device — your words never leave your iPhone.")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Color.jotMute)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 2)
                    .padding(.horizontal, 24)
                    .accessibilityLabel("Free, private, and fully on-device. Your words never leave your iPhone.")

                Spacer(minLength: 40)
            }
        } footer: {
            WizardPrimaryButton(title: "Get started", action: onAdvance)
        }
    }
}

#Preview {
    WelcomeStep(onClose: {}, onAdvance: {})
}
