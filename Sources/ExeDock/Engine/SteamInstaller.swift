import Foundation

enum SteamInstallError: Error, LocalizedError {
    case downloadFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail): return "Couldn't download Steam: \(detail)"
        case .timedOut: return "The Steam installer didn't finish in time. Check the Steam bottle and try launching it manually."
        }
    }
}

/// Downloads Valve's official Steam bootstrapper and silently installs it into ExeDock's dedicated
/// "Steam" bottle, then hands back the path to launch. Purely user-triggered - no background network
/// activity happens unless this is explicitly called.
enum SteamInstaller {
    static let steamSetupURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    static var steamBottle: Bottle { BottleManager.shared.steamBottle }

    static var installedSteamExePath: String {
        (steamBottle.driveCPath as NSString).appendingPathComponent("Program Files (x86)/Steam/Steam.exe")
    }

    static var isSteamInstalled: Bool {
        FileManager.default.fileExists(atPath: installedSteamExePath)
    }

    static func installAndLaunch(progress: @escaping (String) -> Void, bytes: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> String {
        if isSteamInstalled {
            progress("Steam is already installed.")
            return installedSteamExePath
        }

        progress("Downloading Steam installer…")
        let setupPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("SteamSetup.exe")
        try? FileManager.default.removeItem(atPath: setupPath)
        try await ProgressDownload.save(from: steamSetupURL, to: setupPath, onBytes: bytes)

        progress("Preparing the Steam bottle…")
        let bottle = steamBottle
        let wineBinary = try SikarugirEngine.wineBinaryPath()
        try BottleManager.shared.ensureInitialized(bottle, wineBinary: wineBinary, scheduleRuntime: false)

        progress("Installing runtime components…")
        do {
            try await WinetricksRunner.runDefaultVerbs(in: bottle) { message in
                progress(message)
            }
        } catch {
            DiagnosticsLog.log("Steam bottle runtime components: \(error.localizedDescription)")
            progress("Runtime components didn't finish. Continuing with Steam…")
        }

        progress("Installing Steam…")
        try await Task.detached(priority: .userInitiated) {
            // The installer has to live inside the bottle. A temp-folder path is outside
            // drive_c, which is why a fresh install never actually unpacked Steam.
            let fm = FileManager.default
            let setupInBottle = (bottle.driveCPath as NSString).appendingPathComponent("SteamSetup.exe")
            if fm.fileExists(atPath: setupInBottle) {
                try? fm.removeItem(atPath: setupInBottle)
            }
            try fm.copyItem(atPath: setupPath, toPath: setupInBottle)

            try? fm.createDirectory(atPath: ExeRunner.logsDir, withIntermediateDirectories: true)
            let logPath = (ExeRunner.logsDir as NSString).appendingPathComponent("steam-install-\(Int(Date().timeIntervalSince1970)).log")
            fm.createFile(atPath: logPath, contents: nil)
            let logHandle = FileHandle(forWritingAtPath: logPath)

            // Silent setup must run synchronously under wine. `wine start /unix … /S` can return
            // while still doing nothing useful (start.exe never hands /S through), so invoke the
            // bootstrapper directly with cwd set to drive_c — same pattern as a real Explorer launch.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: wineBinary)
            process.arguments = [setupInBottle, "/S"]
            process.currentDirectoryURL = URL(fileURLWithPath: bottle.driveCPath)
            let libraryPath = (try? SikarugirEngine.runtimeEnvironment()["DYLD_FALLBACK_LIBRARY_PATH"]) ?? ""
            var env = ExeRunner.loaderEnvironment(
                wineBinary: wineBinary, prefixPath: bottle.prefixPath, libraryPath: libraryPath
            )
            env["WINEDEBUG"] = "-all"
            process.environment = env
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                DiagnosticsLog.log("Steam installer exited with status \(process.terminationStatus). Log: \(logPath)")
            }
        }.value

        // Steam's bootstrapper /S flag returns quickly while it keeps unpacking itself in the
        // background, so poll for Steam.exe rather than trusting the process exit code alone.
        progress("Finishing setup…")
        let deadline = Date().addingTimeInterval(900)
        while !isSteamInstalled {
            if Date() > deadline { throw SteamInstallError.timedOut }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        progress("Steam is ready.")
        return installedSteamExePath
    }
}
