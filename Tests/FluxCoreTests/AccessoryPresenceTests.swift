import Testing
@testable import FluxCore

@Test func accessoryAliasesDoNotCreateStartupOrFalseDisconnectNotices() {
    let headset = Accessory(name: "Ammar’s AirPods", kind: .audio, percent: nil)
    let hid = Accessory(name: "Ammar’s AirPods", kind: .audio, percent: 74)
    let keyboard = Accessory(name: "Keyboard", kind: .keyboard, percent: nil)
    var presence = AccessoryPresence()
    #expect(presence.accept(nil).isEmpty)
    #expect(presence.accept([headset, hid]).isEmpty)
    #expect(presence.accept([hid]).isEmpty)
    #expect(presence.accept(nil).isEmpty)
    #expect(presence.accept([hid, keyboard]) == [.connected(keyboard)])
    #expect(presence.accept([keyboard]) == [.disconnected(hid)])
    #expect(presence.accept([]) == [.disconnected(keyboard)])
}

@Test func accessoryDisplayValuesStayBounded() {
    let accessory = Accessory(name: String(repeating: "a", count: 1000), kind: .mouse, percent: 1000)
    #expect(accessory.name.count == 200)
    #expect(accessory.percent == 100)
    #expect(accessory.symbol == "computermouse")
}
