// Shared by the Runner app and the NetcattyWidgets extension: both targets
// compile this file so ActivityKit can decode the same content state.
import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct NetcattySessionSummary: Codable, Hashable {
  var name: String
  var distro: String
  var connected: Bool
}

@available(iOS 16.1, *)
struct NetcattyActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// "zh" or "en"; the extension has no access to the app's settings.
    var lang: String
    var activeName: String
    var activeDistro: String
    var activeConnected: Bool
    var activeAddress: String
    /// Last command typed at a shell prompt, empty when unknown or hidden.
    var command: String
    var connectedSince: Date
    var count: Int
    /// Active session first, at most six.
    var sessions: [NetcattySessionSummary]
  }
}
#endif
