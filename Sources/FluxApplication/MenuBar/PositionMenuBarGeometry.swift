import AppKit
import FluxCore
import FluxPlatform

struct PositionMenuBarApplication {
    let id: ApplicationID
    let name: String
    let icon: NSImage?
    let frames: [CGRect?]
    let systemItems: [SystemMenuItem?]

    init(id: ApplicationID, name: String, icon: NSImage?, frames: [CGRect?], systemItems: [SystemMenuItem?] = []) {
        self.id = id
        self.name = name
        self.icon = icon
        self.frames = frames
        self.systemItems = systemItems
    }
}

struct PositionMenuBarInventory {
    let applications: [PositionMenuBarApplication]
    let accessibilityAllowed: Bool
    let complete: Bool
}

struct PositionMenuBarScreen: Equatable {
    /// Quartz points, with the origin at the primary display's top left.
    let frame: CGRect
    let menuBarHeight: CGFloat
}

/// Classifies owner geometry only. It does not claim that an icon is visible,
/// unobstructed, or saved by the owner. An uncertain app gets no assignment.
enum PositionMenuBarGeometry {
    static func assignments(
        applications: [PositionMenuBarApplication], hidden: CGRect?, always: CGRect?,
        screens: [PositionMenuBarScreen], alwaysEnabled: Bool
    ) -> [ApplicationID: MenuBarGroup] {
        guard let hidden, valid(hidden),
              let screen = singleScreen(containing: hidden, screens: screens),
              inMenuBar(hidden, screen: screen) else { return [:] }
        if alwaysEnabled {
            guard let always, valid(always), screen.frame.contains(always),
                  inMenuBar(always, screen: screen), always.maxX < hidden.minX else { return [:] }
        }
        let allFrames = applications.flatMap(\.frames).compactMap { $0 }
        var result: [ApplicationID: MenuBarGroup] = [:]
        let counts = Dictionary(grouping: applications, by: \.id).mapValues(\.count)
        for application in applications where counts[application.id] == 1 && !application.id.isManagedBySystem {
            guard !application.frames.isEmpty else { continue }
            var groups: [MenuBarGroup] = []
            for optionalFrame in application.frames {
                guard let frame = optionalFrame, valid(frame), screen.frame.contains(frame),
                      inMenuBar(frame, screen: screen), !frame.intersects(hidden),
                      !alwaysEnabled || !(always?.intersects(frame) ?? true),
                      allFrames.filter({ $0.intersects(frame) }).count == 1 else {
                    groups.removeAll()
                    break
                }
                if frame.minX >= hidden.maxX { groups.append(.shown) }
                else if frame.maxX <= hidden.minX {
                    if alwaysEnabled, let always {
                        if frame.maxX <= always.minX { groups.append(.alwaysHidden) }
                        else if frame.minX >= always.maxX { groups.append(.hidden) }
                        else { groups.removeAll(); break }
                    } else { groups.append(.hidden) }
                } else { groups.removeAll(); break }
            }
            if let first = groups.first, groups.count == application.frames.count,
               groups.allSatisfy({ $0 == first }) { result[application.id] = first }
        }
        return result
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0 && rect.size.width <= 512 && rect.size.height <= 128
    }

    private static func singleScreen(containing rect: CGRect, screens: [PositionMenuBarScreen]) -> PositionMenuBarScreen? {
        let matches = screens.filter { $0.frame.contains(rect) }
        return matches.count == 1 ? matches.first : nil
    }

    private static func inMenuBar(_ rect: CGRect, screen: PositionMenuBarScreen) -> Bool {
        let band = CGRect(x: screen.frame.minX, y: screen.frame.minY,
                          width: screen.frame.width, height: screen.menuBarHeight)
        return band.contains(rect)
    }
}
