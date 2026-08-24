import Foundation
import SwiftData

// MARK: - Enums

enum TaskContext: String, Codable, CaseIterable, Identifiable {
    case school = "School"
    case work = "Work"
    case personal = "Personal"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .school: return "book.fill"
        case .work: return "briefcase.fill"
        case .personal: return "person.fill"
        }
    }
}

enum TaskSource: String, Codable {
    case manual
    case bulkEntry
    /// Stamped out automatically from a TaskTemplate.
    case recurring
}

// MARK: - Task

@Model
final class FilumaTask {
    var id: UUID
    var title: String
    var context: TaskContext
    var deadline: Date
    var effortMinutes: Int
    var isComplete: Bool
    var userModified: Bool
    var source: TaskSource
    /// Self-reported completion (0–100) from work sessions; combined with
    /// block-based progress, whichever is further along.
    var manualProgressPercent: Int = 0
    /// The tiny concrete opening move ("open the doc, paste the data table").
    /// "Write lab report" is un-startable; the first physical action isn't.
    /// Cleared automatically after the first work session — its job is done.
    var firstStep: String? = nil
    /// When the task was completed. Completed tasks are kept as history so the
    /// planned-vs-actual record can inform future estimates (EstimateAdvisor).
    var completedAt: Date? = nil
    /// The recurring template this task was stamped from, when it was.
    /// Lets "Stop repeating" find and end the recurrence from any occurrence.
    var templateId: UUID? = nil

    @Relationship(deleteRule: .cascade, inverse: \ScheduledBlock.task)
    var scheduledBlocks: [ScheduledBlock]

    @Relationship(deleteRule: .cascade, inverse: \WorkSession.task)
    var workSessions: [WorkSession] = []

    init(
        title: String,
        context: TaskContext,
        deadline: Date,
        effortMinutes: Int,
        source: TaskSource = .manual,
        firstStep: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.context = context
        self.deadline = deadline
        self.effortMinutes = effortMinutes
        self.isComplete = false
        self.userModified = false
        self.source = source
        self.manualProgressPercent = 0
        self.firstStep = firstStep
        self.scheduledBlocks = []
        self.workSessions = []
    }

    /// Minutes recorded by checked-off blocks that do not already have a timed
    /// session. A linked session is the canonical record for that block, so the
    /// reservation is not counted a second time.
    var workedBlockMinutes: Int {
        let timedBlockIds = Set(workSessions.compactMap(\.scheduledBlockId))
        return scheduledBlocks
            .filter { $0.isComplete && !timedBlockIds.contains($0.id) }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    /// Actual minutes worked: timed sessions plus checked-off blocks that do
    /// not have a linked timed session.
    var timeSpentMinutes: Int {
        workSessions.reduce(0) { $0 + ($1.durationSeconds + 30) / 60 } + workedBlockMinutes
    }

    var isOverBudget: Bool {
        timeSpentMinutes > effortMinutes
    }

    /// Effort considered done — self-reported progress only.
    var effectiveCompletedMinutes: Int {
        effortMinutes * min(100, max(0, manualProgressPercent)) / 100
    }

    /// 0.0–1.0 for progress bars.
    var progressFraction: Double {
        guard effortMinutes > 0 else { return 0 }
        return min(1.0, Double(effectiveCompletedMinutes) / Double(effortMinutes))
    }

    var progressPercent: Int {
        Int((progressFraction * 100).rounded())
    }

    var remainingMinutes: Int {
        max(0, effortMinutes - effectiveCompletedMinutes)
    }

    var nextBlock: ScheduledBlock? {
        scheduledBlocks
            .filter { !$0.isComplete && $0.endTime > Date() }
            .sorted { $0.startTime < $1.startTime }
            .first
    }

    /// Minutes of not-yet-completed work that still have a future block reserved.
    var futureScheduledMinutes: Int {
        let now = Date()
        return scheduledBlocks
            .filter { !$0.isComplete && $0.endTime > now }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    var isFullyScheduled: Bool {
        futureScheduledMinutes >= remainingMinutes
    }
}

// MARK: - ScheduledBlock

@Model
final class ScheduledBlock {
    var id: UUID
    var task: FilumaTask?
    var startTime: Date
    var durationMinutes: Int
    var isComplete: Bool
    var isLocked: Bool
    var appleCalendarEventId: String?
    /// Mirrors `appleCalendarEventId` for the Google export.
    var googleCalendarEventId: String? = nil

    init(
        task: FilumaTask,
        startTime: Date,
        durationMinutes: Int
    ) {
        self.id = UUID()
        self.task = task
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.isComplete = false
        self.isLocked = false
        self.appleCalendarEventId = nil
        self.googleCalendarEventId = nil
    }

    var endTime: Date {
        startTime.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }
}

// MARK: - WorkSession

@Model
final class WorkSession {
    var id: UUID
    var task: FilumaTask?
    var startedAt: Date
    var durationSeconds: Int
    /// The reservation this timer was started inside, when there was one.
    /// Optional with an inline default so existing stores migrate safely.
    var scheduledBlockId: UUID? = nil

    init(
        id: UUID = UUID(),
        task: FilumaTask,
        startedAt: Date,
        durationSeconds: Int,
        scheduledBlockId: UUID? = nil
    ) {
        self.id = id
        self.task = task
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.scheduledBlockId = scheduledBlockId
    }
}

// MARK: - BlockedTime

/// A recurring window (class, standup, commute…) the scheduler must not book over.
@Model
final class BlockedTime {
    var id: UUID
    var label: String
    /// Calendar weekdays this repeats on (1 = Sunday … 7 = Saturday).
    var weekdays: [Int]
    var startHour: Int
    var startMinute: Int
    var durationMinutes: Int

    init(
        label: String,
        weekdays: [Int],
        startHour: Int,
        startMinute: Int,
        durationMinutes: Int
    ) {
        self.id = UUID()
        self.label = label
        self.weekdays = weekdays
        self.startHour = startHour
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
    }

    /// Human label for the repeat pattern ("Daily", "Weekdays", "Mon, Wed"…).
    var repeatLabel: String {
        let set = Set(weekdays)
        if set == Set(1...7) { return "Daily" }
        if set == Set(2...6) { return "Weekdays" }
        if set == Set([1, 7]) { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted()
            .compactMap { $0 >= 1 && $0 <= 7 ? symbols[$0 - 1] : nil }
            .joined(separator: ", ")
    }

    /// Concrete occurrences of this window between two dates.
    func occurrences(from: Date, to: Date, calendar: Calendar = .current) -> [DateInterval] {
        guard durationMinutes > 0, !weekdays.isEmpty else { return [] }
        var result: [DateInterval] = []
        var day = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        while day <= lastDay {
            if weekdays.contains(calendar.component(.weekday, from: day)),
               let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day) {
                let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
                if end > from && start < to {
                    result.append(DateInterval(start: start, end: end))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

// MARK: - TaskTemplate

/// A weekly-recurring capture: problem sets, readings, chores. The template
/// itself never appears in the task list — on foreground refresh it stamps
/// out real FilumaTasks a rolling two weeks ahead (see
/// `SchedulerService.materializeRecurringTasks`), then deletes itself once
/// `repeatUntil` passes.
@Model
final class TaskTemplate {
    var id: UUID
    var title: String
    var context: TaskContext
    var effortMinutes: Int
    var firstStep: String?
    /// Deadline of the next occurrence to materialize; advances by 7 days
    /// per stamped task.
    var nextDeadline: Date
    /// The recurrence ends after this date (inclusive).
    var repeatUntil: Date

    init(
        title: String,
        context: TaskContext,
        effortMinutes: Int,
        firstStep: String? = nil,
        nextDeadline: Date,
        repeatUntil: Date
    ) {
        self.id = UUID()
        self.title = title
        self.context = context
        self.effortMinutes = effortMinutes
        self.firstStep = firstStep
        self.nextDeadline = nextDeadline
        self.repeatUntil = repeatUntil
    }
}

// MARK: - Reminder

/// A one-off, point-in-time reminder with a local notification. Deliberately
/// not a task: no effort, no blocks, no scheduling; just a nudge at a time.
@Model
final class Reminder {
    var id: UUID
    var title: String
    var dueDate: Date
    var isComplete: Bool
    /// Identifier of the pending local notification, for cancellation.
    var notificationId: String

    init(title: String, dueDate: Date) {
        self.id = UUID()
        self.title = title
        self.dueDate = dueDate
        self.isComplete = false
        self.notificationId = UUID().uuidString
    }
}

// MARK: - BusyEvent

enum BusySource: String, Codable {
    case appleCalendar
    case googleCalendar
}

/// A concrete busy window imported from an external calendar. Occupies
/// scheduler slots and shows on the schedule, but is deliberately not a task —
/// it never appears in the task list and carries no effort or progress.
@Model
final class BusyEvent {
    var id: UUID
    var source: BusySource
    /// The external event identifier — re-imports upsert on this, never duplicate.
    var sourceId: String
    var title: String
    var startTime: Date
    var endTime: Date
    var calendarName: String?

    init(
        source: BusySource,
        sourceId: String,
        title: String,
        startTime: Date,
        endTime: Date,
        calendarName: String? = nil
    ) {
        self.id = UUID()
        self.source = source
        self.sourceId = sourceId
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.calendarName = calendarName
    }
}

// MARK: - Start streak

/// Streaks that count *initiation*, not completion — starting is the actual
/// disorder-level challenge. A couple of free "mend" days per week keep one
/// bad day from torching the whole thread (broken-streak despair is the
/// classic ADHD streak-app failure). Lives here rather than in Insights so
/// the widget target can compute it too.
struct StreakCalculator {

    /// Length in days of the current chain of "days with at least one work
    /// session start", walking back from today. Rules:
    /// - Today without a start yet neither counts nor breaks — the day isn't over.
    /// - Up to `weeklyMends` startless days per calendar week are mended: they
    ///   keep the chain alive and count toward its length, but only when they
    ///   actually bridge to an earlier start day — mends that dead-end into a
    ///   break must not inflate the count.
    static func startStreak(
        startDates: [Date],
        now: Date = Date(),
        calendar: Calendar = .current,
        weeklyMends: Int = 2
    ) -> Int {
        let startDays = Set(startDates.map { calendar.startOfDay(for: $0) })
        guard let earliest = startDays.min() else { return 0 }

        var cursor = calendar.startOfDay(for: now)
        if !startDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                return 0
            }
            cursor = yesterday
        }

        var streak = 0
        var pendingMends = 0
        var mendsUsedByWeek: [Int: Int] = [:]

        while cursor >= earliest {
            if startDays.contains(cursor) {
                streak += 1 + pendingMends
                pendingMends = 0
            } else {
                let comps = calendar.dateComponents(
                    [.weekOfYear, .yearForWeekOfYear], from: cursor
                )
                let weekKey = (comps.yearForWeekOfYear ?? 0) * 100 + (comps.weekOfYear ?? 0)
                guard mendsUsedByWeek[weekKey, default: 0] < weeklyMends else { break }
                mendsUsedByWeek[weekKey, default: 0] += 1
                pendingMends += 1
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        return streak
    }
}

// MARK: - UserSettings

/// The scheduling values a brand-new Filuma plan starts from.
///
/// Keep this outside `UserSettings` so changing how onboarding applies the
/// defaults never changes the SwiftData model schema.
struct UserSettingsSchedulingDefaults: Equatable, Sendable {
    let wakeHour: Int
    let wakeMinute: Int
    let sleepHour: Int
    let sleepMinute: Int
    let minBlockMinutes: Int
    let maxBlockMinutes: Int
    let deadlineBufferMinutes: Int
    let startBufferMinutes: Int

    static let fresh = UserSettingsSchedulingDefaults(
        wakeHour: 8,
        wakeMinute: 0,
        sleepHour: 23,
        sleepMinute: 0,
        minBlockMinutes: 30,
        maxBlockMinutes: 90,
        deadlineBufferMinutes: 120,
        startBufferMinutes: 15
    )
}

@Model
final class UserSettings {
    var id: UUID
    var wakeHour: Int
    var wakeMinute: Int
    var sleepHour: Int
    var sleepMinute: Int
    var minBlockMinutes: Int
    var maxBlockMinutes: Int
    var deadlineBufferMinutes: Int
    /// Breathing room before the first block of newly scheduled work — nothing
    /// gets booked to start "right now" unless the user explicitly asks.
    var startBufferMinutes: Int = 15
    /// Max minutes of task blocks the scheduler may place on a single day. 0 = no limit.
    var dailyFocusMinutes: Int = 0
    /// The last plan state where automatic scheduling proved no more work fit.
    /// Optional with an inline default so existing stores migrate safely.
    var lastFutileAutomaticRebalanceFingerprint: String? = nil
    /// A planning preference was accepted but its derived plan has not yet
    /// committed. Persisting this intent lets the next foreground launch retry
    /// after a save failure or termination instead of stranding old blocks.
    var planningRebuildPending: Bool = false
    var exportToAppleCalendar: Bool
    /// One-way import: Apple Calendar events become BusyEvents the scheduler avoids.
    var importFromAppleCalendar: Bool = false
    /// Calendars the user opted out of importing (EKCalendar identifiers).
    var excludedCalendarIds: [String] = []
    var filumaCalendarIdentifier: String?
    // Google Calendar — the OAuth mirror of the Apple pair above. Tokens live
    // in the Keychain; these fields hold the sync state and display data.
    var importFromGoogleCalendar: Bool = false
    var exportToGoogleCalendar: Bool = false
    /// Incremental cursor from events.list; nil forces a full window fetch.
    var googleSyncToken: String? = nil
    /// The connected account, shown in Settings. Nil means not connected.
    var googleAccountEmail: String? = nil
    /// The refresh token expired or was revoked — surface "Reconnect Google".
    var googleNeedsReconnect: Bool = false
    var hasCompletedOnboarding: Bool = false
    /// Nudge when a scheduled block begins (the anti-time-blindness alarm).
    var blockRemindersEnabled: Bool = true
    /// Extra heads-up this many minutes before a block starts. 0 = off.
    var blockReminderLeadMinutes: Int = 0
    /// Morning preview notification (wake time + 30 min): the day's shape,
    /// pre-loaded before the day ambushes you.
    var morningPreviewEnabled: Bool = true
    /// Evening wrap-up notification: what got done, what tomorrow opens with.
    var eveningReviewEnabled: Bool = true
    var eveningReviewHour: Int = 21
    var eveningReviewMinute: Int = 30

    init() {
        let schedulingDefaults = UserSettingsSchedulingDefaults.fresh
        self.id = UUID()
        self.wakeHour = schedulingDefaults.wakeHour
        self.wakeMinute = schedulingDefaults.wakeMinute
        self.sleepHour = schedulingDefaults.sleepHour
        self.sleepMinute = schedulingDefaults.sleepMinute
        self.minBlockMinutes = schedulingDefaults.minBlockMinutes
        self.maxBlockMinutes = schedulingDefaults.maxBlockMinutes
        self.deadlineBufferMinutes = schedulingDefaults.deadlineBufferMinutes
        self.startBufferMinutes = schedulingDefaults.startBufferMinutes
        self.dailyFocusMinutes = 0
        self.lastFutileAutomaticRebalanceFingerprint = nil
        self.planningRebuildPending = false
        self.exportToAppleCalendar = false
        self.importFromAppleCalendar = false
        self.excludedCalendarIds = []
        self.filumaCalendarIdentifier = nil
        self.importFromGoogleCalendar = false
        self.exportToGoogleCalendar = false
        self.googleSyncToken = nil
        self.googleAccountEmail = nil
        self.googleNeedsReconnect = false
        self.hasCompletedOnboarding = false
        self.blockRemindersEnabled = true
        self.blockReminderLeadMinutes = 0
        self.morningPreviewEnabled = true
        self.eveningReviewEnabled = true
        self.eveningReviewHour = 21
        self.eveningReviewMinute = 30
    }

    /// Restores only the fresh-plan scheduling choices. Notification,
    /// calendar, and onboarding state remain exactly as the user left them.
    func applyRecommendedSchedulingDefaults() {
        let schedulingDefaults = UserSettingsSchedulingDefaults.fresh
        wakeHour = schedulingDefaults.wakeHour
        wakeMinute = schedulingDefaults.wakeMinute
        sleepHour = schedulingDefaults.sleepHour
        sleepMinute = schedulingDefaults.sleepMinute
        minBlockMinutes = schedulingDefaults.minBlockMinutes
        maxBlockMinutes = schedulingDefaults.maxBlockMinutes
        deadlineBufferMinutes = schedulingDefaults.deadlineBufferMinutes
        startBufferMinutes = schedulingDefaults.startBufferMinutes
    }

    var wakeTime: DateComponents {
        DateComponents(hour: wakeHour, minute: wakeMinute)
    }

    var sleepTime: DateComponents {
        DateComponents(hour: sleepHour, minute: sleepMinute)
    }

    /// The single settings row, created on first use. Always fetch through here
    /// so the app can't end up with competing duplicates.
    static func fetchOrCreate(in context: ModelContext) -> UserSettings {
        let descriptor = FetchDescriptor<UserSettings>()
        if let existing = (try? context.fetch(descriptor))?.first {
            return existing
        }
        let fresh = UserSettings()
        context.insert(fresh)
        return fresh
    }
}
