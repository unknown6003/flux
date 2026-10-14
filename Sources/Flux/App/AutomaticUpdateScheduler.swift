import Combine
import Foundation

/// Owns the automatic check schedule for the lifetime of the app.
@MainActor
final class AutomaticUpdateScheduler {
    private let check: () -> Void
    private let initialDelay: Duration
    private let interval: TimeInterval
    private var enabled = false
    private var subscription: AnyCancellable?
    private var launchCheck: Task<Void, Never>?
    private var timer: Timer?

    init(enabled: AnyPublisher<Bool, Never>,
         initialDelay: Duration = .seconds(4), interval: TimeInterval = 6 * 3600,
         check: @escaping () -> Void) {
        precondition(interval > 0)
        self.check = check
        self.initialDelay = initialDelay
        self.interval = interval
        subscription = enabled.removeDuplicates().sink { [weak self] value in
            self?.configure(enabled: value)
        }
    }

    private func configure(enabled: Bool) {
        self.enabled = enabled
        launchCheck?.cancel()
        launchCheck = nil
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        launchCheck = Task { @MainActor [weak self] in
            guard let delay = self?.initialDelay else { return }
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, self.enabled else { return }
            self.check()
        }
        let periodic = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                self.check()
            }
        }
        RunLoop.main.add(periodic, forMode: .common)
        timer = periodic
    }

    deinit {
        launchCheck?.cancel()
        timer?.invalidate()
    }
}
