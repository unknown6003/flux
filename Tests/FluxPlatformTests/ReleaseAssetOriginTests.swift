import Foundation
import Testing
@testable import FluxPlatform

struct ReleaseAssetOriginTests {
    @Test func assetRedirectsKeepTheReleaseHostsWithoutCredentialsOrOtherPorts() throws {
        for text in ["https://github.com/unknown6003/flux/releases/download/v0.22.0/Flux.dmg",
                     "https://release-assets.githubusercontent.com/asset?token=fixture"] {
            #expect(ReleaseAssetOrigin.accepts(try #require(URL(string: text))))
        }
        for text in ["http://github.com/asset", "https://github.com.evil.example/asset",
                     "https://github.com:444/asset", "https://user:secret@github.com/asset",
                     "https://raw.githubusercontent.com/asset"] {
            #expect(!ReleaseAssetOrigin.accepts(try #require(URL(string: text))))
        }
    }
}
