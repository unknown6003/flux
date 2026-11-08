import Foundation

/// The token is immutable after construction. NotificationCenter permits
/// removal from any thread, including the final owner's deinitialization.
final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name,
         object: AnyObject? = nil,
         receive: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: .main, using: receive)
    }

    deinit { center.removeObserver(token) }
}
