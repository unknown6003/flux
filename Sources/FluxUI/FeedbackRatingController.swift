import AppKit
import FluxCore

/// Why the last try did not end with an accepted rating. Each case has one
/// fixed message. It holds no error text or IDs.
public enum FeedbackFailure: Equatable, Sendable {
    /// Another rating is still in progress. Nothing was sent for this try.
    case busy
    /// Flux can't send more ratings now.
    case limited
    /// No accepted reply came back. The rating may still have arrived.
    case unconfirmed
}

/// The parent's state for the rating form. Show `.sent` only after
/// `UsageCollection.submitRating` returns `.accepted`.
public enum FeedbackSubmission: Equatable, Sendable {
    case ready
    case sending
    case sent
    case failed(FeedbackFailure)
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

/// Requests from the rating form. The parent sends the rating and closes the form.
public enum FeedbackRatingAction: Equatable, Sendable {
    /// Sent once per click. The form shows `.sending` before it sends this.
    case submit(UsageRating)
    /// Cancel or Esc before an accepted rating.
    case cancel
    /// Done or Esc after an accepted rating.
    case done
}

/// A 1 to 5 rating with Submit and Cancel, then Done after an accepted
/// rating. Open it only from a user action. It has no text field, holds no
/// IDs and does no networking.
@MainActor
public final class FeedbackRatingController: NSViewController {
    public private(set) var state: FeedbackRatingState
    private let onAction: (FeedbackRatingAction) -> Void
    private let ratings = NSSegmentedControl()
    private let status = FluxUIStyle.label("", style: .callout, secondary: true)
    private var submit: NSButton!
    private var cancel: NSButton!
    private var done: NSButton!
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
        let wasSent = self.state.submission == .sent
        self.state = state
        refresh()
        if !wasSent, state.submission == .sent, isViewLoaded { view.window?.makeFirstResponder(done) }
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
        cancel.identifier = .init("feedback.cancel")
        self.cancel = cancel
        let submit = FluxUIStyle.button(L("feedback.submit", "Submit"), target: self, action: #selector(submitPressed))
        submit.identifier = .init("feedback.submit")
        self.submit = submit
        let done = FluxUIStyle.button(L("feedback.done", "Done"), target: self, action: #selector(donePressed))
        done.identifier = .init("feedback.done")
        self.done = done
        let buttons = FluxUIStyle.hstack([FluxUIStyle.spacer(), cancel, submit, done])
        let content = FluxUIStyle.vstack([question, ratings, ends, status, buttons], spacing: 10)
        let root = NSView()
        FluxUIStyle.pin(content, in: root, inset: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        let width = root.widthAnchor.constraint(equalToConstant: 360)
        width.priority = .defaultHigh
        width.isActive = true
        view = root
        refresh()
    }

    public override func cancelOperation(_ sender: Any?) {
        if state.submission == .sent { donePressed() } else { cancelPressed() }
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let sent = state.submission == .sent
        let locked = sent || state.submission == .sending
        ratings.isEnabled = state.collectionEnabled && !locked
        submit.isEnabled = state.collectionEnabled && selected != nil && !locked
        // Hidden buttons keep no key equivalent, so Return and Esc reach only the visible ones.
        cancel.isHidden = sent
        submit.isHidden = sent
        done.isHidden = !sent
        cancel.keyEquivalent = sent ? "" : "\u{1b}"
        submit.keyEquivalent = sent ? "" : "\r"
        done.keyEquivalent = sent ? "\r" : ""
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
        case .sent: return L("feedback.sent", "Rating received. Thank you.")
        case .failed(.busy): return L("feedback.busy", "Flux is still sending a rating. Try again in a moment.")
        case .failed(.limited): return L("feedback.limited", "Flux can't send more ratings now. Try again later.")
        case .failed(.unconfirmed): return L("feedback.unconfirmed", "Could not confirm that the rating arrived. You can try again.")
        }
    }

    @objc private func choose(_ sender: NSSegmentedControl) {
        let all = UsageRating.allCases
        selected = all.indices.contains(sender.selectedSegment) ? all[sender.selectedSegment] : nil
        refresh()
    }

    /// Locks the form before it sends the action, so a second click or
    /// Return sends nothing. The parent's next state unlocks it.
    @objc private func submitPressed() {
        guard let selected, submit.isEnabled, state.collectionEnabled, state.submission != .sending else { return }
        state = FeedbackRatingState(collectionEnabled: true, submission: .sending)
        refresh()
        onAction(.submit(selected))
    }

    @objc private func cancelPressed() { onAction(.cancel) }

    @objc private func donePressed() { onAction(.done) }
}
