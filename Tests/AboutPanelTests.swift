import XCTest
@testable import FjarrConnect

final class AboutPanelTests: XCTestCase {
    func testCreditsNameDanielNylanderAndLinkTheRepository() throws {
        let bundle = localizedAppBundle
        let credits = AboutPanel.credits(bundle: bundle)
        XCTAssertTrue(credits.string.contains("Daniel Nylander"))
        let repository = bundle.localizedString(forKey: "about.repository", value: nil, table: nil)
        let range = try XCTUnwrap(credits.string.range(of: repository))
        let location = credits.string.distance(from: credits.string.startIndex, to: range.lowerBound)
        XCTAssertEqual(credits.attribute(.link, at: location, effectiveRange: nil) as? URL, AboutPanel.repositoryURL)
        let paragraphStyle = try XCTUnwrap(credits.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraphStyle.alignment, .center)
    }

    private var localizedAppBundle: Bundle {
        guard Bundle.main.bundleIdentifier != "se.fjarrconnect.app" else { return .main }
        let appURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let bundle = Bundle(url: appURL), bundle.bundleIdentifier == "se.fjarrconnect.app" else {
            return .main
        }
        return bundle
    }
}
