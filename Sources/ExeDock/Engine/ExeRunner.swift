import Foundation
import AppKit

/// Launches Windows executables through the Sikarugir engine ExeDock reuses.
enum ExeRunner {
    /// The log from the launch that just started. The overlay tails this file.
    static var lastLogPath: String?

    /// Launch logs. A fresh-install machine keeps them inside its own support folder.
    static var logsDir: String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["PLAYDOCK_SUPPORT_DIR"] ?? env["EXEDOCK_SUPPORT_DIR"], !override.isEmpty {
            return SikarugirEngine.supportFile("Logs")
        }
        return ("~/Library/Logs/ExeDock" as NSString).expandingTildeInPath
    }

    enum RunError: Error, LocalizedError, Equatable {
        case missingExecutable(String)
        case spawnFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .missingExecutable(let path):
                return "Couldn't find \((path as NSString).lastPathComponent) to launch."
            case .spawnFailed(let code):
                return "The Wine loader didn't start (error \(code))."
            }
        }
    }

    /// What a running Sikarugir wrapper actually execs, read from its live process:
    /// `…/lib/wine/x86_64-unix/wine start /unix <exe> [args…]`.
    /// Extra args stay after the exe path so Steam's `-applaunch <id>` is not dropped.
    /// The installer is the exception: it is started as `wine SteamSetup.exe /S` in
    /// `SteamInstaller`, because `start` does not forward `/S`.
    static func wineStartArguments(exePath: String, extra: [String] = []) -> [String] {
        ["start", "/unix", exePath] + extra
    }

    /// `bin/wine` is the small stub. The process that actually starts the game is
    /// `lib/wine/x86_64-unix/wine`. Use that when it is next to the stub.
    static func unixLoaderPath(wineBinary: String) -> String {
        let binDir = (wineBinary as NSString).deletingLastPathComponent
        let root = (binDir as NSString).deletingLastPathComponent
        let unix = (root as NSString).appendingPathComponent("lib/wine/x86_64-unix/wine")
        if FileManager.default.isExecutableFile(atPath: unix) { return unix }
        return wineBinary
    }

    /// Environment CrossOver's `cxstart` sets before it execs the loader. `libraryPath` is the
    /// DYLD fallback list (Frameworks plus the engine's lib). Graphics keys from the game config
    /// are merged in by the caller.
    static func loaderEnvironment(wineBinary: String, prefixPath: String, libraryPath: String, extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONPATH")
        env["WINEPREFIX"] = prefixPath
        env["WINELOADER"] = wineBinary
        let beside = (wineBinary as NSString).deletingLastPathComponent
        var wineserver = (beside as NSString).appendingPathComponent("wineserver")
        if !FileManager.default.isExecutableFile(atPath: wineserver) {
            // The real loader lives in lib/wine/x86_64-unix. wineserver stays in bin/.
            wineserver = ((beside as NSString).appendingPathComponent("../../../bin/wineserver") as NSString).standardizingPath
        }
        if FileManager.default.isExecutableFile(atPath: wineserver) {
            env["WINESERVER"] = wineserver
        }
        // Do not set WINEDLLPATH. Wine finds its own DLLs next to this loader. Overriding
        // that path is what made wineboot exit before the game existed.
        if !libraryPath.isEmpty {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libraryPath
        }
        if let d3d = d3dSharedLibrary(libraryPath: libraryPath) {
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3d
        }
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["DOTNET_EnableWriteXorExecute"] = "0"
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// `libd3dshared.dylib` next to D3DMetal. CrossOver sets this whenever the file is present.
    private static func d3dSharedLibrary(libraryPath: String) -> String? {
        let fm = FileManager.default
        let relatives = [
            "renderer/d3dmetal/external/libd3dshared.dylib",
            "apple_gptk/external/libd3dshared.dylib",
        ]
        let roots = libraryPath.split(separator: ":").map(String.init) + [SikarugirEngine.exeDockFrameworksDir]
        for root in roots {
            for relative in relatives {
                let path = (root as NSString).appendingPathComponent(relative)
                if fm.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    /// `preferWrapperEngine`, when true and the target bottle isn't already a wrapper bottle,
    /// runs the exe with a real Sikarugir wrapper app's own bundled wine binary (see
    /// `SikarugirEngine.anyWrapperEngine`) instead of ExeDock's own engine. Used for older
    /// custom games that still live in a shared or wrapper prefix. A game with its own bottle
    /// uses ExeDock's engine, because that engine created the prefix.
    @discardableResult
    static func run(exePath: String, in bottle: Bottle, arguments: [String] = [], config: GameModeConfig = GameModeConfig(), engineName: String? = nil, preferWrapperEngine: Bool = false, extraEnv: [String: String] = [:]) async throws -> Process? {
        guard FileManager.default.fileExists(atPath: exePath) else {
            throw RunError.missingExecutable(exePath)
        }
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = (exePath as NSString).lastPathComponent

        // A game that already lives inside a Sikarugir wrapper's prefix runs with that
        // wrapper's wine, against that prefix. Configure is not opened: waiting for its Test
        // Run button cost about ten seconds and then failed. `wine start /unix` is the command
        // Test Run itself runs.
        if case .sikarugirWrapper(let appPath) = bottle.kind {
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
                wineBinary: wrapperWine, libraryPath: libraryPath, baseName: baseName, timestamp: timestamp,
                extraEnv: extraEnv
            )
        }

        let wrapperEngine = preferWrapperEngine ? SikarugirEngine.anyWrapperEngine() : nil
        let wineBinary = try wrapperEngine?.wineBinary ?? SikarugirEngine.wineBinaryPath(engineName: engineName ?? config.engineName)
        if !bottle.isReadOnly {
            try BottleManager.shared.ensureInitialized(bottle, wineBinary: wineBinary)
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
            wineBinary: wineBinary, libraryPath: libraryPath, baseName: baseName, timestamp: timestamp,
            extraEnv: extraEnv
        )
    }

    /// Runs an exe by invoking wine directly (no Sikarugir wrapper CLI involved) - shared by
    /// Playdock's own bottles, borrowed-wrapper-engine custom game launches, and now the
    /// fast-fail fallback for a wrapper bottle whose own CLI didn't come up.
    private static func runDirect(exePath: String, bottle: Bottle, arguments: [String], config: GameModeConfig, wineBinary: String, libraryPath: String, baseName: String, timestamp: String, extraEnv: [String: String] = [:]) throws -> Process? {
        let logPath = (logsDir as NSString).appendingPathComponent("\(baseName)-\(timestamp)-direct.log")
        lastLogPath = logPath
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let cwd = (exePath as NSString).deletingLastPathComponent
        let loader = unixLoaderPath(wineBinary: wineBinary)
        var extra = config.environment
        for (key, value) in extraEnv { extra[key] = value }
        let env = loaderEnvironment(
            wineBinary: loader,
            prefixPath: bottle.prefixPath,
            libraryPath: libraryPath,
            extra: extra
        )
        // Same argv as the wrapper's own launch. A new session so Playdock is not wrapped
        // around the game; wineserver keeps it after this spawn returns.
        try spawnLoader(
            wineBinary: loader,
            arguments: wineStartArguments(exePath: exePath, extra: arguments),
            environment: env,
            workingDirectory: cwd,
            logPath: logPath
        )
        return nil
    }

    /// `posix_spawn` with `POSIX_SPAWN_SETSID`, the same shape as CrossOver's `exec` of the loader:
    /// the new process is not in Playdock's process group, so closing a screen here does not
    /// signal the game.
    private static func spawnLoader(wineBinary: String, arguments: [String], environment: [String: String], workingDirectory: String, logPath: String) throws {
        let logFd = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        defer { if logFd >= 0 { close(logFd) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if logFd >= 0 {
            posix_spawn_file_actions_adddup2(&actions, logFd, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, logFd, STDERR_FILENO)
            posix_spawn_file_actions_addclose(&actions, logFd)
        }
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let argvStrings = [wineBinary] + arguments
        let argvC = argvStrings.map { strdup($0) }
        defer { argvC.forEach { free($0) } }
        var cArgv: [UnsafeMutablePointer<CChar>?] = argvC.map { UnsafeMutablePointer($0) }
        cArgv.append(nil)

        let envC = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { envC.forEach { free($0) } }
        var cEnv: [UnsafeMutablePointer<CChar>?] = envC.map { UnsafeMutablePointer($0) }
        cEnv.append(nil)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, wineBinary, &actions, &attr, &cArgv, &cEnv)
        guard rc == 0 else { throw RunError.spawnFailed(rc) }
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
