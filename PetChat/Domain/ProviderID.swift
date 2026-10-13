enum ProviderID: String, Codable, Hashable {
    case ollama
    case chatGPT

    var displayName: String { self == .ollama ? "Ollama" : "ChatGPT" }
}
