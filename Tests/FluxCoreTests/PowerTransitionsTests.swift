import Testing
@testable import FluxCore

@Test func powerRestartsShowCurrentLowLevelAndNoFalsePlugEvent() {
    var router = PowerTransitions()
    #expect(router.accept(.init(percent: 18, charging: false, externalPower: false)) == [.low(18)])
    #expect(router.accept(.init(percent: 18, charging: false, externalPower: false)).isEmpty)
    #expect(router.accept(.init(percent: 17, charging: false, externalPower: false)) == [.low(17)])
    #expect(router.accept(.init(percent: 21, charging: false, externalPower: false)).isEmpty)
    #expect(router.accept(.init(percent: 25, charging: false, externalPower: false)) == [.recovered])
    #expect(router.accept(.init(percent: 20, charging: false, externalPower: false)) == [.low(20)])
    #expect(router.accept(.init(percent: 20, charging: true, externalPower: true)) == [.connected(20), .recovered])
    #expect(router.accept(.init(percent: 30, charging: false, externalPower: false)) == [.disconnected(30)])
}
