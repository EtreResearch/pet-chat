import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import PetChat

@MainActor
final class ChatAccessibilityTests: XCTestCase {
    func testChatPanelLabelsPetComposerAndActions() throws {
        let attachments = AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let container = try ModelContainer(for: ChatRecord.self, MessageRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LocalChatStore(container: container, attachments: attachments)
        let coordinator = try ChatCoordinator(providers: [.ollama: AccessibilityProvider()], store: store,
                                              attachments: attachments)
        let model = AppModel(coordinator: coordinator)
        try model.select(providerID: .ollama, modelID: "test")
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            ChatPanelView(model: model, onClose: {}, onChangeModel: {})
            PetView()
        })
        hosting.frame = CGRect(x: 0, y: 0, width: 340, height: 484)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()

        let labels = accessibilityLabels(in: AXUIElementCreateApplication(getpid()))
        for label in ["Pet", "Message", "Send", "Stop", "Tell me more", "Close"] {
            XCTAssertTrue(labels.contains(label), "Missing accessible \(label): \(labels)")
        }
    }

    private func accessibilityLabels(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 20 else { return [] }
        var labels: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String { labels.append(text) }
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let items = children as? [AXUIElement] {
            labels += items.flatMap { accessibilityLabels(in: $0, depth: depth + 1) }
        }
        return labels
    }
}

private struct AccessibilityProvider: ChatProvider {
    let providerID: ProviderID = .ollama
    func availableModels() async throws -> [ProviderModel] { [] }
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancel(_ requestID: UUID) async {}
}
