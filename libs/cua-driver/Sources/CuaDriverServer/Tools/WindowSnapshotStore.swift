import Foundation

actor WindowSnapshotStore {
    static let shared = WindowSnapshotStore()

    private var snapshots: [String: [ListWindowsTool.Row]] = [:]
    private var counter = 0

    func store(_ rows: [ListWindowsTool.Row]) -> String {
        counter += 1
        let token = "windows-\(counter)-\(UUID().uuidString)"
        snapshots[token] = rows
        if snapshots.count > 50 {
            for key in snapshots.keys.sorted().prefix(snapshots.count - 50) {
                snapshots.removeValue(forKey: key)
            }
        }
        return token
    }

    func rows(for token: String) -> [ListWindowsTool.Row]? {
        snapshots[token]
    }
}
