import AppKit
import ScreenCaptureKit
import XCTest
@testable import PetChat

@MainActor
final class RegionCaptureTests: XCTestCase {
    func testCancellingSelectionClosesOverlaysWithoutCapturing() async throws {
        let pending = Task { await RegionSelectionOverlay.selectRegion() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(NSApp.windows.contains { $0.isVisible && $0.contentView is RegionSelectionOverlay })
        pending.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let remainsVisible = NSApp.windows.contains { $0.isVisible && $0.contentView is RegionSelectionOverlay }
        // Always close the test overlay, including on the RED run.
        if remainsVisible {
            for window in NSApp.windows { (window.contentView as? RegionSelectionOverlay)?.cancelOperation(nil) }
        }
        let result = await pending.value
        XCTAssertNil(result)
        XCTAssertFalse(remainsVisible)
    }

    func testRetinaUsesLogicalTopLeftSourceRectAndScalesOnlyOutput() throws {
        let selection = RegionSelection(displayID: 1,
            displayFrame: CGRect(x: -1440, y: -200, width: 1440, height: 900),
            rect: CGRect(x: -1400, y: 500, width: 100, height: 50))
        let config = try RegionCaptureController.configuration(for: selection, scale: 2)
        XCTAssertEqual(config.sourceRect, CGRect(x: 40, y: 150, width: 100, height: 50))
        XCTAssertEqual(config.width, 200)
        XCTAssertEqual(config.height, 100)
        XCTAssertFalse(config.showsCursor)
    }

    func testSelectionRejectsEmptyNonfiniteAndOutsideSelectedDisplay() {
        let frame = CGRect(x: 1000, y: -900, width: 1000, height: 900)
        for rect in [CGRect.zero, CGRect(x: 900, y: -800, width: 200, height: 50),
                     CGRect(x: 1100, y: -800, width: 950, height: 50),
                     CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)] {
            XCTAssertThrowsError(try RegionCaptureController.configuration(
                for: RegionSelection(displayID: 2, displayFrame: frame, rect: rect), scale: 1))
        }
    }

    func testDeniedPermissionDoesNotSelectOrReadPixels() async {
        let capture = RegionCaptureController(permission: { false }, select: {
            XCTFail("Selected after denied permission"); return nil
        }, screenshot: { _ in XCTFail("Read pixels after denied permission"); return Data() })
        do { _ = try await capture.captureRegion(); XCTFail("Expected permission error") }
        catch { XCTAssertEqual(error as? RegionCaptureController.Error, .permissionDenied) }
    }

    func testEscapeCancelsOverlayWithoutReadingPixels() async throws {
        let overlay = RegionSelectionOverlay(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let capture = RegionCaptureController(permission: { true }, select: {
            await withCheckedContinuation { continuation in
                overlay.onSelection = { rect in
                    XCTAssertNil(rect)
                    continuation.resume(returning: nil)
                }
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53)!
                overlay.keyDown(with: escape)
            }
        }, screenshot: { _ in XCTFail("Read pixels after Escape"); return Data() })
        let result = try await capture.captureRegion()
        XCTAssertNil(result)
    }

    func testOverlayReverseDragClampsToDisplayBounds() throws {
        let overlay = RegionSelectionOverlay(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var selected: CGRect?
        overlay.onSelection = { selected = $0 }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        overlay.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 90, y: 80)))
        overlay.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: -20, y: 20)))
        XCTAssertEqual(selected, CGRect(x: 0, y: 20, width: 90, height: 60))
    }

    func testEmptySelectionFailsBeforeReadingPixels() async {
        let capture = RegionCaptureController(permission: { true }, select: {
            RegionSelection(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rect: .zero)
        }, screenshot: { _ in XCTFail("Read pixels for empty selection"); return Data() })
        do { _ = try await capture.captureRegion(); XCTFail("Expected invalid selection") }
        catch { XCTAssertEqual(error as? RegionCaptureController.Error, .invalidSelection) }
    }

    func testSelectionUsesSelectedDisplayBottomLeftToTopLeftConversion() throws {
        let selection = RegionSelection(displayID: 2,
            displayFrame: CGRect(x: 1920, y: -1080, width: 1920, height: 1080),
            rect: CGRect(x: 2000, y: -1000, width: 200, height: 100))
        let config = try RegionCaptureController.configuration(for: selection, scale: 1)
        XCTAssertEqual(config.sourceRect, CGRect(x: 80, y: 900, width: 200, height: 100))
        XCTAssertEqual(config.width, 200)
    }
}
