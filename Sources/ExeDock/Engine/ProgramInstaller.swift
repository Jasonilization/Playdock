import Foundation

/// Copies a setup file into a new Windows 10 bottle, installs the usual runtime components,
/// and returns the path to open. The caller starts it so the vendor's own setup window appears.
enum ProgramInstaller {
    static func stage(setupPath: String, bottleID: String, bottleName: String, progress: @escaping (String) -> Void) async throws -> (path: String, bottle: Bottle) {
        let trimmed = bottleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileTitle = ((setupPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let displayName = trimmed.isEmpty ? fileTitle : trimmed
        let bottle = BottleManager.shared.gameBottle(id: bottleID, name: displayName)
        progress("Preparing the \(displayName) bottle…")
        let wineBinary = try SikarugirEngine.wineBinaryPath()
        try BottleManager.shared.ensureInitialized(bottle, wineBinary: wineBinary, scheduleRuntime: false)
        progress("Installing Visual C++, DirectX 9, and core fonts…")
        do {
            try await WinetricksRunner.runDefaultVerbs(in: bottle) { message in
                progress(message)
            }
        } catch {
            DiagnosticsLog.log("Installer runtime: \(error.localizedDescription)")
            progress("Runtime components didn't finish. Opening the installer…")
        }
        let fm = FileManager.default
        let dest = (bottle.driveCPath as NSString).appendingPathComponent((setupPath as NSString).lastPathComponent)
        if fm.fileExists(atPath: dest) { try? fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: setupPath, toPath: dest)
        return (dest, bottle)
    }
}
