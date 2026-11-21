import Foundation
import Testing
@testable import ExeDock

@Suite("Launch backends", .serialized)
struct LaunchBackendTests {
    private let storeKey = "com.exedock.launchBackends"

    @Test func wineGameDefaultsToPlaydockWine() {
        withCleanStore {
            let game = wineGame()
            #expect(LaunchBackendStore.backend(for: game) == .playdockWine)
        }
    }

    @Test func nativeGameDefaultsToNativeMac() {
        withCleanStore {
            let game = nativeGame()
            #expect(LaunchBackendStore.backend(for: game) == .nativeMac)
        }
    }

    @Test func storedBackendOverridesDefault() {
        withCleanStore {
            let game = wineGame()
            LaunchBackendStore.set(.steamPlay, for: game)
            #expect(LaunchBackendStore.backend(for: game) == .steamPlay)
        }
    }

    @Test func steamPlayIsAlwaysOffered() {
        withCleanStore {
            #expect(LaunchBackendStore.available(for: wineGame()).contains(.steamPlay))
            #expect(LaunchBackendStore.available(for: nativeGame()).contains(.steamPlay))
            #expect(LaunchBackendStore.available(for: wineGame()).first == .playdockWine)
        }
    }

    @Test func steamPlayURLAsksSteamToRunTheGame() {
        #expect(SteamPlaySupport.runURL(appID: "220")?.absoluteString == "steam://rungameid/220")
    }

    @Test func windowsExecutableUsesIconPathWhenPresent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("playdock-steamplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("hl2.exe")
        try Data([0x4D, 0x5A]).write(to: exe)
        let game = SteamGame(
            appID: "220", name: "Half-Life 2", installDir: "Half-Life 2",
            installFolderPath: dir.path, iconExePath: exe.path,
            sizeOnDisk: 1, buildID: "1", lastUpdated: Date(), source: .wineBottle
        )
        #expect(SteamPlaySupport.windowsExecutable(for: game) == exe.path)
    }

    @Test func windowsExecutableFindsExeInInstallFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("playdock-steamplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("game.exe")
        try Data(repeating: 1, count: 64).write(to: exe)
        let game = SteamGame(
            appID: "220", name: "Half-Life 2", installDir: "Half-Life 2",
            installFolderPath: dir.path, iconExePath: nil,
            sizeOnDisk: 1, buildID: "1", lastUpdated: Date(), source: .wineBottle
        )
        #expect(SteamPlaySupport.windowsExecutable(for: game) == exe.path)
    }

    @Test func steamPlaySummaryIsNotProton() {
        #expect(LaunchBackend.steamPlay.summary.contains("NotProton"))
        #expect(LaunchBackend.steamPlay.summary.contains("Mac Steam"))
        #expect(!LaunchBackend.steamPlay.summary.localizedCaseInsensitiveContains("crossover"))
    }

    @Test func windowsGameWithoutNotProtonDoesNotUseMacSteam() {
        #expect(!SteamPlaySupport.usesMacSteamClient(for: wineGame(), steamPlayEnabled: false))
    }

    @Test func windowsGameWithNotProtonUsesMacSteam() {
        #expect(SteamPlaySupport.usesMacSteamClient(for: wineGame(), steamPlayEnabled: true))
    }

    @Test func macNativeGameWithoutWindowsExeUsesMacSteam() {
        #expect(SteamPlaySupport.usesMacSteamClient(for: nativeGame(), steamPlayEnabled: false))
    }

    @Test func steamPlayInstallURLAsksSteamToInstall() {
        #expect(SteamPlaySupport.installURL(appID: "12210")?.absoluteString == "steam://install/12210")
    }

    @Test func notProtonCaskIsUpstream() {
        #expect(SteamPlaySupport.brewCask == "notprotonnot/notproton/notproton")
        #expect(SteamPlaySupport.notProtonAppPath == "/Applications/NotProton.app")
    }

    private func wineGame() -> SteamGame {
        SteamGame(
            appID: "220", name: "Half-Life 2", installDir: "Half-Life 2",
            installFolderPath: "/tmp/steamapps/common/Half-Life 2", iconExePath: nil,
            sizeOnDisk: 1, buildID: "1", lastUpdated: Date(), source: .wineBottle
        )
    }

    private func nativeGame() -> SteamGame {
        SteamGame(
            appID: "MAC-105600", name: "Terraria", installDir: "Terraria",
            installFolderPath: "/tmp/steamapps/common/Terraria", iconExePath: nil,
            sizeOnDisk: 1, buildID: "1", lastUpdated: Date(), source: .nativeMac
        )
    }

    private func withCleanStore(_ body: () -> Void) {
        let previous = UserDefaults.standard.dictionary(forKey: storeKey)
        UserDefaults.standard.removeObject(forKey: storeKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: storeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storeKey)
            }
        }
        body()
    }
}
