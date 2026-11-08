import Foundation

public enum FluxUsageProject {
    public static let id = 340600
    public static let region: PostHogRegion = .eu
    // Public, write-only ingestion token. The maintenance key stays in the credential vault.
    public static let token = "phc_ke2AcgstgoMJNBUZu9zrrH2PzE3j4EWoxYJefGrgBgEq"
}

extension UsageCollection {
    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults) { identity in
            try PostHogClient(projectToken: FluxUsageProject.token, identity: identity,
                              transport: NativeUsageTransport(region: FluxUsageProject.region))
        }
    }
}
