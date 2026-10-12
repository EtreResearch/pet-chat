import AppKit
import ScreenCaptureKit

struct RegionSelection {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let rect: CGRect
}

@MainActor
final class RegionCaptureController {
    enum Error: LocalizedError, Equatable {
        case permissionDenied, invalidSelection, displayUnavailable, encodingFailed
        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Allow Pet Chat in System Settings → Privacy & Security → Screen Recording. If macOS asks, quit and reopen Pet Chat, then try Capture area again."
            case .invalidSelection: "Drag to select an area within one display."
            case .displayUnavailable: "The selected display is unavailable. Try Capture area again."
            case .encodingFailed: "The screenshot could not be saved. Try again."
            }
        }
    }

    private let permission: () -> Bool
    private let select: () async -> RegionSelection?
    private let screenshot: (RegionSelection) async throws -> Data

    init(permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() },
         select: @escaping () async -> RegionSelection? = { await RegionSelectionOverlay.selectRegion() },
         screenshot: @escaping (RegionSelection) async throws -> Data = { try await RegionCaptureController.screenshot($0) }) {
        self.permission = permission
        self.select = select
        self.screenshot = screenshot
    }

    func captureRegion() async throws -> Data? {
        guard permission() else { throw Error.permissionDenied }
        guard let selection = await select() else { return nil }
        _ = try Self.configuration(for: selection, scale: 1)
        return try await screenshot(selection)
    }

    static func configuration(for selection: RegionSelection, scale: CGFloat) throws -> SCStreamConfiguration {
        let rect = selection.rect, frame = selection.displayFrame
        guard [rect.minX, rect.minY, rect.width, rect.height, frame.minX, frame.minY,
               frame.width, frame.height, scale].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, scale > 0, frame.contains(rect) else { throw Error.invalidSelection }
        let configuration = SCStreamConfiguration()
        // ScreenCaptureKit sourceRect is display-local logical points; only output dimensions are pixels.
        configuration.sourceRect = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                                          width: rect.width, height: rect.height)
        configuration.width = Int(ceil(rect.width * scale))
        configuration.height = Int(ceil(rect.height * scale))
        configuration.showsCursor = false
        return configuration
    }

    private static func screenshot(_ selection: RegionSelection) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == selection.displayID
              }), screen.frame == selection.displayFrame else { throw Error.displayUnavailable }
        let filter = SCContentFilter(display: display,
            excludingApplications: content.applications.filter { $0.processID == getpid() }, exceptingWindows: [])
        let configuration = try configuration(for: selection, scale: CGFloat(filter.pointPixelScale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Error.encodingFailed
        }
        return png
    }
}
