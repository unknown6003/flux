import AppKit
import FluxCore

/// The parent's state for the rating form. Show `.sent` only after the
/// analytics client reports that it sent the event.
public enum FeedbackSubmission: Equatable, Sendable {
    case ready
    case sending
    case sent
    case failed(code: String)
}

/// What the rating form shows. `collectionEnabled` is the saved analytics opt-in.
public struct FeedbackRatingState: Equatable, Sendable {
    public let collectionEnabled: Bool
    public let submission: FeedbackSubmission

    public init(collectionEnabled: Bool, submission: FeedbackSubmission) {
        self.collectionEnabled = collectionEnabled
        self.submission = submission
    }
}

/// Requests from the rating form. The parent adds its survey IDs, sends, and closes the form.
public enum FeedbackRatingAction: Equatable, Sendable {
    case submit(UsageRating)
    case cancel
}

/// A 1 to 5 rating with Submit and Cancel. Open it only from a user action.
/// It has no text field and holds no IDs.
@MainActor
public final class FeedbackRatingController: NSViewController {
    public private(set) var state: FeedbackRatingState
    private let onAction: (FeedbackRatingAction) -> Void
    private let ratings = NSSegmentedControl()
    private let status = FluxUIStyle.label("", style: .callout, secondary: true)
    private var submit: NSButton!
    private var selected: UsageRating?

    public init(state: FeedbackRatingState, onAction: @escaping (FeedbackRatingAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows a new state. It never sends an action and keeps the user's choice.
    public func update(state: FeedbackRatingState) {
        guard state != self.state else { return }
        self.state = state
        refresh()
    }

    override public func loadView() {
        let question = FluxUIStyle.label(L("feedback.question", "How well does Flux work for you?"), style: .headline)
        let all = UsageRating.allCases
        ratings.segmentCount = all.count
        ratings.trackingMode = .selectOne
        ratings.segmentDistribution = .fillEqually
        for (index, rating) in all.enumerated() {
            ratings.setLabel(rating.rawValue, forSegment: index)
        }
        ratings.selectedSegment = -1
        ratings.target = self
        ratings.action = #selector(choose(_:))
        ratings.identifier = .init("feedback.rating")
        ratings.setAccessibilityLabel(L("feedback.rating.ax", "Rating from 1, poor, to 5, great"))
        let ends = FluxUIStyle.hstack([
            FluxUIStyle.label(L("feedback.low", "1 Poor"), style: .caption1, secondary: true, wraps: false),
            FluxUIStyle.spacer(),
            FluxUIStyle.label(L("feedback.high", "5 Great"), style: .caption1, secondary: true, wraps: false),
        ])
        let cancel = FluxUIStyle.button(L("feedback.cancel", "Cancel"), target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        cancel.identifier = .init("feedback.cancel")
        let submit = FluxUIStyle.button(L("feedback.submit", "Submit"), target: self, action: #selector(submitPressed))
        submit.keyEquivalent = "\r"
        submit.identifier = .init("feedback.submit")
        self.submit = submit
        let buttons = FluxUIStyle.hstack([FluxUIStyle.spacer(), cancel, submit])
        let content = FluxUIStyle.vstack([question, ratings, ends, status, buttons], spacing: 10)
        let root = NSView()
        FluxUIStyle.pin(content, in: root, inset: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        let width = root.widthAnchor.constraint(equalToConstant: 360)
        width.priority = .defaultHigh
        width.isActive = true
        view = root
        refresh()
    }

    public override func cancelOperation(_ sender: Any?) { cancelPressed() }

    private func refresh() {
        guard isViewLoaded else { return }
        let sending = state.submission == .sending || state.submission == .sent
        ratings.isEnabled = state.collectionEnabled && !sending
        submit.isEnabled = state.collectionEnabled && selected != nil && !sending
        status.stringValue = statusText
        status.setAccessibilityLabel(status.stringValue)
        NSAccessibility.post(element: status, notification: .valueChanged)
    }

    private var statusText: String {
        guard state.collectionEnabled else {
            return L("feedback.off", "Usage data is off, so Flux can't send a rating. Turn it on in General to send one.")
        }
        switch state.submission {
        case .ready: return L("feedback.ready", "Usage data is on, so Flux sends this number. It sends no text.")
        case .sending: return L("feedback.sending", "Sending…")
        case .sent: return L("feedback.sent", "Rating sent. Thank you.")
        case .failed(let code): return String(format: L("feedback.failed", "The rating was not sent (%@). You can try again."), code)
        }
    }

    @objc private func choose(_ sender: NSSegmentedControl) {
        let all = UsageRating.allCases
        selected = all.indices.contains(sender.selectedSegment) ? all[sender.selectedSegment] : nil
        refresh()
    }

    @objc private func submitPressed() {
        guard let selected, submit.isEnabled else { return }
        onAction(.submit(selected))
    }

    @objc private func cancelPressed() { onAction(.cancel) }
}
