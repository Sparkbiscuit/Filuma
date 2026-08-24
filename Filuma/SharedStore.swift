import Foundation
import SwiftData
import WidgetKit

/// The SwiftData store lives in the App Group container so the widget
/// extension can read the schedule. Both targets build their containers
/// through here.
enum SharedStore {

    static let appGroupId = "group.com.christoforakis.Filuma"

    static let schema = Schema([
        FilumaTask.self,
        TaskTemplate.self,
        ScheduledBlock.self,
        WorkSession.self,
        BlockedTime.self,
        BusyEvent.self,
        Reminder.self,
        UserSettings.self
    ])

    static var storeURL: URL {
        if let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) {
            return base.appendingPathComponent("Filuma.store")
        }
        // No group entitlement (previews, misconfigured signing): stay local
        // rather than crash.
        return URL.applicationSupportDirectory.appendingPathComponent("Filuma.store")
    }

    static func makeContainer() throws -> ModelContainer {
        try migrateLegacyStoreIfNeeded()
        let configuration = ModelConfiguration(url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Pre-1.2 builds kept the store at SwiftData's default location inside
    /// the app sandbox. Copy it into the group container once, so updating
    /// doesn't lose data. (Runs as a no-op inside the widget, whose sandbox
    /// never had a legacy store.)
    static func migrateLegacyStoreIfNeeded() throws {
        let fileManager = FileManager.default
        let destination = storeURL
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let legacyBase = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: legacyBase.path) else { return }

        // A migration attempt that died mid-install can leave orphan sidecars
        // at the destination (the main file installs last). With the main
        // file absent they're garbage — clear them so this retry's moves
        // can't collide with them.
        for suffix in ["-shm", "-wal"] {
            let orphan = URL(fileURLWithPath: destination.path + suffix)
            if fileManager.fileExists(atPath: orphan.path) {
                try? fileManager.removeItem(at: orphan)
            }
        }

        // SQLite sidecars must travel with the main file. Install the main file
        // last so its presence marks a complete migration.
        let files = ["-shm", "-wal", ""].compactMap { suffix -> (URL, URL)? in
            let from = URL(fileURLWithPath: legacyBase.path + suffix)
            let to = URL(fileURLWithPath: destination.path + suffix)
            return fileManager.fileExists(atPath: from.path) ? (from, to) : nil
        }
        let migrationId = UUID().uuidString
        let stagedFiles = files.map { from, to in
            (from, to, URL(fileURLWithPath: to.path + ".migration-\(migrationId)"))
        }
        var installedFiles: [URL] = []

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for (from, _, staged) in stagedFiles {
                try fileManager.copyItem(at: from, to: staged)
            }
            for (_, to, staged) in stagedFiles {
                try fileManager.moveItem(at: staged, to: to)
                installedFiles.append(to)
            }
        } catch {
            for (_, _, staged) in stagedFiles {
                try? fileManager.removeItem(at: staged)
            }
            for installed in installedFiles {
                try? fileManager.removeItem(at: installed)
            }
            throw error
        }
    }

    /// Nudge home/lock screen widgets after anything that changes the schedule.
    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// A verified entitlement snapshot shared with extensions and App Intents.
/// The main app refreshes this value from StoreKit's signed transaction
/// sequence. Extensions use the last verified value because they cannot rely
/// on a live StoreKit query during every timeline render.
enum FilumaProAccess {
    static let entitlementKey = "filuma.pro.current-entitlement"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedStore.appGroupId) ?? .standard
    }

    static var isPro: Bool {
        defaults.bool(forKey: entitlementKey)
    }

    static func setVerifiedEntitlement(_ isPro: Bool) {
        guard defaults.bool(forKey: entitlementKey) != isPro else { return }
        defaults.set(isPro, forKey: entitlementKey)
        SharedStore.reloadWidgets()
    }
}

enum SubscriptionPolicy {
    static let freeActiveTaskLimit = 3

    static func canAddTasks(
        activeTaskCount: Int,
        requestedCount: Int,
        isPro: Bool
    ) -> Bool {
        guard requestedCount >= 0 else { return false }
        return isPro || activeTaskCount + requestedCount <= freeActiveTaskLimit
    }

    static func remainingFreeTasks(activeTaskCount: Int, isPro: Bool) -> Int? {
        guard !isPro else { return nil }
        return max(0, freeActiveTaskLimit - activeTaskCount)
    }
}
