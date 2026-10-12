struct ProviderModel: Equatable, Identifiable {
    let id: String
    let displayName: String
    let supportsImages: Bool
    let contextWindowTokens: Int?
}
