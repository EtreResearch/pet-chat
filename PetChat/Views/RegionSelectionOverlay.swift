import AppKit

@MainActor
final class RegionSelectionOverlay: NSView {
    var onSelection: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection: CGRect?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        onSelection?(selection ?? .zero)
    }

    override func cancelOperation(_ sender: Any?) { onSelection?(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let selection {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            selection.fill()
            NSColor.white.setStroke()
            NSBezierPath(rect: selection).stroke()
        }
        let hint = "Drag to capture an area · Esc to cancel"
        hint.draw(at: CGPoint(x: 24, y: bounds.height - 48), withAttributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 18, weight: .semibold)
        ])
    }

    static func selectRegion() async -> RegionSelection? {
        await withCheckedContinuation { continuation in
            var panels: [SelectionPanel] = []
            var finished = false
            for screen in NSScreen.screens {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
                let panel = SelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.level = .screenSaver
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.backgroundColor = .clear
                panel.isOpaque = false
                let overlay = RegionSelectionOverlay(frame: CGRect(origin: .zero, size: screen.frame.size))
                overlay.setAccessibilityLabel("Select capture area. Drag within a display. Escape cancels.")
                overlay.onSelection = { rect in
                    guard !finished else { return }
                    finished = true
                    let result = rect.map { RegionSelection(displayID: id, displayFrame: screen.frame,
                                                            rect: panel.convertToScreen($0)) }
                    for panel in panels { panel.orderOut(nil); panel.contentView = nil; panel.close() }
                    panels.removeAll()
                    continuation.resume(returning: result)
                }
                panel.contentView = overlay
                panels.append(panel)
                panel.orderFrontRegardless()
                panel.makeFirstResponder(overlay)
            }
            guard !panels.isEmpty else { continuation.resume(returning: nil); return }
            let mouse = NSEvent.mouseLocation
            let active = panels.first(where: { $0.frame.contains(mouse) }) ?? panels[0]
            active.makeKeyAndOrderFront(nil)
        }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { contentView?.cancelOperation(sender) }
}
