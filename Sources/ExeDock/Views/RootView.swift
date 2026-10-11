import SwiftUI

/// Gates the main UI behind `SetupCoordinator` so the app can detect and prepare a Sikarugir
/// engine (and ExeDock's own bottle) automatically the first time it's launched.
struct RootView: View {
    @StateObject private var setup = SetupCoordinator()
    @StateObject private var model = AppModel()
    @AppStorage(WizardCompletion.storageKey) private var hasCompletedWizard = false
    @LocalState private var showingWizard = false

    var body: some View {
        Group {
            if setup.stage == .ready {
                ContentView()
                    .environmentObject(model)
                    .sheet(isPresented: $showingWizard) {
                        SetupWizardView()
                    }
                    .transition(.opacity)
            } else {
                SetupView(setup: setup)
                    .transition(.opacity)
            }
        }
        // A real, previously-missing transition - the moment setup actually finishes (the boot
        // screen above) was a hard, instant cut straight to the dashboard, the single most jarring
        // beat in the whole first-launch experience. `.animation(value:)` here is enough on its
        // own (no withAnimation needed at the mutation site) since `setup.stage` is Equatable.
        .animation(.easeInOut(duration: 0.35), value: setup.stage)
        .onAppear {
            setup.runSetup()
        }
        .onChange(of: setup.stage) { newStage in
            if newStage == .ready {
                model.onSetupReady()
                // Only a brand-new install (or one where it was explicitly skipped/never finished)
                // ever sees this on its own - "on request in settings later on" otherwise, per live
                // feedback, via DefaultSettingsSheet's own "Run Setup Wizard Again".
                if !hasCompletedWizard {
                    showingWizard = true
                }
            }
        }
    }
}
