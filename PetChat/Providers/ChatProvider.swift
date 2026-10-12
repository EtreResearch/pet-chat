import Foundation

enum GenerationEvent {
    case textDelta(String)
    case completed
}

protocol ChatProvider {
    var providerID: ProviderID { get }
    func availableModels() async throws -> [ProviderModel]
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    func cancel(_ requestID: UUID) async
}
