import Foundation

/// Where background agents leave finished work — the spreadsheet, the summary, the
/// converted file. A plain folder in the home directory rather than Application Support
/// (where `Profile` lives): the whole point of this one is that the user can find what
/// the agent made, and nobody browses ~/Library by choice.
///
/// This is a drop-off, not a sandbox. Agents can only write at all when full access is
/// on, and that mode scopes nothing — `--dangerously-skip-permissions` has no notion of
/// a permitted path. What this folder buys is that ten runs put their output in one
/// predictable place instead of inventing ten. `workNote` in AgentRunner is what points
/// agents here, and it is the only thing that does.
enum Workspace {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Debby", isDirectory: true)

    static var path: String { url.path }

    /// Created when an agent that can write actually starts, not at launch: an app that
    /// puts a folder in your home directory before you have ever run an agent is litter.
    static func ensure() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
