import Foundation
import Testing
@testable import ExeDock

/// Regression tests for the pure half of library discovery - the manifest/VDF parsing every
/// card in the app depends on. A silent regression here reads to a user as "all my games are
/// gone", so the parsing gates are pinned by fixtures copied from real Steam file shapes.
@Suite("SteamLibrary parsing")
struct SteamLibraryTests {
    /// A realistic `appmanifest_*.acf` with a `%@` StateFlags placeholder so each test can pin
    /// the exact gate behavior it cares about.
    private func manifest(stateFlags: String) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"220"
        \t"name"\t\t"Half-Life 2"
        \t"installdir"\t\t"Half-Life 2"
        \t"StateFlags"\t\t"\(stateFlags)"
        \t"SizeOnDisk"\t\t"6500000000"
        \t"buildid"\t\t"1234567"
        \t"LastUpdated"\t\t"1700000000"
        }
        """
    }

    @Test func parsesCoreFields() {
        let parsed = SteamLibrary.parseManifest(manifest(stateFlags: "4"))
        #expect(parsed?.appID == "220")
        #expect(parsed?.name == "Half-Life 2")
        #expect(parsed?.installDir == "Half-Life 2")
        #expect(parsed?.sizeOnDisk == 6_500_000_000)
        #expect(parsed?.buildID == "1234567")
        #expect(parsed?.lastUpdated == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func partiallyInstalledGameIsExcluded() {
        // bit 0x2 ("update required") without bit 0x4 ("fully installed") - a download in
        // progress whose folder already exists must not show up as launchable.
        #expect(SteamLibrary.parseManifest(manifest(stateFlags: "2")) == nil)
        #expect(SteamLibrary.parseManifest(manifest(stateFlags: "6")) != nil) // 0x2 | 0x4
        #expect(SteamLibrary.parseManifest(manifest(stateFlags: "4")) != nil)
    }

    @Test func missingOrUnparseableStateFlagsStaysIncluded() {
        #expect(SteamLibrary.parseManifest(manifest(stateFlags: "not-a-number")) != nil)
        let noFlags = """
        "AppState"
        {
        \t"appid"\t\t"220"
        \t"name"\t\t"Half-Life 2"
        \t"installdir"\t\t"Half-Life 2"
        }
        """
        #expect(SteamLibrary.parseManifest(noFlags) != nil)
    }

    @Test func sharedRuntimePayloadsAreIgnored() {
        let redistributables = """
        "AppState"
        {
        \t"appid"\t\t"228983"
        \t"name"\t\t"Steamworks Common Redistributables"
        \t"installdir"\t\t"Steamworks Shared"
        \t"StateFlags"\t\t"4"
        }
        """
        #expect(SteamLibrary.parseManifest(redistributables) == nil)
    }

    @Test func missingRequiredFieldsReturnNil() {
        let noName = """
        "AppState"
        {
        \t"appid"\t\t"220"
        \t"installdir"\t\t"Half-Life 2"
        }
        """
        #expect(SteamLibrary.parseManifest(noName) == nil)
    }

    @Test func optionalFieldsAreOptional() {
        let minimal = """
        "AppState"
        {
        \t"appid"\t\t"105600"
        \t"name"\t\t"Terraria"
        \t"installdir"\t\t"Terraria"
        }
        """
        let parsed = SteamLibrary.parseManifest(minimal)
        #expect(parsed?.appID == "105600")
        #expect(parsed?.sizeOnDisk == nil)
        #expect(parsed?.buildID == nil)
        #expect(parsed?.lastUpdated == nil)
    }

    @Test func libraryFoldersVDFYieldsSteamAppsPaths() {
        let vdf = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"/Users/gamer/Library/Application Support/Steam"
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"D:\\\\SteamGames"
        \t}
        }
        """
        let paths = SteamLibrary.libraryPaths(fromLibraryFoldersVDF: vdf)
        #expect(paths.count == 2)
        #expect(paths[0] == "/Users/gamer/Library/Application Support/Steam/steamapps")
        #expect(paths[1] == "D:/SteamGames/steamapps")
    }

    @Test func libraryFoldersVDFWithoutPathsYieldsNothing() {
        #expect(SteamLibrary.libraryPaths(fromLibraryFoldersVDF: "\"libraryfolders\"\n{\n}\n") == [])
    }
}
