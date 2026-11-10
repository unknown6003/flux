import Foundation
import Testing
@testable import FluxPlatform

struct FullscreenSpacesTests {
    private func display(type: Int?) -> [String: Any] {
        var current: [String: Any] = ["ManagedSpaceID": 3, "id64": 3]
        if let type { current["type"] = NSNumber(value: type) }
        return ["Display Identifier": "Main", "Current Space": current, "Spaces": [current]]
    }

    @Test func onlyAFullscreenCurrentSpaceCounts() {
        #expect(FullscreenSpaces.containsFullscreen([display(type: 0)]) == false)
        #expect(FullscreenSpaces.containsFullscreen([display(type: 4)]) == true)
        #expect(FullscreenSpaces.containsFullscreen([display(type: 0), display(type: 4)]) == true)
        #expect(FullscreenSpaces.containsFullscreen([display(type: nil)]) == false)
        #expect(FullscreenSpaces.containsFullscreen([]) == false)
        #expect(FullscreenSpaces.containsFullscreen([["Display Identifier": "Main"]]) == false)
    }

    @Test func aFullscreenSpaceThatIsNotCurrentDoesNotCount() {
        let fullscreen: [String: Any] = ["type": NSNumber(value: 4)]
        let desktop: [String: Any] = ["type": NSNumber(value: 0)]
        #expect(FullscreenSpaces.containsFullscreen([["Current Space": desktop, "Spaces": [desktop, fullscreen]]]) == false)
    }
}
