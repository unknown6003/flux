import Foundation
import FluxCore

public struct MenuBarOrderVisibilityEdit: Sendable {
    let id: UUID
    let applications: Set<ApplicationID>
}

/// A short visibility lease for the icons named by one Settings move.
/// Its journal restores only flags that Flux changed from false to true.
public actor MenuBarOrderVisibilityStore {
    private let preferences: MenuBarContainerPreferences
    private let journal: UserDefaults
    private let journalKey = "flux.menuBar.orderVisibilityLease.v1"
    private var activeID: UUID?

    public init(journalDomain: String = "com.flux.menubar") {
        preferences = MenuBarContainerPreferences(domain: "group.com.apple.controlcenter", key: "trackedApplications",
            container: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter"))
        journal = UserDefaults(suiteName: journalDomain) ?? .standard
    }

    init(domain: String, container: URL, journalDomain: String) {
        preferences = MenuBarContainerPreferences(domain: domain, key: "trackedApplications", container: container)
        journal = UserDefaults(suiteName: journalDomain)!
    }

    public func recover() throws {
        guard activeID == nil, let stored = journal.object(forKey: journalKey) else { return }
        guard let names = stored as? [String], names.count <= 128 else { throw MenuBarMoveFailure.orderVisibilityRestoreFailed }
        if names.isEmpty { journal.removeObject(forKey: journalKey); return }
        let applications = Set(names.compactMap(ApplicationID.init(rawValue:)))
        guard applications.count == names.count, applications.allSatisfy({ $0.canBeHidden }) else {
            throw MenuBarMoveFailure.orderVisibilityRestoreFailed
        }
        try restore(applications)
        journal.removeObject(forKey: journalKey)
    }

    public func begin(_ applications: Set<ApplicationID>) throws -> MenuBarOrderVisibilityEdit? {
        try Task.checkCancellation()
        guard activeID == nil else { throw MenuBarMoveFailure.notAccepted }
        try recover()
        var rows = try read()
        let eligible = applications.filter(\.canBeHidden)
        let changed = try change(&rows, applications: Set(eligible), from: false, to: true)
        guard !changed.isEmpty else { return nil }
        let edit = MenuBarOrderVisibilityEdit(id: UUID(), applications: changed)
        journal.set(changed.map(\.rawValue).sorted(), forKey: journalKey)
        activeID = edit.id
        do { try write(rows) }
        catch {
            try finish(edit)
            throw error
        }
        return edit
    }

    public func finish(_ edit: MenuBarOrderVisibilityEdit) throws {
        guard activeID == edit.id else { return }
        do { try restore(edit.applications) }
        catch { activeID = nil; throw MenuBarMoveFailure.orderVisibilityRestoreFailed }
        journal.removeObject(forKey: journalKey)
        activeID = nil
    }

    private func restore(_ applications: Set<ApplicationID>) throws {
        var rows = try read()
        let changed = try change(&rows, applications: applications, from: true, to: false)
        if !changed.isEmpty { try write(rows) }
    }

    private func read() throws -> [Any] {
        guard let data = preferences.read() as? Data else { throw MenuBarMoveFailure.orderVisibilityAccessRequired }
        guard data.count <= 2_097_152,
              let rows = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [Any],
              rows.count <= 4096 else { throw MenuBarMoveFailure.positionIdentityUnavailable }
        return rows
    }

    private func change(_ rows: inout [Any], applications: Set<ApplicationID>, from: Bool, to: Bool) throws -> Set<ApplicationID> {
        var changed: Set<ApplicationID> = []
        for application in applications {
            let matches = rows.indices.filter { index in
                guard let row = rows[index] as? [String: Any], row["isAllowed"] != nil,
                      let location = row["location"] as? [String: Any],
                      let bundle = location["bundle"] as? [String: Any] else { return false }
                return bundle["_0"] as? String == application.rawValue
            }
            guard matches.count <= 1 else { throw MenuBarMoveFailure.positionIdentityUnavailable }
            guard let index = matches.first, var row = rows[index] as? [String: Any] else { continue }
            guard let flag = row["isAllowed"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                throw MenuBarMoveFailure.positionIdentityUnavailable
            }
            if flag.boolValue == from {
                row["isAllowed"] = to; rows[index] = row; changed.insert(application)
            }
        }
        return changed
    }

    private func write(_ rows: [Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0)
        guard preferences.write(data as CFData),
              let check = preferences.read() as? Data, check == data else { throw MenuBarMoveFailure.orderVisibilityRestoreFailed }
    }
}
