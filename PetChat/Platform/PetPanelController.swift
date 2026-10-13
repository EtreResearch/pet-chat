import AppKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}

struct PetDisplay: Identifiable {
    let id: CGDirectDisplayID
    let visibleFrame: CGRect
    var name = ""
}

struct PetPosition {
    let displayID: CGDirectDisplayID
    let origin: CGPoint

    static func clamp(_ origin: CGPoint, size: CGSize, to frame: CGRect) -> CGPoint {
        CGPoint(x: max(frame.minX, min(origin.x, frame.maxX - size.width)),
                y: max(frame.minY, min(origin.y, frame.maxY - size.height)))
    }

    static func resolve(displayID: CGDirectDisplayID?, positions: [CGDirectDisplayID: CGPoint],
                        displays: [PetDisplay]) -> PetPosition? {
        guard let display = displays.first(where: { $0.id == displayID }) ?? displays.first else { return nil }
        let origin = positions[display.id] ?? CGPoint(x: display.visibleFrame.maxX - 80, y: display.visibleFrame.minY + 16)
        return PetPosition(displayID: display.id, origin: clamp(origin, size: CGSize(width: 64, height: 64), to: display.visibleFrame))
    }

    static func chatFrame(near pet: CGPoint, visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(340, visibleFrame.width), height: min(420, visibleFrame.height))
        let above = pet.y + 72
        let y = above + size.height <= visibleFrame.maxY ? above : pet.y - size.height - 8
        return CGRect(origin: clamp(CGPoint(x: pet.x + 64 - size.width, y: y), size: size, to: visibleFrame), size: size)
    }
}

final class ChatFloatingPanel: NSPanel {
    var onCollapse: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCollapse?() }
    override func close() { onCollapse?() }
}

@MainActor
final class PetPanelController: NSObject {
    let petPanel: NSPanel
    let chatPanel: ChatFloatingPanel
    let model: AppModel
    private let defaults: UserDefaults
    private let displayProvider: () -> [PetDisplay]
    private let fullScreenProvider: (CGDirectDisplayID?) -> Bool
    private(set) var selectedDisplayID: CGDirectDisplayID?
    private(set) var isPetVisible = true
    private var fullScreen = false
    private var summonedInFullScreen = false
    private var chatContentInstalled = false
    private var panelRevision = 0
    private var captureInProgress = false
    private var captureMayFocus = true

    var displays: [PetDisplay] { displayProvider() }

    static var currentDisplays: [PetDisplay] {
        NSScreen.screens.compactMap { screen in
            screen.displayID.map { PetDisplay(id: $0, visibleFrame: screen.visibleFrame, name: screen.localizedName) }
        }
    }
    private var positions: [CGDirectDisplayID: CGPoint] {
        var result: [CGDirectDisplayID: CGPoint] = [:]
        for (key, value) in defaults.dictionary(forKey: "PetChat.petPositions") ?? [:] {
            if let id = UInt32(key), let values = value as? [Double], values.count == 2,
               values[0].isFinite, values[1].isFinite {
                result[id] = CGPoint(x: values[0], y: values[1])
            }
        }
        return result
    }

    init(model: AppModel, defaults: UserDefaults = .standard,
         displayProvider: @escaping () -> [PetDisplay] = { PetPanelController.currentDisplays },
         fullScreenProvider: @escaping (CGDirectDisplayID?) -> Bool = { PetPanelController.hasFullScreenWindow(on: $0) }) {
        self.model = model
        self.defaults = defaults
        self.displayProvider = displayProvider
        self.fullScreenProvider = fullScreenProvider
        petPanel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        chatPanel = ChatFloatingPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 420),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        for panel in [petPanel, chatPanel] {
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
        }
        model.captureRegion = { [weak self] in try await self?.captureRegion() }
        petPanel.hasShadow = false
        chatPanel.hasShadow = true
        chatPanel.title = "Pet Chat"
        chatPanel.onCollapse = { [weak self] in self?.collapseChat(preservingDraft: true) }
        petPanel.contentView = PetInteractionView(model: model, onClick: { [weak self] in self?.showChat() },
                                                 onDrag: { [weak self] in self?.movePet(to: $0) })
        selectedDisplayID = (defaults.object(forKey: "PetChat.selectedDisplayID") as? NSNumber)?.uint32Value
        repositionPet(for: selectedDisplayID ?? displays.first?.id ?? 0)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivated),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }

    func captureRegion(using capture: @MainActor () async throws -> Data? = {
        try await RegionCaptureController().captureRegion()
    }) async throws -> Data? {
        guard !captureInProgress else { throw ChatCoordinator.Error.busy }
        captureInProgress = true
        captureMayFocus = true
        let revision = panelRevision
        petPanel.orderOut(nil)
        chatPanel.orderOut(nil)
        defer {
            captureInProgress = false
            if panelRevision == revision, isPetVisible {
                presentChat(activate: false, focus: captureMayFocus && NSApp.isActive)
            }
        }
        return try await capture()
    }

    func showChat() { presentChat(activate: true, focus: true) }

    private func presentChat(activate: Bool, focus: Bool) {
        panelRevision += 1
        if !chatContentInstalled {
            chatPanel.contentView = NSHostingView(rootView: FloatingChatRootView(model: model, onClose: { [weak self] in
                self?.collapseChat(preservingDraft: true)
            }))
            chatContentInstalled = true
        }
        isPetVisible = true
        summonedInFullScreen = fullScreen
        petPanel.orderFrontRegardless()
        placeChat()
        if activate { NSApp.activate(ignoringOtherApps: true) }
        if focus { chatPanel.makeKeyAndOrderFront(nil) }
        else { chatPanel.orderFrontRegardless() }
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isActive, self.chatPanel.isKeyWindow else { return }
            self.chatPanel.contentView?.layoutSubtreeIfNeeded()
            if let editor = Self.textEditor(in: self.chatPanel.contentView) {
                self.chatPanel.makeFirstResponder(editor)
            }
        }
    }

    func collapseChat(preservingDraft: Bool) {
        panelRevision += 1
        chatPanel.orderOut(nil)
        if !preservingDraft { model.draft = "" }
        if fullScreen { summonedInFullScreen = false; petPanel.orderOut(nil) }
    }

    func showPetOnly() {
        panelRevision += 1
        isPetVisible = true
        chatPanel.orderOut(nil)
        if !fullScreen || summonedInFullScreen { petPanel.orderFrontRegardless() }
    }

    func hidePet() {
        panelRevision += 1
        isPetVisible = false
        summonedInFullScreen = false
        petPanel.orderOut(nil)
        chatPanel.orderOut(nil)
    }

    func repositionPet(for displayID: CGDirectDisplayID) {
        guard let position = PetPosition.resolve(displayID: displayID, positions: positions, displays: displays) else {
            petPanel.orderOut(nil); chatPanel.orderOut(nil); return
        }
        selectedDisplayID = position.displayID
        defaults.set(position.displayID, forKey: "PetChat.selectedDisplayID")
        petPanel.setFrameOrigin(position.origin)
        placeChat()
        spaceChanged()
    }

    func movePet(to origin: CGPoint) {
        guard let display = displays.first(where: { $0.id == selectedDisplayID }) else { return }
        let clamped = PetPosition.clamp(origin, size: petPanel.frame.size, to: display.visibleFrame)
        petPanel.setFrameOrigin(clamped)
        var stored = defaults.dictionary(forKey: "PetChat.petPositions") ?? [:]
        stored[String(display.id)] = [clamped.x, clamped.y]
        defaults.set(stored, forKey: "PetChat.petPositions")
        placeChat()
    }

    func applicationDidDeactivate() {
        captureMayFocus = false
        chatPanel.resignKey()
    }

    func activeSpaceDidChange(isFullScreen: Bool) {
        panelRevision += 1
        fullScreen = isFullScreen
        summonedInFullScreen = false
        if isFullScreen { petPanel.orderOut(nil); chatPanel.orderOut(nil) }
        else if isPetVisible && !captureInProgress { petPanel.orderFrontRegardless() }
    }

    private func placeChat() {
        guard let display = displays.first(where: { $0.id == selectedDisplayID }) else { return }
        chatPanel.setFrame(PetPosition.chatFrame(near: petPanel.frame.origin, visibleFrame: display.visibleFrame), display: true)
    }

    private static func textEditor(in view: NSView?) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view?.subviews.lazy.compactMap { textEditor(in: $0) }.first
    }

    @objc private func displaysChanged() { repositionPet(for: selectedDisplayID ?? 0) }
    @objc private func deactivated() { applicationDidDeactivate() }
    @objc private func spaceChanged() {
        activeSpaceDidChange(isFullScreen: fullScreenProvider(selectedDisplayID))
    }

    // Window metadata is sufficient; no screen pixels or accessibility permission are read.
    static func hasFullScreenWindow(on displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let frame = CGDisplayBounds(displayID)
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? Int32 != getpid(),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.minX - frame.minX) < 2 && abs(rect.minY - frame.minY) < 2 &&
                   abs(rect.width - frame.width) < 2 && abs(rect.height - frame.height) < 2
        }
    }
}

private struct FloatingChatRootView: View {
    @Bindable var model: AppModel
    let onClose: () -> Void
    @State private var choosingModel = false

    var body: some View {
        Group {
            if model.thread == nil || choosingModel {
                VStack(spacing: 0) {
                    HStack {
                        if model.thread != nil { Button("Back") { choosingModel = false } }
                        Spacer()
                        Button("Close", action: onClose).accessibilityLabel("Close")
                    }.padding(10)
                    SetupView(model: model, onSelected: { choosingModel = false })
                    Spacer(minLength: 0)
                }.frame(width: 340, height: 420)
            } else {
                ChatPanelView(model: model, onClose: onClose, onChangeModel: { choosingModel = true })
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onExitCommand(perform: onClose)
    }
}

private final class PetInteractionView: NSHostingView<PetSurface> {
    private let onClick: () -> Void
    private let onDrag: (CGPoint) -> Void
    private var startMouse = CGPoint.zero
    private var startOrigin = CGPoint.zero
    private var dragged = false

    init(model: AppModel, onClick: @escaping () -> Void, onDrag: @escaping (CGPoint) -> Void) {
        self.onClick = onClick
        self.onDrag = onDrag
        super.init(rootView: PetSurface(model: model))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pet")
        setAccessibilityHelp("Open chat. Drag to move the pet.")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @available(*, unavailable) required init(rootView: PetSurface) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
        if hypot(dx, dy) > 3 { dragged = true }
        if dragged { onDrag(CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) { if !dragged { onClick() } }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

private struct PetSurface: View {
    @Bindable var model: AppModel
    var body: some View {
        PetCharacterView(isThinking: model.isLoading, completionID: model.thread?.messages.last.flatMap {
            $0.role == .pet && $0.status == .complete ? $0.id : nil
        })
        .accessibilityHidden(true)
    }
}
