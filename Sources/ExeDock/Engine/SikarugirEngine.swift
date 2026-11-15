import Foundation

enum EngineError: Error, LocalizedError {
    case noEngineFound
    case extractionFailed(String)
    case missingSharedLibraries

    var errorDescription: String? {
        switch self {
        case .noEngineFound:
            return "No Sikarugir Wine engine was found. Open Sikarugir Creator once and let it download an engine, then relaunch ExeDock."
        case .extractionFailed(let detail):
            return "Failed to prepare the Sikarugir engine: \(detail)"
        case .missingSharedLibraries:
            return "Couldn't find the shared runtime libraries a Sikarugir wrapper app normally provides (like libinotify). Build at least one wrapper app with Sikarugir Creator first, then relaunch ExeDock."
        }
    }
}

/// Locates and reuses the Wine engine Sikarugir Creator already downloaded, extracting a private
/// working copy into ExeDock's own support directory. Every access to Sikarugir's own files here is
/// read-only (list a directory, read a tarball) - nothing under Sikarugir's folders is ever written.
enum SikarugirEngine {
    static let sikarugirEnginesDir = ("~/Library/Application Support/Sikarugir/Engines" as NSString).expandingTildeInPath
    /// `PLAYDOCK_SUPPORT_DIR` / `EXEDOCK_SUPPORT_DIR` isolate support data (bottles, cached engine)
    /// for internal verification only — normal launches never set these.
    static var exeDockSupportDir: String {
        if let override = ProcessInfo.processInfo.environment["PLAYDOCK_SUPPORT_DIR"]
            ?? ProcessInfo.processInfo.environment["EXEDOCK_SUPPORT_DIR"],
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return ("~/Library/Application Support/ExeDock" as NSString).expandingTildeInPath
    }

    /// A file inside the support directory. Every Playdock-owned cache and library file goes
    /// through here so a fresh-install machine (`PLAYDOCK_SUPPORT_DIR`) cannot write the real one.
    static func supportFile(_ relativePath: String) -> String {
        (exeDockSupportDir as NSString).appendingPathComponent(relativePath)
    }
    /// Where a build of ExeDock before per-engine caching always extracted to - still checked first
    /// so an existing install doesn't silently re-extract (and re-download nothing, but re-pay the
    /// tar cost) something it already has ready to go.
    static let legacyExtractedEngineDir = (exeDockSupportDir as NSString).appendingPathComponent("Engine")
    static let exeDockFrameworksDir = (exeDockSupportDir as NSString).appendingPathComponent("Frameworks")
    /// A cached, working copy of Sikarugir's own blank Configure.app (see
    /// `SikarugirWrapperTemplateRemote`'s doc comment for where this comes from) - `ConfigureShellBuilder`
    /// copies from here to give each of Playdock's own bottles the same Configure-driven launch path
    /// a real Sikarugir Creator wrapper already has.
    static let exeDockConfigureTemplatePath = (exeDockSupportDir as NSString).appendingPathComponent("ConfigureTemplate.app")

    /// Each named engine gets its own extraction cache (`Engine-<name>`) so ExeDock can hold more
    /// than one ready at once - needed both for the engine picker (switching without re-extracting
    /// every time) and for the launch fallback ladder trying an alternate engine after a failure.
    static func extractedEngineDir(named engineName: String) -> String {
        let safeName = engineName.replacingOccurrences(of: "/", with: "-")
        return (exeDockSupportDir as NSString).appendingPathComponent("Engine-\(safeName)")
    }

    // Setup can be triggered from more than one place at once (the launch-time SetupCoordinator
    // preparing the Default bottle while the user clicks Install & Run Steam for the Steam bottle).
    // Both paths extract into the same shared Engine/Frameworks directories, so this serializes
    // them - without it, two concurrent extractions can race and leave a half-written engine behind,
    // which is exactly what produced a wineboot failure logged with the Steam bottle previously.
    private static let prepLock = NSLock()

    /// Path to the `wine` binary ExeDock should use to launch executables. Pass a specific
    /// `engineName` (one of `availableEngineNames()`) to use that engine; leave it `nil` to get
    /// whatever's already cached, or the recommended engine if nothing's cached yet.
    static func wineBinaryPath(engineName: String? = nil) throws -> String {
        prepLock.lock()
        defer { prepLock.unlock() }
        let fm = FileManager.default
        let dir = try engineDirectory(engineName: engineName, extractIfNeeded: true)
        let wine = (dir as NSString).appendingPathComponent("bin/wine")
        if fm.isExecutableFile(atPath: wine) {
            return wine
        }
        if let wrapperWine = try? findWrapperWineBinary() {
            return wrapperWine
        }
        throw EngineError.noEngineFound
    }

    /// Picks (and, if `extractIfNeeded`, extracts) the directory a given engine request resolves
    /// to. Both `wineBinaryPath` and `runtimeEnvironment` go through this so they can never disagree
    /// about which engine a launch actually used - callers must already hold `prepLock`.
    private static func engineDirectory(engineName: String?, extractIfNeeded: Bool) throws -> String {
        let fm = FileManager.default

        // No specific engine requested and something's already extracted (from this build or an
        // older one) - the cheap, common-case path.
        if engineName == nil {
            let legacyWine = (legacyExtractedEngineDir as NSString).appendingPathComponent("bin/wine")
            if fm.isExecutableFile(atPath: legacyWine) {
                return legacyExtractedEngineDir
            }
        }

        if let chosenName = engineName ?? recommendedEngineName() {
            let dir = extractedEngineDir(named: chosenName)
            let cachedWine = (dir as NSString).appendingPathComponent("bin/wine")
            if fm.isExecutableFile(atPath: cachedWine) {
                return dir
            }
            if extractIfNeeded, let tarballPath = tarballPath(for: chosenName) {
                try extractEngine(tarball: tarballPath, into: dir)
                if fm.isExecutableFile(atPath: cachedWine) {
                    return dir
                }
            }
        }

        return legacyExtractedEngineDir
    }

    /// Names of every Wine engine Sikarugir has already downloaded (for the Game Mode engine
    /// picker), newest-looking first - the same folder Sikarugir Creator itself downloads into, so
    /// this list can never drift from what Sikarugir Creator shows.
    static func availableEngineNames() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: sikarugirEnginesDir) else { return [] }
        return items.filter { $0.hasSuffix(".tar.xz") }
            .map { $0.replacingOccurrences(of: ".tar.xz", with: "") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }

    /// The engine ExeDock suggests by default: prefers the in-house "Sikarugir" build over a
    /// third-party CX one, and among same-family names prefers the highest version (natural/numeric
    /// sort, so "Sikarugir-10.0" ranks above "Sikarugir-9.0" rather than sorting as text).
    static func recommendedEngineName() -> String? {
        let names = availableEngineNames() // already newest-first
        return names.first { $0.localizedCaseInsensitiveContains("sikarugir") } ?? names.first
    }

    /// True if Sikarugir Creator has already downloaded at least one engine tarball - a purely
    /// local check (no network) used by the launch-time setup flow to know whether it can just
    /// extract what's already on disk.
    static func hasDownloadedTarball() -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: sikarugirEnginesDir) else { return false }
        return items.contains { $0.hasSuffix(".tar.xz") }
    }

    /// True if ExeDock has (or can produce) a ready-to-use engine, from any source: an already
    /// extracted copy, a tarball it will extract as a side effect of this call, or falling back to
    /// a wrapper's bundled wine.
    static func isEngineAvailable() -> Bool {
        (try? wineBinaryPath()) != nil
    }

    /// True if some engine is already extracted and ready to use - unlike `isEngineAvailable()`,
    /// this never extracts anything as a side effect. Used by setup to decide whether it's safe to
    /// silently proceed, or whether (on a genuinely fresh install with more than one engine
    /// downloaded) it should ask the user which one to use before auto-picking one for them.
    static func hasReadyCachedEngine() -> Bool {
        let fm = FileManager.default
        let legacyWine = (legacyExtractedEngineDir as NSString).appendingPathComponent("bin/wine")
        if fm.isExecutableFile(atPath: legacyWine) {
            return true
        }
        return availableEngineNames().contains { name in
            fm.isExecutableFile(atPath: (extractedEngineDir(named: name) as NSString).appendingPathComponent("bin/wine"))
        }
    }

    /// Environment variables that must be set on every wine/wineserver/wineboot process ExeDock
    /// launches. The engine tarball only contains wine's own binaries - the ~50 shared macOS
    /// libraries wine needs at runtime (libinotify, libgnutls, GStreamer, MoltenVK, …) are NOT part
    /// of it. Sikarugir Creator bundles those into every wrapper app's own Contents/Frameworks at
    /// wrapper-creation time instead, so ExeDock copies (read-only source, never edits) that same
    /// payload from an existing wrapper app once, and points DYLD_FALLBACK_LIBRARY_PATH at it.
    static func runtimeEnvironment(engineName: String? = nil) throws -> [String: String] {
        let frameworks = try ensureFrameworksAvailable()
        prepLock.lock()
        let dir = (try? engineDirectory(engineName: engineName, extractIfNeeded: false)) ?? legacyExtractedEngineDir
        prepLock.unlock()
        let engineLib = (dir as NSString).appendingPathComponent("lib")
        return ["DYLD_FALLBACK_LIBRARY_PATH": "\(frameworks):\(engineLib)"]
    }

    static let frameworksReadyMarkerPath = (exeDockFrameworksDir as NSString).appendingPathComponent(".complete")

    /// Marks ExeDock's own copied Frameworks as ready without doing the copy itself - used by
    /// `SikarugirWrapperTemplateRemote` once it has finished moving a downloaded copy into place,
    /// so `ensureFrameworksAvailable`'s own cheap marker-file check picks it up from then on exactly
    /// like a copy sourced from a local wrapper app.
    static func markFrameworksReady() {
        try? FileManager.default.createDirectory(atPath: exeDockSupportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: frameworksReadyMarkerPath, contents: nil)
    }

    @discardableResult
    static func ensureFrameworksAvailable() throws -> String {
        prepLock.lock()
        defer { prepLock.unlock() }
        let fm = FileManager.default
        // Best-effort and independent of the frameworks marker below on purpose: an install that
        // already had its Frameworks copy set up *before* `ConfigureShellBuilder` existed would
        // otherwise never take this path again and so never get a Configure template cached at all
        // - this same cheap check just runs every time instead, a no-op once it's actually there.
        if !fm.fileExists(atPath: exeDockConfigureTemplatePath), let sourceConfigure = try? findWrapperConfigureApp() {
            try? fm.createDirectory(atPath: exeDockSupportDir, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: sourceConfigure, toPath: exeDockConfigureTemplatePath)
        }

        if fm.fileExists(atPath: frameworksReadyMarkerPath) {
            return exeDockFrameworksDir
        }

        guard let sourceFrameworks = try? findWrapperFrameworksDir() else {
            throw EngineError.missingSharedLibraries
        }

        try? fm.createDirectory(atPath: exeDockSupportDir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: exeDockFrameworksDir)

        // `-c` clonefiles on APFS (instant, copy-on-write) and transparently falls back to a real
        // copy elsewhere - either way this never touches the source wrapper app.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-Rc", sourceFrameworks, exeDockFrameworksDir]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: exeDockFrameworksDir) else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "cp exited with status \(process.terminationStatus)"
            throw EngineError.extractionFailed(message)
        }

        fm.createFile(atPath: frameworksReadyMarkerPath, contents: nil)
        return exeDockFrameworksDir
    }

    private static func findWrapperFrameworksDir() throws -> String {
        let fm = FileManager.default
        let root = ("~/Applications/Sikarugir" as NSString).expandingTildeInPath
        guard let apps = try? fm.contentsOfDirectory(atPath: root) else { throw EngineError.missingSharedLibraries }
        for app in apps where app.hasSuffix(".app") {
            let frameworksPath = (root as NSString).appendingPathComponent(app) + "/Contents/Frameworks"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: frameworksPath, isDirectory: &isDir), isDir.boolValue {
                return frameworksPath
            }
        }
        throw EngineError.missingSharedLibraries
    }

    /// A real, working Configure.app from any already-installed Sikarugir wrapper - read-only
    /// source, only ever copied from, exactly like `findWrapperFrameworksDir` above. Feeds
    /// `ConfigureShellBuilder`'s local-copy fast path (see `ensureFrameworksAvailable`'s own call
    /// site) so an existing user who already has a wrapper on this Mac gets Playdock's own bottles
    /// upgraded to the same reliable launch path too, not only a brand-new install going through
    /// `SikarugirWrapperTemplateRemote`'s network download.
    private static func findWrapperConfigureApp() throws -> String {
        let fm = FileManager.default
        let root = ("~/Applications/Sikarugir" as NSString).expandingTildeInPath
        guard let apps = try? fm.contentsOfDirectory(atPath: root) else { throw EngineError.missingSharedLibraries }
        for app in apps where app.hasSuffix(".app") {
            let configurePath = (root as NSString).appendingPathComponent(app) + "/Contents/Configure.app"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: configurePath, isDirectory: &isDir), isDir.boolValue {
                return configurePath
            }
        }
        throw EngineError.missingSharedLibraries
    }

    /// Path to a specific engine's tarball on disk, if Sikarugir Creator has downloaded one by that
    /// exact name (as returned by `availableEngineNames()`).
    private static func tarballPath(for engineName: String) -> String? {
        let candidate = (sikarugirEnginesDir as NSString).appendingPathComponent("\(engineName).tar.xz")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    private static func extractEngine(tarball: String, into destinationDir: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: exeDockSupportDir, withIntermediateDirectories: true)

        // Extract to a staging dir first so a failed extraction never leaves a broken "cached" engine.
        let stagingDir = (exeDockSupportDir as NSString).appendingPathComponent("Engine.staging")
        try? fm.removeItem(atPath: stagingDir)
        try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xJf", tarball, "-C", stagingDir]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "tar exited with status \(process.terminationStatus)"
            try? fm.removeItem(atPath: stagingDir)
            throw EngineError.extractionFailed(message)
        }

        // Sikarugir engine tarballs contain a single top-level bundle dir (e.g. "wswine.bundle/")
        // with bin/lib/share inside. Normalize so extractedEngineDir/bin/wine always exists.
        var sourceDir = stagingDir
        if let entries = try? fm.contentsOfDirectory(atPath: stagingDir), entries.count == 1,
           let only = entries.first {
            let onlyPath = (stagingDir as NSString).appendingPathComponent(only)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: onlyPath, isDirectory: &isDir), isDir.boolValue {
                sourceDir = onlyPath
            }
        }

        try? fm.removeItem(atPath: destinationDir)
        try fm.moveItem(atPath: sourceDir, toPath: destinationDir)
        try? fm.removeItem(atPath: stagingDir)
    }

    /// Last-resort fallback: read (never write) the wine binary bundled inside an already-installed
    /// Sikarugir wrapper app, if no engine tarball is cached yet.
    private static func findWrapperWineBinary() throws -> String {
        let fm = FileManager.default
        let root = ("~/Applications/Sikarugir" as NSString).expandingTildeInPath
        guard let apps = try? fm.contentsOfDirectory(atPath: root) else { throw EngineError.noEngineFound }
        for app in apps where app.hasSuffix(".app") {
            let winePath = (root as NSString).appendingPathComponent(app) + "/Contents/SharedSupport/wine/bin/wine"
            if fm.isExecutableFile(atPath: winePath) {
                return winePath
            }
        }
        throw EngineError.noEngineFound
    }

    /// The wine binary (and its matching `lib`/`Frameworks` directories, from that *same* app - a
    /// wine binary paired with a mismatched engine's own shared libraries risks a broken/
    /// incompatible mix) bundled inside any already-installed Sikarugir wrapper app - not tied to a
    /// specific bottle, just a real, already-working Sikarugir engine build on this Mac. Used for
    /// custom game launches instead of ExeDock's own separately-downloaded engine - a real
    /// Sikarugir engine build is guaranteed to work against a Sikarugir-created bottle.
    static func anyWrapperEngine() -> (wineBinary: String, libDir: String, frameworksDir: String)? {
        let fm = FileManager.default
        let root = ("~/Applications/Sikarugir" as NSString).expandingTildeInPath
        guard let apps = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for app in apps where app.hasSuffix(".app") {
            let appPath = (root as NSString).appendingPathComponent(app)
            let wineBinary = appPath + "/Contents/SharedSupport/wine/bin/wine"
            if fm.isExecutableFile(atPath: wineBinary) {
                return (
                    wineBinary: wineBinary,
                    libDir: appPath + "/Contents/SharedSupport/wine/lib",
                    frameworksDir: appPath + "/Contents/Frameworks"
                )
            }
        }
        return nil
    }
}
