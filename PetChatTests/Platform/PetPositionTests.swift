import AppKit
import XCTest
@testable import PetChat

final class PetPositionTests: XCTestCase {
    func testClampsPetAtEveryVisibleScreenEdge() {
        let visible = CGRect(x: -1200, y: 40, width: 1200, height: 800)
        for (point, expected) in [
            (CGPoint(x: -1300, y: 200), CGPoint(x: -1200, y: 200)),
            (CGPoint(x: 30, y: 200), CGPoint(x: -64, y: 200)),
            (CGPoint(x: -500, y: -10), CGPoint(x: -500, y: 40)),
            (CGPoint(x: -500, y: 900), CGPoint(x: -500, y: 776))
        ] {
            XCTAssertEqual(PetPosition.clamp(point, size: CGSize(width: 64, height: 64), to: visible), expected)
        }
    }

    func testMissingSelectedDisplayRecoversToFirstAvailableDisplay() {
        let displays = [PetDisplay(id: 2, visibleFrame: CGRect(x: 100, y: 40, width: 1000, height: 700))]
        let position = PetPosition.resolve(displayID: 99, positions: [99: CGPoint(x: -800, y: 90)], displays: displays)
        XCTAssertEqual(position?.displayID, 2)
        XCTAssertEqual(position?.origin, CGPoint(x: 1020, y: 56))
    }

    func testChatStaysOnScreenNearPetAtAllCorners() {
        let frame = CGRect(x: -1000, y: 40, width: 1000, height: 700)
        for point in [CGPoint(x: -1000, y: 40), CGPoint(x: -64, y: 40),
                      CGPoint(x: -1000, y: 676), CGPoint(x: -64, y: 676)] {
            let chat = PetPosition.chatFrame(near: point, visibleFrame: frame)
            XCTAssertEqual(chat.size, CGSize(width: 440, height: 530))
            XCTAssertTrue(frame.contains(chat))
        }
    }
}
