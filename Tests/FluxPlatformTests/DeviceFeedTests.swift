import Foundation
import Testing
import FluxCore
@testable import FluxPlatform

@MainActor @Test(.timeLimit(.minutes(1)))
func releasingTheDeviceFeedStopsItsRealReadOnlySubscriptions() async throws {
    weak var releasedDriver: DeviceDriver?
    weak var releasedFeed: DeviceFeed?
    do {
        let driver = DeviceDriver()
        var feed: DeviceFeed? = DeviceFeed(driver: driver) { _ in }
        releasedDriver = driver
        releasedFeed = feed
        // Start real registry/HAL listeners. This opens no radio connection,
        // asks for no grant and changes no device state.
        try await Task.sleep(for: .milliseconds(100))
        feed = nil
        #expect(releasedFeed == nil)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while releasedDriver != nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(releasedDriver == nil)
}
