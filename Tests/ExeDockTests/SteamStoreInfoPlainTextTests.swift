import Testing
@testable import ExeDock

/// Plain-text conversion for Steam "About" HTML — same cases as XCTest would cover; this target
/// builds with Swift Testing because Command Line Tools here don't ship XCTest.
@Suite("SteamStoreInfoPlainTextTests")
struct SteamStoreInfoPlainTextTests {
    @Test func headingAndParagraphDoNotGlueWords() {
        let html = "<h2>Learning!</h2><p>Baldi's Basics</p>"
        let plain = SteamStoreInfo.plainText(fromHTML: html)
        #expect(!plain.contains("Learning!Baldi's"))
        #expect(plain.contains("Learning!"))
        #expect(plain.contains("Baldi's"))
    }

    @Test func brBecomesLineBreak() {
        let html = "Line one<br>Line two<br/>Line three"
        let plain = SteamStoreInfo.plainText(fromHTML: html)
        #expect(plain.contains("Line one\nLine two"))
        #expect(plain.contains("Line two\nLine three"))
    }

    @Test func decodesAmpAndNbsp() {
        let html = "Tom &amp; Jerry&nbsp;forever"
        let plain = SteamStoreInfo.plainText(fromHTML: html)
        #expect(plain == "Tom & Jerry forever")
    }
}
