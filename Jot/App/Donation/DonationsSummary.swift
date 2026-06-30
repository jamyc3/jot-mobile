import Foundation

struct DonationsSummary: Codable, Equatable, Sendable {
    let totalDonations: Int
    let totalRaisedUSD: Double
    let perCharity: [DonationCharity]
    let lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case totalDonations = "total_donations"
        case totalRaisedUSD = "total_raised_usd"
        case perCharity = "per_charity"
        case lastUpdated = "last_updated"
    }
}

struct DonationCharity: Codable, Equatable, Hashable, Identifiable, Sendable {
    let slug: String
    let name: String
    /// One-line charity description from the donations API (e.g.
    /// "Supports children in foster care with essentials and
    /// resources."). Optional because a small number of charities in
    /// the feed (e.g. "techleapindia") ship without one — the row
    /// renders without the description line in that case rather than
    /// substituting placeholder copy.
    let description: String?
    /// Direct URL to the charity's specific Jot fundraiser page on
    /// every.org (e.g. `https://www.every.org/fosterlove/f/kids-in-
    /// foster-care`). Optional for the same reason as `description`
    /// — a charity without an active fundraiser entry simply omits it.
    /// NOT currently used by the donate-pill URL builder, which
    /// constructs `/<slug>/donate?amount=N` — see `openDonation` in
    /// `DonationsView`. There's an open question whether donations
    /// through the generic `/donate` URL count toward Jot's tracker
    /// (which is keyed on the fundraiser page); flagged as a
    /// follow-up.
    let fundraiserURL: String?
    /// Direct URL to the charity's logo image (PNG/JPG/SVG served by the
    /// donations API). Optional — for charities without a logo the
    /// avatar falls back to a tinted initials chip (see
    /// `CharityAvatar`). Loaded async via `AsyncImage` at both list-row
    /// (40pt) and detail-sheet (72pt) sizes.
    let logoURL: String?
    let count: Int
    let totalRaisedUSD: Double

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug
        case name
        case description
        case fundraiserURL = "fundraiser_url"
        case logoURL = "logo_url"
        case count
        case totalRaisedUSD = "total_raised_usd"
    }

    /// Return a copy enriched with static metadata from `charities.json`
    /// (description / logo / fundraiser URL), joined by slug. The live
    /// `/summary` feed only carries `count` + `totalRaisedUSD`, so the
    /// human-facing copy and logo come from the metadata file. Metadata wins
    /// when present; otherwise the existing value is kept. Slug, name, count,
    /// and raised totals are untouched.
    func enriched(with metadata: CharityMetadata?) -> DonationCharity {
        guard let metadata else { return self }
        return DonationCharity(
            slug: slug,
            name: name,
            description: metadata.description ?? description,
            fundraiserURL: metadata.fundraiserURL ?? fundraiserURL,
            logoURL: metadata.logoURL ?? logoURL,
            count: count,
            totalRaisedUSD: totalRaisedUSD
        )
    }
}

/// Static per-charity metadata from `https://jot-donations.ideaflow.page/charities.json`
/// — the human-facing copy + logo that the live `/summary` feed omits. Joined
/// to the summary by `slug` (owner-defined slugs; NOT every.org slugs). The
/// logo field is decoded flexibly so whichever key the file uses
/// (`logo_url` / `logo` / `image` / `image_url`) is picked up without an app
/// change.
struct CharityMetadata: Codable, Equatable, Sendable {
    let slug: String
    let name: String
    let description: String?
    let fundraiserURL: String?
    let logoURL: String?

    enum CodingKeys: String, CodingKey {
        case slug, name, description
        case fundraiserURL = "fundraiser_url"
        case logoURL = "logo_url"
        case logo, image
        case imageURL = "image_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        fundraiserURL = try c.decodeIfPresent(String.self, forKey: .fundraiserURL)
        // Whichever logo key the file uses — none today, but ready for when
        // the owner adds one.
        let logoCandidates: [String?] = [
            try c.decodeIfPresent(String.self, forKey: .logoURL),
            try c.decodeIfPresent(String.self, forKey: .logo),
            try c.decodeIfPresent(String.self, forKey: .image),
            try c.decodeIfPresent(String.self, forKey: .imageURL),
        ]
        logoURL = logoCandidates.compactMap { $0 }.first
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slug, forKey: .slug)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(fundraiserURL, forKey: .fundraiserURL)
        try c.encodeIfPresent(logoURL, forKey: .logoURL)
    }
}

/// Wrapper matching the `{ "charities": [...] }` shape of `charities.json`.
struct CharitiesFile: Codable, Sendable {
    let charities: [CharityMetadata]
}
