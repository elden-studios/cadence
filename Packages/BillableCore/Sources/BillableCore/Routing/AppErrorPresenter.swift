import Foundation
import Observation

/// Shared error channel for the SwiftUI environment.  Views call
/// `present(_:)` on the main actor; `RootView` hosts a single
/// `.alert` modifier that reads `message` and clears it on dismiss.
///
/// Why this lives alongside `NotificationRouter` in `BillableCore`:
/// keeping both presenter types in the testable package lets unit tests
/// verify the `present` / clear lifecycle without importing UIKit or
/// spinning up a full app target.
@MainActor
@Observable
public final class AppErrorPresenter {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }

    public func present(_ message: String) {
        self.message = message
    }
}
