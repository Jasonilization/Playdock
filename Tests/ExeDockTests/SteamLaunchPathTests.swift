import Foundation
import Testing
@testable import ExeDock

/// Pins the Steam.exe launch argv and the gates that used to let a preview card or a missing
/// exe look like a successful game start.
@Suite("Steam launch path")
struct SteamLaunchPathTests {
    @Test func wineStartKeepsArgumentsAfterUnixPath() {
        let exe = "/tmp/Program Files (x86)/Steam/Steam.exe"
        let args = ExeRunner.wineStartArguments(exePath: exe, extra: ["-applaunch", "220"])
        #expect(args == ["start", "/unix", exe, "-applaunch", "220"])
    }

    @Test func gameModeConfigExportsGraphicsEnv() {
        var config = GameModeConfig()
        config.d3dMetal = true
        config.dxvk = false
        config.dxmt = false
        config.moltenVKCX = true
        config.fastSync = true
        #expect(config.environment["D3DMETAL"] == "1")
        #expect(config.environment["DXVK"] == "0")
        #expect(config.environment["DXMT"] == "0")
        #expect(config.environment["MOLTENVKCX"] == "1")
        #expect(config.environment["WINEESYNC"] == "1")
        #expect(config.environment["WINEMSYNC"] == "1")
    }

    @Test func previewSampleIsNotASteamExeLaunch() {
        let sample = SteamGame(
            appID: "SAMPLE-367520", name: "Hollow Knight", installDir: "Hollow Knight",
            installFolderPath: "", iconExePath: nil, sizeOnDisk: 1, buildID: "sample",
            lastUpdated: Date()
        )
        #expect(sample.isPreviewSample)
        #expect(sample.wineSteamLaunchArguments == nil)
        #expect(sample.metadataAppID == "367520")
    }

    @Test func installedWineGameUsesApplaunchWithRealAppID() {
        let game = SteamGame(
            appID: "220", name: "Half-Life 2", installDir: "Half-Life 2",
            installFolderPath: "/tmp/steamapps/common/Half-Life 2", iconExePath: nil,
            sizeOnDisk: 1, buildID: "1", lastUpdated: Date(), source: .wineBottle
        )
        #expect(game.wineSteamLaunchArguments == ["-applaunch", "220"])
        #expect(!game.isPreviewSample)
    }

    @Test func nativeMacGameIsNotSentThroughSteamExe() {
        let game = SteamGame(
            appID: "MAC-105600", name: "Terraria", installDir: "Terraria",
            installFolderPath: "/tmp/steamapps/common/Terraria", iconExePath: nil,
            sizeOnDisk: 1, buildID: "1", lastUpdated: Date(), source: .nativeMac
        )
        #expect(game.wineSteamLaunchArguments == nil)
    }

    @Test func missingExeIsAnErrorNotSuccess() async {
        let missing = "/tmp/playdock-no-such-steam-\(UUID().uuidString)/Steam.exe"
        let bottle = Bottle(name: "Probe", prefixPath: "/tmp/playdock-no-such-prefix", kind: .owned)
        do {
            _ = try await ExeRunner.run(exePath: missing, in: bottle)
            Issue.record("missing Steam.exe must not be reported as a successful launch")
        } catch let runError as ExeRunner.RunError {
            #expect(runError == .missingExecutable(missing))
        } catch {
            Issue.record("expected ExeRunner.RunError, got \(error)")
        }
    }
}
