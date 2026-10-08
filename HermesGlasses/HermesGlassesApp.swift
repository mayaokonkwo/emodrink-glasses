//
// HermesGlassesApp.swift
// Hermes Glasses - Talk to Hermes AI from Meta Ray-Ban glasses
//
// Main entry point. Configures the Meta Wearables DAT SDK, sets up
// audio capture from the glasses, and connects to Hermes Agent for
// real-time voice conversation.
//

import MWDATCore
import SwiftUI
import os

#if DEBUG
import MWDATMockDevice
#endif

private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "startup")

@main
struct HermesGlassesApp: App {
    /// The only screen until the two fundamentals (glasses display text,
    /// glasses camera feed) work. ContentView, onboarding and the
    /// EmoDrink/Hermes view models stay in the codebase but are not
    /// constructed, so nothing auto-starts a session, the camera or
    /// drink watching at launch.
    @State private var glassesLink: GlassesLink
    @State private var basicsViewModel: GlassesBasicsViewModel

    init() {
        // Step 0: the gift build's bundled assistant key. Never overwrites
        // a key the user typed.
        BundledAIKey.seedIfNeeded()

        // Step 1: Configure the DAT SDK once at launch
        do {
            try Wearables.configure()
        } catch {
            // Unconditional: a release build with a broken SDK config should
            // still leave a breadcrumb, not just the DEBUG console.
            logger.error("Failed to configure Wearables SDK: \(error.localizedDescription, privacy: .public)")
            NSLog("[Basics] Wearables.configure() failed: %@", error.localizedDescription)
        }

        #if DEBUG
        // Enable MockDeviceKit for testing without physical glasses
        if ProcessInfo.processInfo.arguments.contains("--mock-device") {
            MockDeviceKit.shared.enable(
                config: MockDeviceKitConfig(initiallyRegistered: false)
            )
        }
        #endif

        // The one path to the glasses (session, display, camera), shared
        // by everything that talks to them.
        let link = GlassesLink(wearables: Wearables.shared)
        self._glassesLink = State(wrappedValue: link)
        self._basicsViewModel = State(
            wrappedValue: GlassesBasicsViewModel(link: link)
        )
    }

    var body: some Scene {
        WindowGroup {
            GlassesBasicsView(viewModel: basicsViewModel)
                // Handle Meta AI URL callback after registration
                .onOpenURL { url in
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
        }
    }
}
