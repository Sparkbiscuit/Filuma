import Foundation
import UIKit
@preconcurrency import UserNotifications
import SwiftData

// MARK: - Block-start nudges

/// Local notifications when a scheduled block begins — the anti-time-blindness
/// alarm. The plan is useless if it only exists inside an app you're not
/// looking at. Notifications are re-synced after every scheduling change;
/// "Start Session" drops straight into the timer, "Snooze 10 min" re-pings
/// without moving the block.
enum BlockNotificationService {

    /// A single user-facing nudge preference change. Keeping the mutation as a
    /// value makes the SwiftData boundary explicit and gives Settings enough
    /// information to retry the exact rejected choice.
    enum PreferenceUpdate: Equatable {
        case blockRemindersEnabled(Bool)
        case blockReminderLeadMinutes(Int)
        case morningPreviewEnabled(Bool)
        case eveningReviewEnabled(Bool)
        case eveningReviewTime(hour: Int, minute: Int)

        var requiresAuthorization: Bool {
            switch self {
            case .blockRemindersEnabled(true),
                 .morningPreviewEnabled(true),
                 .eveningReviewEnabled(true):
                return true
            default:
                return false
            }
        }

        var failureMessage: String {
            switch self {
            case .blockRemindersEnabled:
                return "Filuma couldn’t save the block nudge setting, so it stayed where it was. Try again."
            case .blockReminderLeadMinutes:
                return "Filuma couldn’t save the early heads-up time, so the previous time is still in use. Try again."
            case .morningPreviewEnabled:
                return "Filuma couldn’t save the morning preview setting, so it stayed where it was. Try again."
            case .eveningReviewEnabled:
                return "Filuma couldn’t save the evening wrap-up setting, so it stayed where it was. Try again."
            case .eveningReviewTime:
                return "Filuma couldn’t save the wrap-up time, so the previous time is still in use. Try again."
            }
        }

        fileprivate func apply(to settings: UserSettings) {
            switch self {
            case .blockRemindersEnabled(let enabled):
                settings.blockRemindersEnabled = enabled
            case .blockReminderLeadMinutes(let minutes):
                settings.blockReminderLeadMinutes = minutes
            case .morningPreviewEnabled(let enabled):
                settings.morningPreviewEnabled = enabled
            case .eveningReviewEnabled(let enabled):
                settings.eveningReviewEnabled = enabled
            case .eveningReviewTime(let hour, let minute):
                settings.eveningReviewHour = hour
                settings.eveningReviewMinute = minute
            }
        }
    }

    private struct HeldPreferences {
        let blockRemindersEnabled: Bool
        let blockReminderLeadMinutes: Int
        let morningPreviewEnabled: Bool
        let eveningReviewEnabled: Bool
        let eveningReviewHour: Int
        let eveningReviewMinute: Int

        init(_ settings: UserSettings) {
            blockRemindersEnabled = settings.blockRemindersEnabled
            blockReminderLeadMinutes = settings.blockReminderLeadMinutes
            morningPreviewEnabled = settings.morningPreviewEnabled
            eveningReviewEnabled = settings.eveningReviewEnabled
            eveningReviewHour = settings.eveningReviewHour
            eveningReviewMinute = settings.eveningReviewMinute
        }

        func repair(_ settings: UserSettings) {
            settings.blockRemindersEnabled = blockRemindersEnabled
            settings.blockReminderLeadMinutes = blockReminderLeadMinutes
            settings.morningPreviewEnabled = morningPreviewEnabled
            settings.eveningReviewEnabled = eveningReviewEnabled
            settings.eveningReviewHour = eveningReviewHour
            settings.eveningReviewMinute = eveningReviewMinute
        }
    }

    static let categoryId = "FILUMA_BLOCK_START"
    static let startActionId = "FILUMA_START_SESSION"
    static let snoozeActionId = "FILUMA_SNOOZE_10"
    private static let idPrefix = "block-"
    private static let digestIdPrefix = "digest-"

    /// Pending-notification budget (iOS caps at 64 per app; reminders need room too).
    private static let maxBlocks = 20
    private static let horizonDays = 3
    private static let pendingRequestTarget = 55
    private static let directRequestThreshold = 60

    @MainActor private static var resyncGeneration: UInt = 0

    /// Durably commit one nudge preference, then reconcile system
    /// notifications. The preflight accepts unrelated pending work before the
    /// rollback boundary; a rejected transaction repairs every held nudge
    /// field and never reaches Notification Center.
    @MainActor
    static func updatePreference(
        _ update: PreferenceUpdate,
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() },
        reconcile: @MainActor (ModelContext) -> Void = { context in
            resync(context: context)
        }
    ) throws {
        try context.save()
        let held = HeldPreferences(settings)

        do {
            try context.transaction {
                update.apply(to: settings)
                try save(context)
            }
        } catch {
            context.rollback()
            held.repair(settings)
            context.processPendingChanges()
            throw error
        }

        // This intentionally runs outside the SwiftData transaction. System
        // notification work is asynchronous and cannot be part of rollback.
        reconcile(context)
    }

    private static func isResyncOwnedIdentifier(_ identifier: String) -> Bool {
        if identifier.hasPrefix(digestIdPrefix) { return true }
        return identifier.hasPrefix(idPrefix) && !identifier.hasPrefix("\(idPrefix)snooze-")
    }

    struct BlockAlertCandidate: Equatable {
        let identifier: String
        let fireDate: Date
        let isLead: Bool
    }

    /// Keeps starts ahead of heads-ups, while reserving room for digests and
    /// pending reminders/snoozes that this service does not own.
    static func selectBlockAlerts(
        candidates: [BlockAlertCandidate],
        digestCount: Int,
        otherPendingCount: Int
    ) -> [BlockAlertCandidate] {
        let available = max(
            0,
            pendingRequestTarget - max(0, digestCount) - max(0, otherPendingCount)
        )
        return candidates.sorted { lhs, rhs in
            if lhs.isLead != rhs.isLead { return !lhs.isLead }
            if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
            return lhs.identifier < rhs.identifier
        }
        .prefix(available)
        .map { $0 }
    }

    private struct BlockSnapshot {
        let id: UUID
        let taskId: UUID
        let title: String
        let start: Date
        let minutes: Int
        let firstStep: String?
    }

    static func registerCategory() {
        let start = UNNotificationAction(
            identifier: startActionId,
            title: "Start Session",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: snoozeActionId,
            title: "Snooze 10 min",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [start, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Rebuild the pending block notifications and daily digests from the
    /// current schedule.
    @MainActor
    static func resync(context: ModelContext) {
        resyncGeneration &+= 1
        let generation = resyncGeneration
        let settings = UserSettings.fetchOrCreate(in: context)
        let enabled = settings.blockRemindersEnabled
        let leadMinutes = settings.blockReminderLeadMinutes

        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: horizonDays, to: now) else { return }
        let allBlocks = (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? []

        let snapshots: [BlockSnapshot] = allBlocks
            .filter { block in
                guard !block.isComplete,
                      block.startTime > now.addingTimeInterval(60),
                      block.startTime < horizon,
                      let task = block.task, !task.isComplete else { return false }
                return true
            }
            .sorted { $0.startTime < $1.startTime }
            .prefix(maxBlocks)
            .compactMap { block in
                guard let task = block.task else { return nil }
                return BlockSnapshot(
                    id: block.id,
                    taskId: task.id,
                    title: task.title,
                    start: block.startTime,
                    minutes: block.durationMinutes,
                    firstStep: task.firstStep
                )
            }

        let digests = digestRequests(settings: settings, allBlocks: allBlocks, now: now)
        var requestsByIdentifier: [String: UNNotificationRequest] = [:]
        var candidates: [BlockAlertCandidate] = []
        if enabled {
            for snapshot in snapshots {
                let startRequest = request(for: snapshot, leadMinutes: 0)
                requestsByIdentifier[startRequest.identifier] = startRequest
                candidates.append(BlockAlertCandidate(
                    identifier: startRequest.identifier,
                    fireDate: snapshot.start,
                    isLead: false
                ))
                if leadMinutes > 0 {
                    let leadRequest = request(for: snapshot, leadMinutes: leadMinutes)
                    requestsByIdentifier[leadRequest.identifier] = leadRequest
                    candidates.append(BlockAlertCandidate(
                        identifier: leadRequest.identifier,
                        fireDate: snapshot.start.addingTimeInterval(TimeInterval(-leadMinutes * 60)),
                        isLead: true
                    ))
                }
            }
        }

        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let pending = await center.pendingNotificationRequests()
            guard generation == resyncGeneration else { return }

            let stale = pending.map(\.identifier).filter(isResyncOwnedIdentifier)
            guard enabled || !digests.isEmpty else {
                center.removePendingNotificationRequests(withIdentifiers: stale)
                return
            }

            let notifSettings = await center.notificationSettings()
            guard generation == resyncGeneration else { return }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            guard notifSettings.authorizationStatus == .authorized else { return }

            let otherPendingCount = pending.filter {
                !isResyncOwnedIdentifier($0.identifier)
            }.count
            let selected = selectBlockAlerts(
                candidates: candidates,
                digestCount: digests.count,
                otherPendingCount: otherPendingCount
            )

            enqueue(digests, on: center)
            enqueue(selected.compactMap { requestsByIdentifier[$0.identifier] }, on: center)
        }
    }

    /// Uses the callback API so a current generation enqueues its whole batch
    /// without yielding back to another resync between individual requests.
    private static func enqueue(
        _ requests: [UNNotificationRequest],
        on center: UNUserNotificationCenter
    ) {
        for request in requests {
            center.add(request)
        }
    }

    // MARK: - Daily digests

    /// One block's worth of digest input — a plain value so the copy builders
    /// below stay pure and testable.
    struct DigestBlock {
        let title: String
        let start: Date
        let end: Date
        let isComplete: Bool
    }

    /// Morning preview: the day's shape, pre-loaded before the day ambushes
    /// you. Nil when the day holds no blocks — no content, no notification.
    static func morningDigestBody(dayBlocks: [DigestBlock]) -> String? {
        let ordered = dayBlocks.sorted { $0.start < $1.start }
        guard let first = ordered.first,
              let doneBy = ordered.map(\.end).max() else { return nil }
        let clock = TimeFormatter.clock
        if ordered.count == 1 {
            return "One block today: \(clock.string(from: first.start)) \(first.title). Done by \(clock.string(from: doneBy))."
        }
        return "First block: \(clock.string(from: first.start)) \(first.title). \(ordered.count) blocks total, done by \(clock.string(from: doneBy))."
    }

    /// Evening wrap-up: what happened today and what tomorrow opens with —
    /// working memory, externalized across the day boundary. Nil when there's
    /// nothing to say on either side.
    static func eveningDigestBody(todayBlocks: [DigestBlock], tomorrowFirst: DigestBlock?) -> String? {
        var parts: [String] = []
        if !todayBlocks.isEmpty {
            let done = todayBlocks.filter(\.isComplete).count
            if done == todayBlocks.count && done > 0 {
                parts.append(done == 1 ? "You finished today's block." : "You finished all \(done) blocks today.")
            } else {
                parts.append("You finished \(done) of \(todayBlocks.count) blocks today.")
            }
        }
        if let first = tomorrowFirst {
            parts.append("Tomorrow starts with \(first.title) at \(TimeFormatter.clock.string(from: first.start)).")
        } else if !todayBlocks.isEmpty {
            parts.append("Nothing is scheduled for tomorrow yet — add a task if something's coming up.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static let digestDayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    /// Build the pending morning/evening digest notifications for the next
    /// few days from the current schedule. Content is a snapshot from resync
    /// time; resync runs on every schedule change, so it stays fresh.
    private static func digestRequests(
        settings: UserSettings,
        allBlocks: [ScheduledBlock],
        now: Date
    ) -> [UNNotificationRequest] {
        guard settings.morningPreviewEnabled || settings.eveningReviewEnabled else { return [] }
        let calendar = Calendar.current

        // Evening counts include checked blocks of since-completed tasks;
        // the morning preview only lists work still ahead.
        let withTask = allBlocks.filter { $0.task != nil }
        func digestBlocks(on day: Date, upcomingOnly: Bool) -> [DigestBlock] {
            withTask
                .filter { block in
                    calendar.isDate(block.startTime, inSameDayAs: day)
                        && (!upcomingOnly || (!block.isComplete && !(block.task?.isComplete ?? true)))
                }
                .map { block in
                    DigestBlock(
                        title: block.task?.title ?? "Task",
                        start: block.startTime,
                        end: block.endTime,
                        isComplete: block.isComplete
                    )
                }
        }

        var requests: [UNNotificationRequest] = []
        for offset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let key = digestDayKey.string(from: day)

            if settings.morningPreviewEnabled,
               let wake = calendar.date(
                   bySettingHour: settings.wakeHour,
                   minute: settings.wakeMinute,
                   second: 0, of: day
               ) {
                let fire = wake.addingTimeInterval(30 * 60)
                if fire > now,
                   let body = morningDigestBody(dayBlocks: digestBlocks(on: day, upcomingOnly: true)) {
                    requests.append(digestRequest(
                        id: "\(digestIdPrefix)morning-\(key)",
                        title: "Today, at a glance",
                        body: body,
                        fireDate: fire
                    ))
                }
            }

            if settings.eveningReviewEnabled,
               let fire = calendar.date(
                   bySettingHour: settings.eveningReviewHour,
                   minute: settings.eveningReviewMinute,
                   second: 0, of: day
               ),
               fire > now,
               let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) {
                let tomorrowFirst = digestBlocks(on: tomorrow, upcomingOnly: true)
                    .min { $0.start < $1.start }
                if let body = eveningDigestBody(
                    todayBlocks: digestBlocks(on: day, upcomingOnly: false),
                    tomorrowFirst: tomorrowFirst
                ) {
                    requests.append(digestRequest(
                        id: "\(digestIdPrefix)evening-\(key)",
                        title: "Evening wrap-up",
                        body: body,
                        fireDate: fire
                    ))
                }
            }
        }
        return requests
    }

    private static func digestRequest(
        id: String,
        title: String,
        body: String,
        fireDate: Date
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    /// Re-ping in 10 minutes without touching the schedule.
    static func snooze(from original: UNNotificationRequest) {
        guard let content = original.content.mutableCopy() as? UNMutableNotificationContent else { return }
        content.body = "Snooze is up — ready to start?"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10 * 60, repeats: false)
        let request = UNNotificationRequest(
            identifier: "snooze-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        addDirectRequestMakingRoom(request)
    }

    /// Direct notifications outrank an early heads-up when the pending queue
    /// is already close to iOS's hard cap.
    static func addDirectRequestMakingRoom(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let farthestLead = pending
                .filter { $0.identifier.hasPrefix(idPrefix) && $0.identifier.hasSuffix("-lead") }
                .max(by: { lhs, rhs in
                    let lhsDate = (lhs.trigger as? UNCalendarNotificationTrigger)?
                        .nextTriggerDate() ?? .distantPast
                    let rhsDate = (rhs.trigger as? UNCalendarNotificationTrigger)?
                        .nextTriggerDate() ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                    return lhs.identifier < rhs.identifier
                })
            if pending.count >= directRequestThreshold,
               !pending.contains(where: { $0.identifier == request.identifier }),
               let farthestLead {
                center.removePendingNotificationRequests(withIdentifiers: [farthestLead.identifier])
            }
            center.add(request)
        }
    }

    private static func request(for snapshot: BlockSnapshot, leadMinutes: Int) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = snapshot.title
        let length = snapshot.minutes < 60
            ? "\(snapshot.minutes)m"
            : "\(snapshot.minutes / 60)h\(snapshot.minutes % 60 > 0 ? " \(snapshot.minutes % 60)m" : "")"
        if leadMinutes > 0 {
            content.body = "\(length) block starts in \(leadMinutes) min. Wrap up what you're doing."
        } else if let step = snapshot.firstStep, !step.isEmpty {
            // The captured opening move beats a platitude: name the exact
            // physical action so the block is startable from the banner.
            content.body = "\(length) block starting now. First step: \(step)"
        } else {
            content.body = "\(length) block starting now. Even a small start counts."
        }
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.userInfo = ["taskId": snapshot.taskId.uuidString]

        let fireDate = snapshot.start.addingTimeInterval(TimeInterval(-leadMinutes * 60))
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let suffix = leadMinutes > 0 ? "-lead" : ""
        return UNNotificationRequest(
            identifier: "\(idPrefix)\(snapshot.id.uuidString)\(suffix)",
            content: content,
            trigger: trigger
        )
    }
}

// MARK: - Schedule-change hook

/// Everything that should happen after the plan changes: refresh widgets and
/// rebuild block nudges. `interactive` gates the one-time permission prompt to
/// user-initiated actions so it never appears out of nowhere at launch.
@MainActor
func scheduleDidChange(context: ModelContext, interactive: Bool = true) {
    PaceCache.invalidate()
    SharedStore.reloadWidgets()
    if interactive {
        Task { @MainActor in
            _ = await NotificationService.requestAuthorization()
            BlockNotificationService.resync(context: context)
        }
    } else {
        BlockNotificationService.resync(context: context)
    }
}

// MARK: - App delegate (notification actions + foreground banners)

final class FilumaAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by a notification tap before the SwiftUI tree may exist; consumed
    /// by MainTabView to open the work session.
    static var pendingSessionTaskId: UUID?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BlockNotificationService.registerCategory()
        return true
    }

    // Show banners even while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content

        if response.actionIdentifier == BlockNotificationService.snoozeActionId {
            BlockNotificationService.snooze(from: response.notification.request)
        } else if content.categoryIdentifier == BlockNotificationService.categoryId,
                  let idString = content.userInfo["taskId"] as? String,
                  let taskId = UUID(uuidString: idString) {
            // Default tap and "Start Session" both open the timer.
            Self.pendingSessionTaskId = taskId
            NotificationCenter.default.post(name: .filumaOpenWorkSession, object: nil)
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let filumaOpenWorkSession = Notification.Name("filumaOpenWorkSession")
}
