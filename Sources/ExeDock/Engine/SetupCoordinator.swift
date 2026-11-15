import Foundation
import AppKit

enum SetupStage: Equatable {
    case checking
    /// More than one engine is downloaded and none is extracted yet - genuinely ambiguous, so
    /// setup pauses here for the user to pick (see `SetupCoordinator.chooseEngine(_:)`) instead of
    /// silently guessing. `recommended` is pre-highlighted in the UI.
    case choosingEngine(options: [String], recommended: String?)
    /// Playdock is fetching its own copy of an engine directly from the real, public
    /// `Sikarugir-App/Engines` GitHub release - no separate Sikarugir Creator install needed.
    case downloadingEngine(String)
    case extractingEngine
    /// A truly fresh install (nothing ever installed but Playdock's own DMG) has an engine but no
    /// local Sikarugir wrapper app to copy shared runtime libraries from - see
    /// `SikarugirEngine.ensureFrameworksAvailable`'s doc comment. Playdock fetches the same public
    /// wrapper template Sikarugir Creator itself builds from instead, so this stays fully automatic.
    case downloadingRuntimeLibraries(String)
    case initializingBottle
    case waitingForSikarugirCreator
    case missingSikarugirCreator
    case ready
    case failed(String)
}

/// Runs automatically at launch: makes sure a Sikarugir engine and Playdock's own bottle are ready
/// to go before the main UI appears, "installing" whatever's missing with no separate app required.
///
/// If nothing's available locally, this downloads a real engine build directly from the public
/// `Sikarugir-App/Engines` GitHub release (`SikarugirEnginesRemote`) into the exact same
/// `~/Library/Application Support/Sikarugir/Engines/` folder Sikarugir Creator itself uses - so the
/// two stay fully interchangeable, and a brand-new user with nothing installed still gets a working
/// app with no extra steps. Only if that direct download can't happen (offline, GitHub unreachable)
/// does this fall back to handing off to an already-installed Sikarugir Creator and waiting for it,
/// rather than getting stuck.
@MainActor
final class SetupCoordinator: ObservableObject {
    static let sikarugirCreatorPath = "/Applications/Sikarugir Creator.app"

    @Published var stage: SetupStage = .checking
    /// The measurement for the step in progress: "Unpacking Sikarugir-11 · 800 MB of 2.1 GB".
    @Published var detail: String = ""
    /// 0...1 when the current step has a real size. Nil while the size is still unknown.
    @Published var fraction: Double?
    /// Steps that have started, oldest first. The screen lists these under the bar.
    @Published var log: [String] = []

    private var pollTask: Task<Void, Never>?
    /// Started as early as possible - right alongside whichever engine-acquisition path gets taken,
    /// not only once the engine itself is already ready - since the engine (from
    /// `Sikarugir-App/Engines`) and the runtime libraries (from `Sikarugir-App/Wrapper`) are two
    /// genuinely independent downloads from separate GitHub releases with no data dependency on
    /// each other; only bottle init at the very end actually needs both finished. Running them
    /// concurrently instead of strictly one-after-the-other measurably shortens a brand-new user's
    /// very first launch. Kept as a stored `Task` (not just called inline) specifically so it can
    /// be *started* here and *awaited*
    /// later in `ensureDefaultBottleReady()`, rather than those two things happening at the same
    /// call site the way a plain `await` would force.
    private var frameworksTask: Task<Void, Error>?

    func runSetup() {
        bindActivity()
        pollTask?.cancel()
        // A genuinely fresh start (first launch, or "Check Again" after a failure) - if the
        // previous attempt's frameworks task already failed (a real, live bug this guarded
        // against: reusing a failed `Task` just re-throws the same cached error forever, so
        // "Check Again" could never recover the runtime-libraries half even once the network came
        // back), this must start a brand new one rather than re-awaiting the dead one.
        frameworksTask = nil
        startFrameworksTaskIfNeeded()
        pollTask = Task { await performSetup() }
    }

    private func bindActivity() {
        SetupActivity.bind { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
    }

    private func apply(_ event: SetupActivity.Event) {
        switch event {
        case .phase(let message):
            if log.last != message { log.append(message) }
            detail = message
            fraction = nil
        case .tick(let message, let fraction):
            detail = message
            self.fraction = fraction
        }
    }

    private func startFrameworksTaskIfNeeded() {
        guard frameworksTask == nil else { return }
        frameworksTask = Task { try await self.ensureRuntimeFrameworksReadyWork() }
    }

    /// Called from the setup screen when more than one engine was offered and the user picked one.
    func chooseEngine(_ name: String) {
        bindActivity()
        pollTask?.cancel()
        startFrameworksTaskIfNeeded()
        pollTask = Task { await extractAndContinue(engineName: name) }
    }

    private func performSetup() async {
        stage = .checking

        // A cheap, side-effect-free check - safe to do first no matter how many engines are
        // downloaded, since it never triggers an extraction the user hasn't chosen yet.
        if SikarugirEngine.hasReadyCachedEngine() {
            await ensureDefaultBottleReady()
            return
        }

        // Sikarugir already downloaded at least one engine tarball - extracting it is a local copy,
        // no network involved, so Playdock can just do this for you. If it downloaded more than
        // one, that's a real choice worth asking about rather than silently guessing.
        if SikarugirEngine.hasDownloadedTarball() {
            let names = SikarugirEngine.availableEngineNames()
            if names.count > 1 {
                stage = .choosingEngine(options: names, recommended: SikarugirEngine.recommendedEngineName())
                return
            }
            await extractAndContinue(engineName: names.first)
            return
        }

        // Nothing local at all - try getting Playdock's own copy directly before falling back to
        // needing a separate app.
        if await downloadEngineDirectly() {
            return
        }

        guard FileManager.default.fileExists(atPath: Self.sikarugirCreatorPath) else {
            stage = .missingSikarugirCreator
            return
        }

        stage = .waitingForSikarugirCreator
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.sikarugirCreatorPath))
        await pollForEngine()
    }

    /// Returns `true` if this path took over setup (whether it ultimately succeeded or hit a real
    /// failure worth stopping on) - `false` only when the download itself couldn't happen at all
    /// (e.g. offline), so the caller falls through to the Sikarugir Creator hand-off instead.
    private func downloadEngineDirectly() async -> Bool {
        stage = .downloadingEngine("Looking for an engine to download…")
        let assets: [RemoteEngineAsset]
        do {
            assets = try await SikarugirEnginesRemote.fetchAvailableAssets()
        } catch {
            DiagnosticsLog.log("Setup: couldn't reach Sikarugir's engine releases - \(error.localizedDescription)")
            return false
        }
        guard let recommended = SikarugirEnginesRemote.recommendedAsset(among: assets) else { return false }

        do {
            try await SikarugirEnginesRemote.download(recommended) { [weak self] message in
                Task { @MainActor in self?.stage = .downloadingEngine(message) }
            }
        } catch {
            DiagnosticsLog.log("Setup: engine download failed - \(error.localizedDescription)")
            return false
        }

        await extractAndContinue(engineName: recommended.name)
        return true
    }

    private func pollForEngine() async {
        while !Task.isCancelled {
            if SikarugirEngine.hasDownloadedTarball() {
                let names = SikarugirEngine.availableEngineNames()
                if names.count > 1 {
                    stage = .choosingEngine(options: names, recommended: SikarugirEngine.recommendedEngineName())
                } else {
                    await extractAndContinue(engineName: names.first)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func extractAndContinue(engineName: String?) async {
        stage = .extractingEngine
        let resolved = await Task.detached(priority: .userInitiated) {
            try? SikarugirEngine.wineBinaryPath(engineName: engineName)
        }.value
        guard resolved != nil else {
            stage = .failed("Found a Sikarugir engine but couldn't prepare it. Try relaunching Playdock.")
            return
        }
        // Pass the same name along so the bottle is initialized with the exact engine that was
        // just extracted, not whatever `wineBinaryPath()` would pick again on its own.
        await ensureDefaultBottleReady(engineName: engineName)
    }

    private func ensureDefaultBottleReady(engineName: String? = nil) async {
        startFrameworksTaskIfNeeded()
        do {
            // Awaits the task started back in `runSetup()`/`chooseEngine()` - which has very
            // likely already finished by now, having run the whole time the engine itself was
            // being acquired, rather than only starting here.
            try await frameworksTask?.value
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }

        stage = .initializingBottle
        let bottle = BottleManager.shared.defaultBottle
        do {
            try await Task.detached(priority: .userInitiated) {
                let wine = try SikarugirEngine.wineBinaryPath(engineName: engineName)
                try BottleManager.shared.ensureInitialized(bottle, wineBinary: wine)
            }.value
            stage = .ready
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Makes sure the shared runtime libraries every launch needs are ready, transparently
    /// downloading Sikarugir's own public wrapper template for them (see
    /// `SikarugirWrapperTemplateRemote`'s doc comment) if no wrapper app happens to be installed
    /// locally to copy from already - so a completely fresh install doesn't dead-end asking the
    /// user to go build a wrapper app in a separate tool first. A no-op, near-instant check for
    /// anyone who already has this (the overwhelmingly common case). The actual work behind
    /// `frameworksTask` - runs concurrently with engine acquisition, so its own stage messaging can
    /// genuinely interleave with the engine's for however briefly they're both actually downloading
    /// at once; by the time `ensureDefaultBottleReady` awaits this, the engine's own async work is
    /// always already finished, so there's no risk of the two fighting over `stage` past that point.
    private func ensureRuntimeFrameworksReadyWork() async throws {
        let alreadyReady = await Task.detached(priority: .userInitiated) {
            (try? SikarugirEngine.ensureFrameworksAvailable()) != nil
        }.value
        if alreadyReady { return }

        stage = .downloadingRuntimeLibraries("Looking for Playdock's runtime libraries…")
        try await SikarugirWrapperTemplateRemote.downloadFrameworks(into: SikarugirEngine.exeDockFrameworksDir) { [weak self] message in
            Task { @MainActor in self?.stage = .downloadingRuntimeLibraries(message) }
        }
        SikarugirEngine.markFrameworksReady()
    }
}
