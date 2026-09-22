import XCTest
@testable import FjarrConnect

final class AboutPanelTests: XCTestCase {
    func testCreditsNameDanielNylanderAndLinkTheRepository() throws {
        let credits = AboutPanel.credits()
        XCTAssertTrue(credits.string.contains("Daniel Nylander"))
        let range = try XCTUnwrap(credits.string.range(of: NSLocalizedString("about.repository", comment: "")))
        let location = credits.string.distance(from: credits.string.startIndex, to: range.lowerBound)
        XCTAssertEqual(credits.attribute(.link, at: location, effectiveRange: nil) as? URL, AboutPanel.repositoryURL)
        let paragraphStyle = try XCTUnwrap(credits.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraphStyle.alignment, .center)
    }
}
