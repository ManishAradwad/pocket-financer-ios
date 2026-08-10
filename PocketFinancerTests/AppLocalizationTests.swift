import Foundation
import XCTest

@testable import PocketFinancer

final class AppLocalizationTests: XCTestCase {
    func testAppDeclaresUSEnglishAsItsDevelopmentLocalization() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en-US")
    }
}
