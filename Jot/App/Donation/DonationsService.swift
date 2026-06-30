import Foundation

enum DonationsService {
    enum Error: Swift.Error {
        case invalidResponse
        case badStatus(Int)
    }

    private static let endpoint = URL(string: "https://jot-donations.ideaflow.page/summary")!
    private static let charitiesEndpoint = URL(string: "https://jot-donations.ideaflow.page/charities.json")!

    static func fetchSummary(session: URLSession = .shared) async throws -> DonationsSummary {
        let (data, response) = try await session.data(from: endpoint)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Error.badStatus(httpResponse.statusCode)
        }
        return try decoder.decode(DonationsSummary.self, from: data)
    }

    /// Fetch the static charity metadata file (description + logo + fundraiser
    /// URL, keyed by owner-defined slug). Returns the RAW bytes so the caller
    /// can cache them verbatim; decode with `decodeCharities`.
    static func fetchCharitiesData(session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(from: charitiesEndpoint)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Error.badStatus(httpResponse.statusCode)
        }
        return data
    }

    /// Decode `charities.json` bytes into a `slug -> metadata` map for merging.
    /// Returns `[:]` on empty/malformed data (best-effort enrichment).
    static func decodeCharities(from data: Data) -> [String: CharityMetadata] {
        guard !data.isEmpty,
              let file = try? decoder.decode(CharitiesFile.self, from: data) else { return [:] }
        return Dictionary(file.charities.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func decodeCachedSummary(from data: Data) -> DonationsSummary? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(DonationsSummary.self, from: data)
    }

    static func encodeForCache(_ summary: DonationsSummary) -> Data? {
        try? encoder.encode(summary)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
