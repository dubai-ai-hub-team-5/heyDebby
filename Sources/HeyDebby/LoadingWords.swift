import Foundation

/// The whimsical vocabulary the notch cycles through while a context.dev fetch is in
/// flight. Instead of one static "Fetching…" line, Debby narrates her own busywork with
/// an ever-changing gerund — practical one tick, culinary the next, then pure nonsense.
///
/// Grouped by flavour for the reader; flattened into `all` for the ticker.
enum LoadingWords {
    static let all: [String] = practical + culinary + scientific + nonsense + more

    /// Down-to-earth, believable-for-a-computer verbs.
    static let practical = [
        "Computing", "Processing", "Generating", "Inferring", "Parsing",
        "Compiling", "Indexing", "Buffering", "Rendering", "Caching",
    ]

    /// It's basically cooking, if you squint.
    static let culinary = [
        "Baking", "Brewing", "Sautéing", "Julienning", "Marinating",
        "Whisking", "Simmering", "Caramelizing", "Kneading", "Poaching",
    ]

    /// Lab-coat energy.
    static let scientific = [
        "Nucleating", "Photosynthesizing", "Ionizing", "Crystallizing",
        "Polymerizing", "Catalyzing", "Distilling", "Oscillating", "Fermenting",
    ]

    /// Certified balderdash.
    static let nonsense = [
        "Flibbertigibbeting", "Discombobulating", "Lollygagging", "Bamboozling",
        "Kerfuffling", "Snollygostering", "Skedaddling", "Flummoxing", "Wibbling",
    ]

    /// …and more funny stuff — short phrases, not single words.
    static let more = [
        "Reticulating splines", "Herding cats", "Summoning pixels",
        "Consulting the oracle", "Untangling the internet", "Poking the hamster",
        "Feeding the algorithm", "Wrangling electrons", "Bribing the servers",
    ]

    /// Shuffled once per launch: each session's sequence differs, but stays stable within
    /// a fetch so the ticker advances in order rather than jumping around at random. A
    /// read-only `let` computed at first access — no mutation, no data race.
    static let shuffled: [String] = all.shuffled()

    /// The word for a given tick, wrapping forever. `abs` guards the (impossible-here but
    /// cheap-to-cover) negative index; `%` keeps it in range for any tick count.
    static func word(tick: Int) -> String {
        guard !shuffled.isEmpty else { return "Working" }
        return shuffled[abs(tick) % shuffled.count]
    }
}
