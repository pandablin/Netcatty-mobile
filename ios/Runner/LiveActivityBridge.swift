import Flutter
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Flutter channel `app.netcatty.mobile/live_activity`:
///   sync(payload) – start or update the Dynamic Island / Lock Screen activity
///   end()         – remove it
enum LiveActivityBridge {
  static func register(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "app.netcatty.mobile/live_activity",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard #available(iOS 16.2, *) else {
        result(nil)
        return
      }
      switch call.method {
      case "sync":
        guard let arguments = call.arguments as? [String: Any] else {
          result(FlutterError(code: "bad_args", message: "Missing payload", details: nil))
          return
        }
        let state = NetcattyLiveActivityManager.contentState(from: arguments)
        Task { @MainActor in
          NetcattyLiveActivityManager.shared.sync(state, completion: result)
        }
      case "end":
        Task { @MainActor in
          NetcattyLiveActivityManager.shared.end { result(nil) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    if #available(iOS 16.2, *) {
      // Nothing is connected right after launch: drop activities left behind
      // when the previous process was killed.
      Task { @MainActor in
        NetcattyLiveActivityManager.shared.end {}
      }
    }
    return channel
  }

  /// Best effort on termination; the process may exit before this finishes.
  static func endAllBlocking() {
    guard #available(iOS 16.2, *) else { return }
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      for activity in Activity<NetcattyActivityAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 1)
  }
}

@available(iOS 16.2, *)
@MainActor
final class NetcattyLiveActivityManager {
  static let shared = NetcattyLiveActivityManager()

  /// Without an update for this long the activity is shown as stale (grey),
  /// e.g. after iOS killed the app in the background.
  private static let staleAfter: TimeInterval = 10 * 60

  private var current: Activity<NetcattyActivityAttributes>?
  /// Serializes operations so two quick syncs can never request two
  /// activities while the first one is still being created.
  private var tail: Task<Void, Never>?

  private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previous = tail
    tail = Task { @MainActor in
      await previous?.value
      await operation()
    }
  }

  nonisolated static func contentState(
    from arguments: [String: Any]
  ) -> NetcattyActivityAttributes.ContentState {
    let sessions = (arguments["sessions"] as? [[String: Any]] ?? []).map { item in
      NetcattySessionSummary(
        name: item["name"] as? String ?? "",
        distro: item["distro"] as? String ?? "linux",
        connected: item["connected"] as? Bool ?? true
      )
    }
    let since = (arguments["connectedSince"] as? NSNumber)?.doubleValue
    return NetcattyActivityAttributes.ContentState(
      lang: arguments["lang"] as? String ?? "zh",
      activeId: arguments["activeId"] as? String ?? "",
      activeName: arguments["activeName"] as? String ?? "",
      activeDistro: arguments["activeDistro"] as? String ?? "linux",
      activeConnected: arguments["activeConnected"] as? Bool ?? true,
      activeAddress: arguments["activeAddress"] as? String ?? "",
      command: arguments["command"] as? String ?? "",
      connectedSince: since.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
      count: arguments["count"] as? Int ?? sessions.count,
      sessions: sessions
    )
  }

  func sync(
    _ state: NetcattyActivityAttributes.ContentState,
    completion: @escaping FlutterResult
  ) {
    enqueue { [weak self] in
      guard let self else { return }
      let content = ActivityContent(
        state: state,
        staleDate: Date().addingTimeInterval(Self.staleAfter)
      )
      if let activity = self.liveActivity() {
        await activity.update(content)
        completion(nil)
        return
      }
      guard ActivityAuthorizationInfo().areActivitiesEnabled else {
        completion(FlutterError(
          code: "disabled",
          message: "Live Activities are turned off for Netcatty",
          details: nil
        ))
        return
      }
      do {
        self.current = try Activity.request(
          attributes: NetcattyActivityAttributes(),
          content: content,
          pushType: nil
        )
        completion(nil)
      } catch {
        // Usually: requested while the app is in the background.
        completion(FlutterError(
          code: "request_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }

  func end(completion: @escaping () -> Void) {
    enqueue { [weak self] in
      self?.current = nil
      for activity in Activity<NetcattyActivityAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      completion()
    }
  }

  /// The running activity, adopting one created earlier in this process and
  /// ending any duplicates.
  private func liveActivity() -> Activity<NetcattyActivityAttributes>? {
    if let current, current.activityState == .active || current.activityState == .stale {
      return current
    }
    current = Activity<NetcattyActivityAttributes>.activities.first {
      $0.activityState == .active || $0.activityState == .stale
    }
    return current
  }
}
