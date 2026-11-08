import Testing
@testable import FluxCore

@MainActor private final class ServiceTrace {
    var entries: [String] = []
}

@MainActor private final class TracedService: FeatureServiceHandle {
    let name: String
    let trace: ServiceTrace
    init(_ name: String, _ trace: ServiceTrace) {
        self.name = name
        self.trace = trace
        trace.entries.append("start.\(name)")
    }
    func stop() { trace.entries.append("stop.\(name)") }
}

@Test @MainActor func runtimeStopsCameraBeforeStartingReplacementAndReleasesTheHandle() {
    let trace = ServiceTrace()
    weak var camera: TracedService?
    let runtime = FeatureRuntime { service in
        let handle = TracedService(String(describing: service), trace)
        if service == .camera { camera = handle }
        return handle
    }
    var config = FeatureConfiguration()
    config.notchEnabled = true
    config.enabledWidgets = [.mirror]
    var demand = FeatureDemand(configuration: config, visibleWidget: .mirror, cameraAllowed: true)
    #expect(runtime.apply(demand).isEmpty)
    #expect(camera != nil)
    #expect(runtime.apply(demand).isEmpty)
    #expect(trace.entries == ["start.camera"])
    demand.configuration.enabledWidgets = [.clipboard]
    demand.visibleWidget = .clipboard
    runtime.apply(demand)
    #expect(trace.entries == ["start.camera", "stop.camera", "start.clipboard"])
    #expect(camera == nil)
    runtime.stop()
    #expect(runtime.active.isEmpty)
    #expect(trace.entries.last == "stop.clipboard")
    runtime.stop()
    #expect(trace.entries.count == 4)
}

@Test @MainActor func unavailableFeatureDoesNotPreventIndependentServiceAndRetry() {
    enum Unavailable: Error { case camera }
    var unavailable = true
    let trace = ServiceTrace()
    let runtime = FeatureRuntime { service in
        if service == .camera, unavailable { throw Unavailable.camera }
        return TracedService(String(describing: service), trace)
    }
    var config = FeatureConfiguration()
    config.notchEnabled = true
    config.enabledWidgets = [.mirror, .clipboard]
    let demand = FeatureDemand(configuration: config, visibleWidget: .mirror, cameraAllowed: true)
    #expect(runtime.apply(demand) == [.camera])
    #expect(runtime.active == [.clipboard])
    unavailable = false
    #expect(runtime.apply(demand).isEmpty)
    #expect(runtime.active == [.camera, .clipboard])
    #expect(trace.entries == ["start.clipboard", "start.camera"])
    runtime.stop()
}
