import SwiftUI

/// Shown while `SetupCoordinator` checks for / prepares the Sikarugir engine at launch - the very
/// first thing a brand-new install ever shows. Previously plain system chrome with no relation to
/// the rest of the app's real per-skin theming (the setup wizard that picks a skin hasn't run
/// yet at this point, so this reads the default/already-saved skin rather than letting someone
/// choose here - a real theme, not a themed choice).
struct SetupView: View {
    @ObservedObject var setup: SetupCoordinator
    @AppStorage(PlaydockSkin.storageKey) private var skinRaw = PlaydockSkin.luxury.rawValue
    private var skin: PlaydockSkin { PlaydockSkin(rawValue: skinRaw) ?? .luxury }

    var body: some View {
        ZStack {
            SkinBackground(skin: skin).ignoresSafeArea()
            if case .choosingEngine(let options, let recommended) = setup.stage {
                EngineChoiceView(options: options, recommended: recommended) { chosen in
                    setup.chooseEngine(chosen)
                }
            } else {
                standardStages
            }
        }
    }

    private var standardStages: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: iconName)
                .font(.system(size: 52))
                .foregroundStyle(iconColor)
            Text(title)
                .font(.title2)
                .bold()
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let current = currentStep {
                stepTracker(current: current).padding(.top, 6)
            }
            if showsSpinner {
                Group {
                    if let fraction = progressFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView(value: nil as Double?)
                    }
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
                .padding(.top, 4)
            }
            if showsRetryButton {
                Button("Check Again") {
                    setup.runSetup()
                }
                .font(.headline)
                .padding(.vertical, 4)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: setup.stage)
    }

    // MARK: - Step tracker

    private enum Step: Int, CaseIterable {
        case engine, bottle

        var label: String {
            switch self {
            case .engine: return "Sikarugir engine"
            case .bottle: return "Finishing up"
            }
        }
    }

    private var currentStep: Step? {
        switch setup.stage {
        case .checking, .downloadingEngine, .extractingEngine, .waitingForSikarugirCreator: return .engine
        case .downloadingRuntimeLibraries, .initializingBottle: return .bottle
        case .ready, .missingSikarugirCreator, .failed, .choosingEngine: return nil
        }
    }

    private func stepTracker(current: Step) -> some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { step in
                HStack(spacing: 6) {
                    Image(systemName: stepIcon(step, current: current))
                        .foregroundStyle(stepColor(step, current: current))
                    Text(step.label)
                        .font(.caption)
                        .foregroundStyle(stepColor(step, current: current))
                }
                if step != Step.allCases.last {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 20, height: 1)
                }
            }
        }
    }

    private func stepIcon(_ step: Step, current: Step) -> String {
        if step.rawValue < current.rawValue { return "checkmark.circle.fill" }
        if step == current { return "circle.dotted" }
        return "circle"
    }

    private func stepColor(_ step: Step, current: Step) -> Color {
        if step.rawValue < current.rawValue { return .green }
        if step == current { return .accentColor }
        return .secondary
    }

    // MARK: - Copy

    private var title: String {
        switch setup.stage {
        case .checking: return "Getting ready…"
        case .downloadingEngine: return "Installing Sikarugir…"
        case .extractingEngine: return "Installing the Sikarugir engine…"
        case .downloadingRuntimeLibraries: return "Installing Playdock's runtime libraries…"
        case .initializingBottle: return "Finishing up…"
        case .waitingForSikarugirCreator: return "Waiting for Sikarugir Creator…"
        case .missingSikarugirCreator: return "Sikarugir Creator isn't installed"
        case .failed: return "Setup ran into a problem"
        case .ready, .choosingEngine: return "Ready"
        }
    }

    private var subtitle: String {
        switch setup.stage {
        case .checking:
            return "Looking for what's already available."
        case .downloadingEngine(let message):
            return message
        case .extractingEngine:
            return "Copying it into Playdock - this only happens once."
        case .downloadingRuntimeLibraries(let message):
            return message
        case .initializingBottle:
            return "Just a moment more."
        case .waitingForSikarugirCreator:
            return "Playdock opened Sikarugir Creator so it can download what it needs to run your games. Let it finish - Playdock will pick it up automatically, no need to relaunch."
        case .missingSikarugirCreator:
            return "Playdock couldn't reach Sikarugir's engine download over the network, and there's no separate Sikarugir Creator install to fall back to here. Check your connection and try again, or install Sikarugir Creator and let it download an engine once."
        case .failed(let message):
            return message
        case .ready, .choosingEngine:
            return ""
        }
    }

    private var iconName: String {
        switch setup.stage {
        case .missingSikarugirCreator: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon"
        case .waitingForSikarugirCreator: return "arrow.triangle.2.circlepath"
        default: return "gamecontroller.fill"
        }
    }

    private var iconColor: Color {
        switch setup.stage {
        case .missingSikarugirCreator, .failed: return .orange
        default: return .secondary
        }
    }

    private var progressFraction: Double? {
        switch setup.stage {
        case .checking: return 0.1
        case .downloadingEngine: return nil // real download progress isn't tracked byte-by-byte
        case .extractingEngine: return 0.7
        case .downloadingRuntimeLibraries: return 0.8
        case .initializingBottle: return 0.9
        default: return nil
        }
    }

    private var showsSpinner: Bool {
        switch setup.stage {
        case .checking, .downloadingEngine, .extractingEngine, .downloadingRuntimeLibraries, .initializingBottle, .waitingForSikarugirCreator: return true
        default: return false
        }
    }

    private var showsRetryButton: Bool {
        switch setup.stage {
        case .missingSikarugirCreator, .failed: return true
        default: return false
        }
    }
}

/// Shown when Sikarugir Creator has more than one engine downloaded and ready - a real choice, so
/// setup pauses and asks instead of silently guessing.
private struct EngineChoiceView: View {
    let options: [String]
    let recommended: String?
    let onChoose: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Choose a Wine engine")
                .font(.title2)
                .bold()
            Text("Sikarugir Creator has more than one engine ready to go. Recommended is the safest bet for most games - you can always change this later.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(spacing: 10) {
                ForEach(options, id: \.self) { name in
                    Button {
                        onChoose(name)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.headline)
                                if name == recommended {
                                    Text("Recommended").font(.caption).foregroundStyle(Color.accentColor)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
