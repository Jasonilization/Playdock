import Foundation
import AppKit

/// Launches Windows executables through the Sikarugir engine ExeDock reuses.
enum ExeRunner {
    static let logsDir = ("~/Library/Logs/ExeDock" as NSString).expandingTildeInPath

    /// `preferWrapperEngine`, when true and the target bottle isn't already a wrapper bottle (that
    /// case always tries that wrapper's own launcher first, below), runs the exe with a real Sikarugir
    /// wrapper app's own bundled wine binary (see `SikarugirEngine.anyWrapperEngine`) instead of
    /// ExeDock's own separately-downloaded engine - still against `bottle`'s own prefix, just with a
    /// different engine reading it. Custom games use this, since a real Sikarugir engine build is
    /// guaranteed to work against a Sikarugir-created bottle. Falls back to
    /// ExeDock's own engine if no Sikarugir wrapper app is actually installed to borrow one from.
    @discardableResult
    static func run(exePath: String, in bottle: Bottle, arguments: [String] = [], config: GameModeConfig = GameModeConfig(), engineName: String? = nil, preferWrapperEngine: Bool = false) async throws -> Process? {
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = (exePath as NSString).lastPathComponent

        // A game living inside a *specific* Sikarugir wrapper's own bottle is launched by driving
        // that wrapper's own Configure app: set its "Windows app" path to this exact exe, then
        // trigger its own Test Run action - "just open configs and launch custom games after
        // setting the right paths, the test run works perfectly well," per live, repeated feedback,
        // confirmed live and repeatedly myself: the raw CLI (`Contents/MacOS/Sikarugir run <file>`,
        // tried first historically) fails with a WineAppInitializationError that never reproduces
        // outside it, and a direct `wine start /unix <file>` invocation gets some titles running but
        // not others (a real D3D12/vkd3d limitation against this Mac's Vulkan stack) - but
        // Configure's own Test Run, against the exact same engine/bottle/title, has launched every
        // game tried this way. See `SikarugirConfigureLauncher`'s own doc comment for how it's
        // actually driven (Accessibility APIs against real, found UI elements, not a blind
        // keystroke). Only falls back to the CLI-then-direct-wine chain below if that's unavailable.
        if case .sikarugirWrapper(let appPath) = bottle.kind {
            do {
                try await SikarugirConfigureLauncher.launch(exePath: exePath, wrapperAppPath: appPath, driveCPath: bottle.driveCPath)
                return nil // Configure owns the actual launch from here - no Process handle to return.
            } catch {
                DiagnosticsLog.log("Configure-driven launch failed for \(baseName): \(error.localizedDescription) - falling back to the wrapper CLI.")
            }

            let launcherBinary = appPath + "/Contents/MacOS/Sikarugir"
            if FileManager.default.isExecutableFile(atPath: launcherBinary) {
                let logPath = (logsDir as NSString).appendingPathComponent("\(baseName)-\(timestamp).log")
                FileManager.default.createFile(atPath: logPath, contents: nil)
                let logHandle = FileHandle(forWritingAtPath: logPath)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: launcherBinary)
                process.arguments = ["run", exePath] + arguments
                process.currentDirectoryURL = URL(fileURLWithPath: (exePath as NSString).deletingLastPathComponent)
                process.standardOutput = logHandle
                process.standardError = logHandle
                try process.run()

                // The wrapper's own CLI is the normal, preferred path here - but it's been observed
                // failing fast (exits within ~1s, a short log ending in
                // "SikarugirSdk.WineAppInitializationError") for reasons that don't reproduce from
                // outside it even against a known-good, already-initialized prefix. Critically, that
                // failure exits *cleanly* (status 0, not a crash) - "Closing Sikarugir" is its own
                // graceful shutdown message - so `terminationStatus` can't distinguish it from a
                // real success. `isRunning` after a short grace period is the only reliable signal:
                // a real game launch keeps the process alive; this failure is always gone well before
                // 2 seconds. If it's already gone for any reason, don't strand the player on a launch
                // that silently did nothing - fall through and run the exe directly instead, against
                // this exact same wrapper's own prefix, borrowing its own wine binary (the identical
                // mechanism `preferWrapperEngine` already uses below for a borrowed wrapper engine).
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning {
                    return process
                }
                DiagnosticsLog.log("Sikarugir wrapper CLI exited fast for \(baseName) (status \(process.terminationStatus)) - falling back to a direct launch against \(appPath).")
            }

            let wrapperWine = appPath + "/Contents/SharedSupport/wine/bin/wine"
            guard FileManager.default.isExecutableFile(atPath: wrapperWine) else {
                // Neither the launcher CLI nor a direct wine binary is where expected - opening the
                // app is still better than a hard failure, even though it can't target the right
                // exe this way.
                try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
                return nil
            }
            let libraryPath = "\(appPath)/Contents/Frameworks:\(appPath)/Contents/SharedSupport/wine/lib"
            return try runDirect(
                exePath: exePath, bottle: bottle, arguments: arguments, config: config,
                wineBinary: wrapperWine, libraryPath: libraryPath, baseName: baseName, timestamp: timestamp
            )
        }

        let wrapperEngine = preferWrapperEngine ? SikarugirEngine.anyWrapperEngine() : nil
        let wineBinary = try wrapperEngine?.wineBinary ?? SikarugirEngine.wineBinaryPath(engineName: engineName ?? config.engineName)
        if !bottle.isReadOnly {
            try BottleManager.shared.ensureInitialized(bottle, wineBinary: wineBinary)
        }

        // Playdock's own bottle (every custom game, and Steam) never had this same reliable path -
        // only a bottle discovered inside a *separately built* Sikarugir wrapper did.
        // `ConfigureShellBuilder` gives it the identical shape Configure itself looks for (confirmed
        // against Configure's own binary strings and a real downloaded copy of Sikarugir's public
        // wrapper template - see its own doc comment), built automatically from a file Playdock
        // already downloads during first-launch setup - no manual step for anyone, and no risk to a
        // launch that already worked: any failure here just falls through to the exact same
        // CLI/direct-wine chain used before this existed. Deliberately placed *after*
        // `ensureInitialized` just above - Configure driving a bottle that doesn't have a real,
        // wineboot-initialized prefix yet isn't a scenario worth risking.
        if !bottle.isReadOnly, let shellPath = ConfigureShellBuilder.shellAppPath(forLaunching: bottle, wineBinaryPath: wineBinary) {
            do {
                try await SikarugirConfigureLauncher.launch(exePath: exePath, wrapperAppPath: shellPath, driveCPath: bottle.driveCPath)
                return nil
            } catch {
                DiagnosticsLog.log("Configure-driven launch failed for \(baseName) in \(bottle.name): \(error.localizedDescription) - falling back.")
            }
        }

        let libraryPath: String
        if let wrapperEngine {
            // Must be paired with the *same* app's own lib/Frameworks - mixing a wrapper's wine
            // binary with ExeDock's own downloaded engine's shared libraries risks a broken,
            // version-mismatched mix.
            libraryPath = "\(wrapperEngine.frameworksDir):\(wrapperEngine.libDir)"
        } else {
            libraryPath = try SikarugirEngine.runtimeEnvironment(engineName: engineName ?? config.engineName)["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        }
        return try runDirect(
            exePath: exePath, bottle: bottle, arguments: arguments, config: config,
            wineBinary: wineBinary, libraryPath: libraryPath, baseName: baseName, timestamp: timestamp
        )
    }

    /// Runs an exe by invoking wine directly (no Sikarugir wrapper CLI involved) - shared by
    /// Playdock's own bottles, borrowed-wrapper-engine custom game launches, and now the
    /// fast-fail fallback for a wrapper bottle whose own CLI didn't come up.
    private static func runDirect(exePath: String, bottle: Bottle, arguments: [String], config: GameModeConfig, wineBinary: String, libraryPath: String, baseName: String, timestamp: String) throws -> Process {
        let logPath = (logsDir as NSString).appendingPathComponent("\(baseName)-\(timestamp)-direct.log")
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wineBinary)
        // `start /unix <path>` rather than passing the exe path straight to wine - captured live
        // from what Sikarugir's own Configure "Test Run" actually invokes (watched via `ps aux`
        // the instant it was clicked), not a guess. `start.exe` is wine's own real, documented
        // helper for launching a program from a host (unix-style) path, and does its own path
        // translation/launch setup that a bare `wine <path>` invocation skips.
        process.arguments = ["start", "/unix", exePath] + arguments
        // Matches what actually double-clicking an exe in Explorer does: run with the exe's own
        // folder as the working directory. A real, confirmed cause of custom games (Unreal Engine
        // titles especially, which often resolve their own Content/Saved folders relative to the
        // process's working directory, not just the exe's location) launching and immediately
        // quitting through ExeDock - without this, the wine process inherited ExeDock's own working
        // directory instead, which the game's own asset-loading code was never expecting.
        process.currentDirectoryURL = URL(fileURLWithPath: (exePath as NSString).deletingLastPathComponent)
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixPath
        if !libraryPath.isEmpty {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libraryPath
        }
        for (key, value) in config.environment { env[key] = value }
        process.environment = env
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }
}

/// Keeps `ExeRunner.logsDir` from growing without bound: every launch, wineboot, and winetricks
/// run creates a new log file there and nothing ever pruned them, so months of daily use quietly
/// piled up thousands of stale files (and made "Open Logs Folder" unusable). Retention is
/// newest-first over the per-run logs only - `diagnostics.log` is the app's own append-only
/// history and is deliberately never swept.
enum LaunchLogRetention {
    static func prune(keeping newest: Int = 300, in dir: String = ExeRunner.logsDir) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        var candidates: [(path: String, modified: Date)] = []
        for name in names where name.hasSuffix(".log") && name != "diagnostics.log" {
            let path = (dir as NSString).appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            candidates.append((path, modified))
        }
        guard candidates.count > newest else { return }
        candidates.sort { $0.modified > $1.modified }
        for stale in candidates.suffix(candidates.count - newest) {
            try? fm.removeItem(atPath: stale.path)
        }
        DiagnosticsLog.log("LaunchLogRetention: pruned \(candidates.count - newest) log file(s) beyond the newest \(newest)")
    }
}
