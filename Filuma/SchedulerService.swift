import Foundation
import CryptoKit
import SwiftData

// MARK: - Scheduling Result

enum ScheduleResult {
    case success(blocks: [ScheduledBlock])
    case partialFit(scheduled: [ScheduledBlock], unscheduledMinutes: Int)
    case noSlots
}

/// Outcome of a catch-up pass over missed blocks.
struct CatchUpSummary: Equatable {
    /// Tasks whose coverage changed during this pass, whether because time
    /// elapsed or because their future plan was found short. This drives calm
    /// user feedback for every automatic plan change, not only one subtype.
    var adjustedTasks = 0
    /// Tasks whose missed work was fed back through the scheduler.
    var replannedTasks = 0
    /// Of those, tasks whose remaining effort could not fully fit before the
    /// deadline — surfaced to the user instead of leaving dangling blocks.
    var unschedulableTasks = 0

    /// Calm, outcome-first copy shared by the visible banner and its VoiceOver
    /// announcement so the two never describe the same refresh differently.
    var feedbackMessage: String {
        replannedTasks > 0
            ? "Plan refreshed after missed work. Your next steps are up to date."
            : "Plan refreshed to keep your remaining work covered."
    }

    var warningMessage: String? {
        guard unschedulableTasks > 0 else { return nil }
        return unschedulableTasks == 1
            ? "1 task no longer fits before its deadline. Extend it or trim the estimate."
            : "\(unschedulableTasks) tasks no longer fit before their deadlines. Extend them or trim the estimates."
    }

    var accessibilityAnnouncement: String {
        [feedbackMessage, warningMessage]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

// MARK: - Estimate Advisor

/// Advice from the planned-vs-actual record: nobody with ADHD estimates well,
/// and Filuma silently trusting the guess makes every downstream schedule a lie.
/// Completed tasks already carry both sides (`effortMinutes` vs
/// `timeSpentMinutes`); at capture this surfaces the pattern as a gentle,
/// one-tap suggestion instead of a lecture.
struct EstimateAdvisor {

    struct Advice: Equatable {
        /// Median actual÷planned ratio across the sample (uncapped — shown to
        /// the user honestly even when the suggestion below is capped).
        let ratio: Double
        let sampleCount: Int
        /// The estimate to offer instead: capped at 2× the guess so one wild
        /// outlier history can't balloon a plan, rounded to tidy 15s.
        let suggestedMinutes: Int

        var ratioLabel: String {
            String(format: "%.1f×", ratio)
        }
    }

    /// Below this the record says the guess is roughly honest — stay quiet.
    private static let minRatio = 1.2
    private static let minSamples = 3
    private static let maxSamples = 5
    private static let suggestionCap = 2.0

    static func advice(
        for taskContext: TaskContext,
        effortMinutes: Int,
        in modelContext: ModelContext
    ) -> Advice? {
        guard effortMinutes > 0 else { return nil }

        // Only tasks with tracked work say anything about estimation; a task
        // marked done with zero logged time is a shrug, not a data point.
        let samples = ((try? modelContext.fetch(FetchDescriptor<FilumaTask>())) ?? [])
            .filter {
                $0.isComplete && $0.context == taskContext
                    && $0.effortMinutes > 0 && $0.timeSpentMinutes > 0
            }
            .sorted { ($0.completedAt ?? $0.deadline) > ($1.completedAt ?? $1.deadline) }
            .prefix(maxSamples)
        guard samples.count >= minSamples else { return nil }

        let ratios = samples
            .map { Double($0.timeSpentMinutes) / Double($0.effortMinutes) }
            .sorted()
        let median = ratios.count.isMultiple(of: 2)
            ? (ratios[ratios.count / 2 - 1] + ratios[ratios.count / 2]) / 2
            : ratios[ratios.count / 2]
        guard median >= minRatio else { return nil }

        let raw = Double(effortMinutes) * min(median, suggestionCap)
        // 720 is the app-wide effort ceiling (capture stepper, edit stepper).
        let rounded = min(720, Int((raw / 15).rounded()) * 15)
        guard rounded > effortMinutes else { return nil }

        return Advice(ratio: median, sampleCount: samples.count, suggestedMinutes: rounded)
    }
}

// MARK: - Scheduler Service

struct SchedulerService {

    // MARK: - Public API

    /// Schedule a task by finding free slots between now and its deadline.
    /// Returns the result indicating full success, partial fit, or no slots.
    /// The returned blocks are NOT inserted into any context — callers commit them.
    static func schedule(
        task: FilumaTask,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime] = [],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        from startDate: Date = Date(),
        allowOvernight: Bool = false
    ) -> ScheduleResult {
        schedule(
            task: task,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            requestedMinutes: task.remainingMinutes,
            from: startDate,
            allowOvernight: allowOvernight
        )
    }

    /// Internal placement entry point for invalidation flows that retain
    /// locked coverage and therefore need less than the task's full remainder.
    private static func schedule(
        task: FilumaTask,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent],
        settings: UserSettings,
        requestedMinutes: Int,
        from startDate: Date,
        allowOvernight: Bool = false
    ) -> ScheduleResult {
        let remaining = max(0, requestedMinutes)
        guard remaining > 0 else { return .success(blocks: []) }

        let bufferSeconds = TimeInterval(settings.deadlineBufferMinutes * 60)
        let windowEnd = task.deadline.addingTimeInterval(-bufferSeconds)

        // Blocks start on tidy 5-minute boundaries, never at "9:47:33".
        let startDate = roundUpToFiveMinutes(startDate)

        guard startDate < windowEnd else { return .noSlots }

        // Gather existing occupied intervals (exclude completed blocks)
        var occupied = allBlocks
            .filter { !$0.isComplete }
            .map { Interval(start: $0.startTime, end: $0.endTime) }

        // Recurring blocked times are occupied too
        for blocked in blockedTimes {
            occupied.append(contentsOf: blocked
                .occurrences(from: startDate, to: windowEnd)
                .map { Interval(start: $0.start, end: $0.end) })
        }

        // …as are imported calendar events
        for event in busyEvents where event.endTime > startDate && event.startTime < windowEnd {
            occupied.append(Interval(start: event.startTime, end: event.endTime))
        }
        occupied.sort { $0.start < $1.start }

        // Find free slots
        let freeSlots = findFreeSlots(
            from: startDate,
            to: windowEnd,
            occupied: occupied,
            settings: settings,
            allowOvernight: allowOvernight,
            minimumSlotMinutes: minimumSlotMinutes(
                for: remaining,
                settings: settings
            )
        )

        var minutesPerDay = settings.dailyFocusMinutes > 0
            ? focusMinutesPerDay(in: allBlocks)
            : [:]
        return place(
            task: task,
            requestedMinutes: remaining,
            in: freeSlots,
            settings: settings,
            minutesPerDay: &minutesPerDay
        )
    }

    /// Reschedule remaining effort for a task — the single invalidation path,
    /// used for manual reschedules, blocked-time/busy-event conflicts, and
    /// missed-block catch-up alike. Removes the task's unlocked, incomplete
    /// blocks and inserts the replacements.
    @discardableResult
    static func reschedule(
        task: FilumaTask,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime] = [],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        from startDate: Date? = nil,
        now: Date = Date(),
        context: ModelContext
    ) -> ScheduleResult {
        // Remove unlocked, incomplete blocks for this task
        let blocksToRemove = task.scheduledBlocks.filter { !$0.isLocked && !$0.isComplete }
        let removedIds = Set(blocksToRemove.map(\.id))
        for block in blocksToRemove {
            context.delete(block)
        }

        // Get all blocks except the ones we just removed. Locked future blocks
        // stay in place and already cover part of the task's remaining effort.
        let remainingBlocks = allBlocks.filter { !removedIds.contains($0.id) }
        let planningStart = roundUpToFiveMinutes(
            startDate
                ?? now.addingTimeInterval(TimeInterval(settings.startBufferMinutes * 60))
        )
        let windowEnd = task.deadline.addingTimeInterval(
            -Double(settings.deadlineBufferMinutes) * 60
        )
        let retainedLockedMinutes = retainedLockedCoverageMinutes(
            for: task,
            in: remainingBlocks,
            from: now,
            to: windowEnd
        )
        let requestedMinutes = max(0, task.remainingMinutes - retainedLockedMinutes)

        let result = schedule(
            task: task,
            allBlocks: remainingBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            requestedMinutes: requestedMinutes,
            from: planningStart
        )
        insert(result: result, into: context)
        return result
    }

    /// Commit a schedule result's blocks to the store.
    static func insert(result: ScheduleResult, into context: ModelContext) {
        switch result {
        case .success(let blocks), .partialFit(let blocks, _):
            for block in blocks { context.insert(block) }
        case .noSlots:
            break
        }
    }

    /// Rebuild the whole plan, earliest deadline first. Every active task's
    /// movable incomplete blocks are wiped and remaining effort is replanned
    /// in deadline order, so an urgent task bumps later-deadline work out of
    /// the near slots instead of going unblocked. Completed and future locked
    /// blocks stay where they are; a lock on elapsed time cannot reserve work
    /// that did not happen, so missed locked blocks are released too.
    @discardableResult
    static func rebalance(
        tasks: [FilumaTask],
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        now: Date = Date(),
        context: ModelContext
    ) -> CatchUpSummary {
        var summary = CatchUpSummary()
        let active = tasks
            .filter { !$0.isComplete && $0.deadline > now }
            .sorted { $0.deadline < $1.deadline }
        guard !active.isEmpty else {
            settings.lastFutileAutomaticRebalanceFingerprint = nil
            return summary
        }

        let activeIds = Set(active.map(\.id))
        var kept: [ScheduledBlock] = []
        for block in allBlocks {
            let belongsToActive = block.task.map { activeIds.contains($0.id) } ?? false
            let isMissed = block.endTime <= now
            if belongsToActive && !block.isComplete && (!block.isLocked || isMissed) {
                context.delete(block)
            } else {
                kept.append(block)
            }
        }

        let start = roundUpToFiveMinutes(
            now.addingTimeInterval(TimeInterval(settings.startBufferMinutes * 60))
        )
        let latestWindowEnd = active
            .map { $0.deadline.addingTimeInterval(-Double(settings.deadlineBufferMinutes) * 60) }
            .max() ?? start

        // Build the shared free-time timeline once. Each task sees the same
        // deadline-clipped slots it did before; placed blocks are subtracted
        // incrementally so later-deadline work cannot overlap earlier work.
        var occupied = kept
            .filter { !$0.isComplete }
            .map { Interval(start: $0.startTime, end: $0.endTime) }
        if start < latestWindowEnd {
            for blocked in blockedTimes {
                occupied.append(contentsOf: blocked
                    .occurrences(from: start, to: latestWindowEnd)
                    .map { Interval(start: $0.start, end: $0.end) })
            }
            for event in busyEvents
                where event.endTime > start && event.startTime < latestWindowEnd {
                occupied.append(Interval(start: event.startTime, end: event.endTime))
            }
        }
        occupied = mergeIntervals(occupied)
        var freeSlots = start < latestWindowEnd
            ? findFreeSlots(
                from: start,
                to: latestWindowEnd,
                occupied: occupied,
                settings: settings,
                allowOvernight: false,
                // Keep short fragments in the shared timeline so a task whose
                // whole remainder is below the configured minimum can claim
                // one after earlier-deadline work has been subtracted.
                minimumSlotMinutes: 1
            )
            : []
        var minutesPerDay = settings.dailyFocusMinutes > 0
            ? focusMinutesPerDay(in: kept)
            : [:]

        for task in active {
            let windowEnd = task.deadline.addingTimeInterval(
                -Double(settings.deadlineBufferMinutes) * 60
            )
            let retainedLockedMinutes = retainedLockedCoverageMinutes(
                for: task,
                in: kept,
                from: now,
                to: windowEnd
            )
            let requestedMinutes = max(0, task.remainingMinutes - retainedLockedMinutes)
            let taskMinimum = minimumSlotMinutes(
                for: requestedMinutes,
                settings: settings
            )
            let taskSlots = freeSlots.compactMap { slot -> Interval? in
                let clipped = Interval(
                    start: max(slot.start, start),
                    end: min(slot.end, windowEnd)
                )
                return clipped.durationMinutes >= Double(taskMinimum)
                    ? clipped
                    : nil
            }
            let result: ScheduleResult
            if requestedMinutes == 0 {
                result = .success(blocks: [])
            } else if start < windowEnd {
                result = place(
                    task: task,
                    requestedMinutes: requestedMinutes,
                    in: taskSlots,
                    settings: settings,
                    minutesPerDay: &minutesPerDay
                )
            } else {
                result = .noSlots
            }
            switch result {
            case .success(let blocks):
                for block in blocks { context.insert(block) }
                kept.append(contentsOf: blocks)
                subtract(blocks: blocks, from: &freeSlots)
            case .partialFit(let blocks, _):
                for block in blocks { context.insert(block) }
                kept.append(contentsOf: blocks)
                subtract(blocks: blocks, from: &freeSlots)
                summary.unschedulableTasks += 1
            case .noSlots:
                if requestedMinutes > 0 {
                    summary.unschedulableTasks += 1
                }
            }
        }
        updateFutileAutomaticRebalanceMarker(
            tasks: tasks,
            allBlocks: kept,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            now: now
        )
        return summary
    }

    /// Foreground catch-up: if any block was missed, or any task is carrying
    /// less future coverage than its remaining effort, the whole plan is
    /// rebalanced by deadline. Missed blocks never sit in limbo, and urgent
    /// unblocked tasks claim slots from later-deadline work automatically.
    @discardableResult
    static func catchUpMissedBlocks(
        tasks: [FilumaTask],
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        now: Date = Date(),
        context: ModelContext
    ) -> CatchUpSummary {
        var summary = CatchUpSummary()
        let active = tasks.filter { !$0.isComplete && $0.deadline > now }

        let missedTaskIds = Set(active.filter { task in
            task.scheduledBlocks.contains {
                !$0.isComplete && $0.endTime <= now
            }
        }.map(\.id))

        let underScheduledTaskIds = Set(active.filter { task in
            let futureMinutes = task.scheduledBlocks
                .filter { !$0.isComplete && $0.endTime > now }
                .reduce(0) { $0 + $1.durationMinutes }
            return task.remainingMinutes > futureMinutes
        }.map(\.id))

        // A missed reservation is new damage and must always be repaired. The
        // fingerprint only quiets an unchanged impossible-fit plan after one
        // honest attempt, avoiding block-ID churn on every foreground pass.
        if missedTaskIds.isEmpty, !underScheduledTaskIds.isEmpty {
            let fingerprint = automaticSchedulingFingerprint(
                tasks: tasks,
                allBlocks: allBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings
            )
            if fingerprint == settings.lastFutileAutomaticRebalanceFingerprint {
                return CatchUpSummary()
            }
        }

        summary.replannedTasks = missedTaskIds.count
        summary.adjustedTasks = missedTaskIds.union(underScheduledTaskIds).count

        guard summary.adjustedTasks > 0 else { return summary }

        let rebalanced = rebalance(
            tasks: tasks,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            now: now,
            context: context
        )
        summary.unschedulableTasks = rebalanced.unschedulableTasks
        return summary
    }

    /// Record whether the resulting plan is still short. Explicit replans call
    /// this after their mutation too: they never consult the marker, but their
    /// new plan state becomes the baseline for the next automatic pass.
    static func updateFutileAutomaticRebalanceMarker(
        tasks: [FilumaTask],
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent],
        settings: UserSettings,
        now: Date = Date()
    ) {
        let remainsUnderScheduled = tasks
            .filter { !$0.isComplete && $0.deadline > now }
            .contains { task in
                let futureMinutes = allBlocks
                    .filter {
                        !$0.isComplete && $0.task?.id == task.id && $0.endTime > now
                    }
                    .reduce(0) { $0 + $1.durationMinutes }
                return task.remainingMinutes > futureMinutes
            }

        settings.lastFutileAutomaticRebalanceFingerprint = remainsUnderScheduled
            ? automaticSchedulingFingerprint(
                tasks: tasks,
                allBlocks: allBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings
            )
            : nil
    }

    /// Stable digest of every input that can change automatic placement. UUID
    /// sorting and fixed date formatting keep it identical across launches;
    /// Swift's process-seeded Hasher is deliberately unsuitable here.
    static func automaticSchedulingFingerprint(
        tasks: [FilumaTask],
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent],
        settings: UserSettings
    ) -> String {
        var records: [String] = []

        records.append(contentsOf: tasks
            .filter { !$0.isComplete }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                [
                    "task", $0.id.uuidString, fingerprintDate($0.deadline),
                    String($0.effortMinutes), String($0.manualProgressPercent),
                    fingerprintBool($0.isComplete)
                ].joined(separator: "|")
            })
        records.append(contentsOf: allBlocks
            .filter { !$0.isComplete }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                [
                    "block", $0.id.uuidString, $0.task?.id.uuidString ?? "nil",
                    fingerprintDate($0.startTime), String($0.durationMinutes),
                    fingerprintBool($0.isLocked), fingerprintBool($0.isComplete)
                ].joined(separator: "|")
            })
        records.append(contentsOf: busyEvents
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                [
                    "busy", $0.id.uuidString, fingerprintDate($0.startTime),
                    fingerprintDate($0.endTime)
                ].joined(separator: "|")
            })
        records.append(contentsOf: blockedTimes
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                [
                    "blocked", $0.id.uuidString,
                    $0.weekdays.sorted().map(String.init).joined(separator: ","),
                    String($0.startHour), String($0.startMinute),
                    String($0.durationMinutes)
                ].joined(separator: "|")
            })
        records.append([
            "settings", String(settings.wakeHour), String(settings.wakeMinute),
            String(settings.sleepHour), String(settings.sleepMinute),
            String(settings.minBlockMinutes), String(settings.maxBlockMinutes),
            String(settings.startBufferMinutes), String(settings.deadlineBufferMinutes),
            String(settings.dailyFocusMinutes)
        ].joined(separator: "|"))

        let digest = SHA256.hash(data: Data(records.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprintDate(_ date: Date) -> String {
        String(
            format: "%.9f",
            locale: Locale(identifier: "en_US_POSIX"),
            date.timeIntervalSinceReferenceDate
        )
    }

    private static func fingerprintBool(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    /// The next moment a running foreground app may need catch-up. Returning
    /// an already elapsed block is intentional: the one-shot caller runs
    /// immediately instead of skipping past damage after an unrelated redraw.
    /// Completed, orphaned, and overdue-task blocks cannot produce catch-up.
    static func nextCatchUpRefreshDate(
        blocks: [ScheduledBlock],
        now: Date = Date()
    ) -> Date? {
        blocks.compactMap { block in
            guard !block.isComplete,
                  let task = block.task,
                  !task.isComplete,
                  task.deadline > now else {
                return nil
            }
            return block.endTime
        }.min()
    }

    /// Replan tasks whose upcoming blocks collide with a blocked time or an
    /// imported calendar event — run after either changes, so existing
    /// schedules move out of the way. Returns the number of tasks replanned.
    @discardableResult
    static func replanConflicts(
        tasks: [FilumaTask],
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        now: Date = Date(),
        context: ModelContext
    ) -> Int {
        guard !blockedTimes.isEmpty || !busyEvents.isEmpty else { return 0 }

        var replanned = 0
        var currentBlocks = allBlocks

        for task in tasks where !task.isComplete && task.deadline > now {
            let upcoming = task.scheduledBlocks.filter {
                !$0.isComplete && !$0.isLocked && $0.endTime > now
            }
            guard !upcoming.isEmpty else { continue }

            let conflicted = upcoming.contains { block in
                let hitsBlockedTime = blockedTimes.contains { blocked in
                    // occurrences(from:to:) already returns only overlapping windows
                    !blocked.occurrences(from: block.startTime, to: block.endTime).isEmpty
                }
                let hitsBusyEvent = busyEvents.contains {
                    $0.startTime < block.endTime && $0.endTime > block.startTime
                }
                return hitsBlockedTime || hitsBusyEvent
            }
            guard conflicted else { continue }

            let removedIds = Set(upcoming.map(\.id))
            let result = reschedule(
                task: task,
                allBlocks: currentBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                context: context
            )
            currentBlocks.removeAll { removedIds.contains($0.id) }
            switch result {
            case .success(let blocks), .partialFit(let blocks, _):
                currentBlocks.append(contentsOf: blocks)
            case .noSlots:
                break
            }
            replanned += 1
        }
        updateFutileAutomaticRebalanceMarker(
            tasks: tasks,
            allBlocks: currentBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            now: now
        )
        return replanned
    }

    // MARK: - Pace (schedule pressure)

    /// Total scheduleable free minutes between two dates, treating other
    /// tasks' incomplete blocks, blocked times, and busy events as occupied.
    /// A task's own blocks don't count against it — that time is already his.
    static func availableMinutes(
        from: Date,
        to: Date,
        excludingTaskId: UUID? = nil,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime] = [],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings
    ) -> Int {
        scheduleableMinutes(
            from: from,
            to: to,
            excludingTaskId: excludingTaskId,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            minimumSlotMinutes: blockBounds(for: settings).minimum
        )
    }

    /// The free-minute pass shared by the public capacity API and task
    /// pressure. Pressure may lower the slot floor when the task's entire
    /// remainder is shorter than the configured minimum block.
    private static func scheduleableMinutes(
        from: Date,
        to: Date,
        excludingTaskId: UUID?,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent],
        settings: UserSettings,
        minimumSlotMinutes: Int
    ) -> Int {
        let from = roundUpToFiveMinutes(from)
        guard from < to else { return 0 }

        var occupied = allBlocks
            .filter { !$0.isComplete && $0.endTime > from && $0.task?.id != excludingTaskId }
            .map { Interval(start: $0.startTime, end: $0.endTime) }
        for blocked in blockedTimes {
            occupied.append(contentsOf: blocked
                .occurrences(from: from, to: to)
                .map { Interval(start: $0.start, end: $0.end) })
        }
        for event in busyEvents where event.endTime > from && event.startTime < to {
            occupied.append(Interval(start: event.startTime, end: event.endTime))
        }
        occupied.sort { $0.start < $1.start }

        let slots = findFreeSlots(
            from: from,
            to: to,
            occupied: occupied,
            settings: settings,
            allowOvernight: false,
            minimumSlotMinutes: minimumSlotMinutes
        )

        let focusCap = settings.dailyFocusMinutes
        var focusUsage = focusCap > 0
            ? focusMinutesPerDay(in: allBlocks)
            : [:]

        // An excluded task can reclaim only the portion of its own reservation
        // that lies inside this query. Same-day reservations before or after
        // the window still consume focus budget, including locked blocks that
        // the scheduler cannot move.
        if focusCap > 0, let excludingTaskId {
            for block in allBlocks
                where !block.isComplete && block.task?.id == excludingTaskId {
                let overlapStart = max(block.startTime, from)
                let overlapEnd = min(block.endTime, to)
                guard overlapStart < overlapEnd else { continue }

                for (day, minutes) in minutesByDay(from: overlapStart, to: overlapEnd) {
                    focusUsage[day] = max(0, focusUsage[day, default: 0] - minutes)
                }
            }
        }

        let bounds = blockBounds(for: settings)
        return slotAwareCapacity(
            in: slots,
            minimum: minimumSlotMinutes,
            maximum: bounds.maximum,
            focusCap: focusCap,
            focusUsage: focusUsage
        )
    }

    /// Schedule pressure for a task: remaining effort ÷ free minutes left
    /// before its buffered deadline. 0.5 means half the free time is spoken
    /// for; above 1 the task no longer fits. Infinity when there's no window
    /// at all. Nil when the task carries no remaining effort.
    static func pressure(
        for task: FilumaTask,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime] = [],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        now: Date = Date()
    ) -> Double? {
        pressureAndAvailableMinutes(
            for: task,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            now: now
        )?.pressure
    }

    /// Pressure plus the free-minute denominator used to calculate it. Pace
    /// consumers that display both values can share one free-slot pass.
    static func pressureAndAvailableMinutes(
        for task: FilumaTask,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime] = [],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        now: Date = Date()
    ) -> (pressure: Double, availableMinutes: Int)? {
        let remaining = task.remainingMinutes
        guard !task.isComplete, remaining > 0 else { return nil }

        let windowEnd = task.deadline.addingTimeInterval(
            -Double(settings.deadlineBufferMinutes) * 60
        )
        guard windowEnd > now else { return (.infinity, 0) }

        let available = scheduleableMinutes(
            from: now,
            to: windowEnd,
            excludingTaskId: task.id,
            allBlocks: allBlocks,
            blockedTimes: blockedTimes,
            busyEvents: busyEvents,
            settings: settings,
            minimumSlotMinutes: minimumSlotMinutes(
                for: remaining,
                settings: settings
            )
        )
        guard available > 0 else { return (.infinity, 0) }
        return (Double(remaining) / Double(available), available)
    }

    // MARK: - Recurring tasks

    /// Stamp out upcoming occurrences of recurring templates, a rolling two
    /// weeks ahead — run on foreground refresh. Occurrences whose deadline
    /// already passed while the app was closed are skipped silently: a
    /// recurrence must never spawn retroactive guilt. Exhausted templates
    /// delete themselves. Returns the number of tasks created.
    @discardableResult
    static func materializeRecurringTasks(
        templates: [TaskTemplate],
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime] = [],
        busyEvents: [BusyEvent] = [],
        settings: UserSettings,
        now: Date = Date(),
        context: ModelContext
    ) -> Int {
        guard !templates.isEmpty else { return 0 }
        let calendar = Calendar.current
        guard let horizon = calendar.date(byAdding: .day, value: 14, to: now) else { return 0 }

        var created = 0
        var currentBlocks = allBlocks
        let start = now.addingTimeInterval(TimeInterval(settings.startBufferMinutes * 60))

        for template in templates {
            var next = template.nextDeadline
            while next <= horizon && next <= template.repeatUntil {
                if next > now {
                    let task = FilumaTask(
                        title: template.title,
                        context: template.context,
                        deadline: next,
                        effortMinutes: template.effortMinutes,
                        source: .recurring,
                        firstStep: template.firstStep
                    )
                    task.templateId = template.id
                    context.insert(task)

                    let result = schedule(
                        task: task,
                        allBlocks: currentBlocks,
                        blockedTimes: blockedTimes,
                        busyEvents: busyEvents,
                        settings: settings,
                        from: start
                    )
                    insert(result: result, into: context)
                    if case .success(let blocks) = result {
                        currentBlocks.append(contentsOf: blocks)
                    } else if case .partialFit(let blocks, _) = result {
                        currentBlocks.append(contentsOf: blocks)
                    }
                    created += 1
                }
                guard let following = calendar.date(byAdding: .day, value: 7, to: next) else { break }
                next = following
            }
            template.nextDeadline = next
            if next > template.repeatUntil {
                context.delete(template)
            }
        }
        return created
    }

    /// Round a date up to the next 5-minute boundary.
    static func roundUpToFiveMinutes(_ date: Date) -> Date {
        let interval: TimeInterval = 5 * 60
        let rounded = (date.timeIntervalSinceReferenceDate / interval).rounded(.up) * interval
        return Date(timeIntervalSinceReferenceDate: rounded)
    }

    // MARK: - Internals

    private struct Interval {
        let start: Date
        let end: Date

        var durationMinutes: Double {
            end.timeIntervalSince(start) / 60.0
        }
    }

    private struct BlockPlacement {
        let start: Date
        let durationMinutes: Int
    }

    private struct PlacementState {
        let scheduledMinutes: Int
        let placements: [BlockPlacement]
        /// Focus added by this candidate plan. Entries for days that no future
        /// slot can touch are discarded after each DP step.
        let addedFocusSeconds: [Date: Int]
    }

    /// Locked blocks stay where the user put them, but only the portion that
    /// can still satisfy this scheduling pass counts as retained coverage.
    /// Elapsed time and time after the buffered deadline cannot reduce the
    /// amount that must be placed inside the usable window. A still-future lock
    /// counts even when an explicit custom start pushes replacement work later.
    private static func retainedLockedCoverageMinutes(
        for task: FilumaTask,
        in blocks: [ScheduledBlock],
        from coverageStart: Date,
        to windowEnd: Date
    ) -> Int {
        guard coverageStart < windowEnd else { return 0 }

        return blocks.reduce(0) { total, block in
            guard block.task?.id == task.id,
                  block.isLocked,
                  !block.isComplete else {
                return total
            }

            let overlapStart = max(block.startTime, coverageStart)
            let overlapEnd = min(block.endTime, windowEnd)
            guard overlapStart < overlapEnd else { return total }

            let overlapMinutes = Int(
                floor(overlapEnd.timeIntervalSince(overlapStart) / 60 + 0.000_001)
            )
            return total + max(0, overlapMinutes)
        }
    }

    private static func scheduledMinuteCount(in result: ScheduleResult) -> Int {
        switch result {
        case .success(let blocks), .partialFit(let blocks, _):
            return blocks.reduce(0) { $0 + $1.durationMinutes }
        case .noSlots:
            return 0
        }
    }

    /// Candidate plans create model objects before one is selected. Sever the
    /// inverse relationship on the loser so only the chosen plan can later be
    /// inserted into SwiftData.
    private static func detachBlocks(in result: ScheduleResult) {
        switch result {
        case .success(let blocks), .partialFit(let blocks, _):
            for block in blocks { block.task = nil }
        case .noSlots:
            break
        }
    }

    /// Assign chunks to the earliest available slots. Daily focus accounting
    /// follows calendar-day boundaries even when an awake window crosses them.
    private static func place(
        task: FilumaTask,
        requestedMinutes: Int,
        in freeSlots: [Interval],
        settings: UserSettings,
        minutesPerDay: inout [Date: Double]
    ) -> ScheduleResult {
        let remaining = max(0, requestedMinutes)
        guard remaining > 0 else { return .success(blocks: []) }

        let orderedSlots = freeSlots.sorted { $0.start < $1.start }
        if orderedSlots.allSatisfy(staysWithinOneCalendarDay) {
            return placeUsingSlotDP(
                task: task,
                requestedMinutes: remaining,
                in: orderedSlots,
                settings: settings,
                minutesPerDay: &minutesPerDay
            )
        }

        // The exact slot DP maximizes fragmented placement, including a block
        // that crosses midnight. The greedy path additionally knows how to
        // skip to midnight when the first date's focus budget is exhausted.
        // Evaluate both against isolated focus snapshots and keep the plan that
        // actually places more work; discarded blocks are detached so they do
        // not linger in the task relationship.
        var dpMinutesPerDay = minutesPerDay
        let dpResult = placeUsingSlotDP(
            task: task,
            requestedMinutes: remaining,
            in: orderedSlots,
            settings: settings,
            minutesPerDay: &dpMinutesPerDay
        )
        var greedyMinutesPerDay = minutesPerDay
        let greedyResult = placeAcrossMidnightGreedily(
            task: task,
            requestedMinutes: remaining,
            in: orderedSlots,
            settings: settings,
            minutesPerDay: &greedyMinutesPerDay
        )

        if scheduledMinuteCount(in: dpResult) >= scheduledMinuteCount(in: greedyResult) {
            detachBlocks(in: greedyResult)
            minutesPerDay = dpMinutesPerDay
            return dpResult
        }

        detachBlocks(in: dpResult)
        minutesPerDay = greedyMinutesPerDay
        return greedyResult
    }

    /// Exact, minute-granularity placement for ordinary same-day gaps. The DP
    /// keeps at most one best state per scheduled-minute total: lower remaining
    /// same-day focus usage dominates, then the chronologically earlier plan
    /// wins. This finds the maximum partial fit without an exponential search.
    private static func placeUsingSlotDP(
        task: FilumaTask,
        requestedMinutes: Int,
        in freeSlots: [Interval],
        settings: UserSettings,
        minutesPerDay: inout [Date: Double]
    ) -> ScheduleResult {
        let bounds = blockBounds(for: settings)
        let minimum = min(requestedMinutes, bounds.minimum)
        let focusCapSeconds = settings.dailyFocusMinutes > 0
            ? settings.dailyFocusMinutes * 60
            : 0
        let initialFocusSeconds = minutesPerDay.mapValues {
            Int(($0 * 60).rounded())
        }

        var states: [Int: PlacementState] = [
            0: PlacementState(
                scheduledMinutes: 0,
                placements: [],
                addedFocusSeconds: [:]
            )
        ]

        for (index, slot) in freeSlots.enumerated() {
            let slotCapacity = min(
                requestedMinutes,
                max(0, Int(floor(slot.durationMinutes + 0.000_001)))
            )
            var options = [0]
            if slotCapacity >= minimum {
                options.append(contentsOf: (minimum...slotCapacity).filter {
                    isRepresentableByBlocks(
                        $0,
                        minimum: minimum,
                        maximum: bounds.maximum
                    )
                })
            }

            let futureDays = Set(freeSlots.dropFirst(index + 1).map {
                Calendar.current.startOfDay(for: $0.start)
            })
            var nextStates: [Int: PlacementState] = [:]

            for state in states.values {
                for amount in options where state.scheduledMinutes + amount <= requestedMinutes {
                    let optionEnd = slot.start.addingTimeInterval(TimeInterval(amount * 60))
                    var addedFocus = state.addedFocusSeconds
                    var fitsFocus = true

                    if focusCapSeconds > 0, amount > 0 {
                        for (day, minutes) in minutesByDay(from: slot.start, to: optionEnd) {
                            let seconds = Int((minutes * 60).rounded())
                            let used = initialFocusSeconds[day, default: 0]
                                + addedFocus[day, default: 0]
                                + seconds
                            if used > focusCapSeconds {
                                fitsFocus = false
                                break
                            }
                            addedFocus[day, default: 0] += seconds
                        }
                    }
                    guard fitsFocus else { continue }

                    var placements = state.placements
                    if amount > 0 {
                        var cursor = slot.start
                        for chunk in splitEffort(
                            minutes: amount,
                            minBlock: minimum,
                            maxBlock: bounds.maximum
                        ) {
                            placements.append(
                                BlockPlacement(start: cursor, durationMinutes: chunk)
                            )
                            cursor = cursor.addingTimeInterval(TimeInterval(chunk * 60))
                        }
                    }

                    addedFocus = addedFocus.filter { futureDays.contains($0.key) }
                    let candidate = PlacementState(
                        scheduledMinutes: state.scheduledMinutes + amount,
                        placements: placements,
                        addedFocusSeconds: addedFocus
                    )
                    let total = candidate.scheduledMinutes

                    if let existing = nextStates[total] {
                        if prefers(candidate, over: existing) {
                            nextStates[total] = candidate
                        }
                    } else {
                        nextStates[total] = candidate
                    }
                }
            }
            states = nextStates

            // Slots are chronological and this state is already the earliest
            // complete plan reachable through the current slot. Later slots
            // cannot improve its first-use time, so stop before a distant
            // deadline turns an exact answer into needless DP work.
            if states[requestedMinutes] != nil {
                break
            }
        }

        guard let scheduledMinutes = states.keys.max(), scheduledMinutes > 0,
              let best = states[scheduledMinutes] else {
            return .noSlots
        }

        let blocks = best.placements.map { placement in
            ScheduledBlock(
                task: task,
                startTime: placement.start,
                durationMinutes: placement.durationMinutes
            )
        }
        for block in blocks {
            for (day, minutes) in minutesByDay(from: block.startTime, to: block.endTime) {
                minutesPerDay[day, default: 0] += minutes
            }
        }

        if scheduledMinutes < requestedMinutes {
            return .partialFit(
                scheduled: blocks,
                unscheduledMinutes: requestedMinutes - scheduledMinutes
            )
        }
        return .success(blocks: blocks)
    }

    /// Existing midnight-aware forward placement. A continuous overnight slot
    /// can carry a block through midnight and, after one day's focus is spent,
    /// resume at the next date boundary.
    private static func placeAcrossMidnightGreedily(
        task: FilumaTask,
        requestedMinutes: Int,
        in freeSlots: [Interval],
        settings: UserSettings,
        minutesPerDay: inout [Date: Double]
    ) -> ScheduleResult {
        let remaining = requestedMinutes

        let focusCap = settings.dailyFocusMinutes
        let bounds = blockBounds(for: settings)

        var newBlocks: [ScheduledBlock] = []
        var minutesLeft = remaining

        for slot in freeSlots where minutesLeft > 0 {
            var slotStart = slot.start
            while slotStart < slot.end, minutesLeft > 0 {
                guard let chunk = fittingChunk(
                    remaining: minutesLeft,
                    from: slotStart,
                    to: slot.end,
                    minimum: bounds.minimum,
                    maximum: bounds.maximum,
                    focusCap: focusCap,
                    minutesPerDay: minutesPerDay
                ) else {
                    // An awake window can cross midnight. If today's focus
                    // budget is exhausted, retry the still-free portion after
                    // the calendar-day boundary instead of discarding it.
                    let day = Calendar.current.startOfDay(for: slotStart)
                    guard let nextDay = Calendar.current.date(
                        byAdding: .day,
                        value: 1,
                        to: day
                    ), nextDay > slotStart, nextDay < slot.end else {
                        break
                    }
                    slotStart = nextDay
                    continue
                }

                let blockEnd = slotStart.addingTimeInterval(TimeInterval(chunk * 60))
                let portions = minutesByDay(from: slotStart, to: blockEnd)
                let block = ScheduledBlock(
                    task: task,
                    startTime: slotStart,
                    durationMinutes: chunk
                )
                newBlocks.append(block)
                for (day, minutes) in portions {
                    minutesPerDay[day, default: 0] += minutes
                }
                minutesLeft -= chunk
                slotStart = blockEnd
            }
        }

        let scheduledMinutes = newBlocks.reduce(0) { $0 + $1.durationMinutes }
        if scheduledMinutes == 0 {
            return .noSlots
        } else if scheduledMinutes < remaining {
            return .partialFit(
                scheduled: newBlocks,
                unscheduledMinutes: remaining - scheduledMinutes
            )
        } else {
            return .success(blocks: newBlocks)
        }
    }

    private static func prefers(
        _ candidate: PlacementState,
        over existing: PlacementState
    ) -> Bool {
        let candidateFocus = candidate.addedFocusSeconds.values.reduce(0, +)
        let existingFocus = existing.addedFocusSeconds.values.reduce(0, +)
        if candidateFocus != existingFocus {
            return candidateFocus < existingFocus
        }

        for (candidateBlock, existingBlock) in zip(
            candidate.placements,
            existing.placements
        ) {
            if candidateBlock.start != existingBlock.start {
                return candidateBlock.start < existingBlock.start
            }
            if candidateBlock.durationMinutes != existingBlock.durationMinutes {
                return candidateBlock.durationMinutes > existingBlock.durationMinutes
            }
        }
        return candidate.placements.count < existing.placements.count
    }

    /// Focus usage from existing blocks, split at every local midnight rather
    /// than charging an overnight block entirely to its start date.
    private static func focusMinutesPerDay(
        in blocks: [ScheduledBlock]
    ) -> [Date: Double] {
        var result: [Date: Double] = [:]
        for block in blocks where !block.isComplete {
            for (day, minutes) in minutesByDay(from: block.startTime, to: block.endTime) {
                result[day, default: 0] += minutes
            }
        }
        return result
    }

    private static func minutesByDay(from start: Date, to end: Date) -> [(Date, Double)] {
        guard start < end else { return [] }
        let calendar = Calendar.current
        var portions: [(Date, Double)] = []
        var cursor = start

        while cursor < end {
            let day = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let portionEnd = min(end, nextDay)
            portions.append((day, portionEnd.timeIntervalSince(cursor) / 60.0))
            cursor = portionEnd
        }
        return portions
    }

    /// Sanitized block bounds shared by free-slot filtering and placement.
    /// A focus cap below the preferred minimum necessarily becomes the usable
    /// maximum (and therefore minimum) for that configuration.
    private static func blockBounds(
        for settings: UserSettings
    ) -> (minimum: Int, maximum: Int) {
        let configuredMaximum = max(1, settings.maxBlockMinutes)
        let maximum = settings.dailyFocusMinutes > 0
            ? min(configuredMaximum, settings.dailyFocusMinutes)
            : configuredMaximum
        return (max(1, min(settings.minBlockMinutes, maximum)), maximum)
    }

    private static func minimumSlotMinutes(
        for remaining: Int,
        settings: UserSettings
    ) -> Int {
        guard remaining > 0 else { return 0 }
        return min(remaining, blockBounds(for: settings).minimum)
    }

    private static func staysWithinOneCalendarDay(_ slot: Interval) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: slot.start)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
            return false
        }
        return slot.end <= nextDay
    }

    /// Maximum capacity across distinct same-day gaps. Each gap contributes
    /// only totals its own geometry can represent, and a bounded daily DP
    /// allocates the remaining focus budget without pooling unusable tails.
    private static func slotAwareCapacity(
        in slots: [Interval],
        minimum: Int,
        maximum: Int,
        focusCap: Int,
        focusUsage: [Date: Double]
    ) -> Int {
        guard minimum > 0, maximum >= minimum else { return 0 }

        if focusCap <= 0 {
            return slots.reduce(0) { total, slot in
                let capacity = max(0, Int(floor(slot.durationMinutes + 0.000_001)))
                return total + largestRepresentableMinutes(
                    upTo: capacity,
                    minimum: minimum,
                    maximum: maximum
                )
            }
        }

        if !slots.allSatisfy(staysWithinOneCalendarDay) {
            // An overnight awake window is one continuous opportunity, but its
            // focus cost belongs to the calendar days on either side of local
            // midnight. Keep two conservative, realizable estimates: the
            // independent-fragment DP prevents disconnected tails from pooling,
            // while the continuous pass preserves a real block that bridges the
            // seam. Taking the better result never claims more than one of those
            // placement strategies can actually schedule.
            var fragments: [Interval] = []
            for slot in slots {
                var cursor = slot.start
                while cursor < slot.end {
                    let day = Calendar.current.startOfDay(for: cursor)
                    guard let nextDay = Calendar.current.date(
                        byAdding: .day,
                        value: 1,
                        to: day
                    ) else { break }
                    let fragmentEnd = min(slot.end, nextDay)
                    fragments.append(Interval(start: cursor, end: fragmentEnd))
                    cursor = fragmentEnd
                }
            }
            let fragmentedCapacity = slotAwareCapacity(
                in: fragments,
                minimum: minimum,
                maximum: maximum,
                focusCap: focusCap,
                focusUsage: focusUsage
            )
            let continuousCapacity = continuousGreedyCapacity(
                in: slots,
                minimum: minimum,
                maximum: maximum,
                focusCap: focusCap,
                focusUsage: focusUsage
            )
            return max(fragmentedCapacity, continuousCapacity)
        }

        let calendar = Calendar.current
        let slotsByDay = Dictionary(grouping: slots) {
            calendar.startOfDay(for: $0.start)
        }

        return slotsByDay.reduce(0) { total, entry in
            let (day, daySlots) = entry
            let remainingFocus = max(
                0,
                Int(floor(Double(focusCap) - focusUsage[day, default: 0] + 0.000_001))
            )
            guard remainingFocus >= minimum else { return total }

            var reachable = Set([0])
            for slot in daySlots {
                let slotCapacity = min(
                    remainingFocus,
                    max(0, Int(floor(slot.durationMinutes + 0.000_001)))
                )
                var options = [0]
                if slotCapacity >= minimum {
                    options.append(contentsOf: (minimum...slotCapacity).filter {
                        isRepresentableByBlocks(
                            $0,
                            minimum: minimum,
                            maximum: maximum
                        )
                    })
                }

                var next = Set<Int>()
                next.reserveCapacity(min(remainingFocus + 1, reachable.count * options.count))
                for used in reachable {
                    for option in options where used + option <= remainingFocus {
                        next.insert(used + option)
                    }
                }
                reachable = next
            }
            return total + (reachable.max() ?? 0)
        }
    }

    /// Capacity lower bound that mirrors the placement path for a continuous
    /// overnight gap. Work starts at the gap's cursor; if today's focus budget
    /// cannot hold another minimum block, the cursor advances to midnight just
    /// as `placeAcrossMidnightGreedily` does. Every accepted run is itself
    /// representable as one or more valid blocks, so this can recover seam-
    /// spanning capacity without pooling disconnected fragments.
    private static func continuousGreedyCapacity(
        in slots: [Interval],
        minimum: Int,
        maximum: Int,
        focusCap: Int,
        focusUsage: [Date: Double]
    ) -> Int {
        guard focusCap > 0 else { return 0 }

        var usage = focusUsage
        var total = 0

        for slot in slots.sorted(by: { $0.start < $1.start }) {
            var cursor = slot.start

            while cursor < slot.end {
                let available = max(
                    0,
                    Int(floor(slot.end.timeIntervalSince(cursor) / 60 + 0.000_001))
                )
                var accepted = 0

                if available >= minimum {
                    for candidate in stride(from: available, through: minimum, by: -1) {
                        guard isRepresentableByBlocks(
                            candidate,
                            minimum: minimum,
                            maximum: maximum
                        ) else { continue }

                        let candidateEnd = cursor.addingTimeInterval(
                            TimeInterval(candidate * 60)
                        )
                        let portions = minutesByDay(from: cursor, to: candidateEnd)
                        let fits = portions.allSatisfy { day, minutes in
                            usage[day, default: 0] + minutes <= Double(focusCap)
                        }
                        if fits {
                            accepted = candidate
                            for (day, minutes) in portions {
                                usage[day, default: 0] += minutes
                            }
                            break
                        }
                    }
                }

                if accepted > 0 {
                    total += accepted
                    cursor = cursor.addingTimeInterval(TimeInterval(accepted * 60))
                    continue
                }

                let day = Calendar.current.startOfDay(for: cursor)
                guard let nextDay = Calendar.current.date(
                    byAdding: .day,
                    value: 1,
                    to: day
                ), nextDay > cursor, nextDay < slot.end else {
                    break
                }
                cursor = nextDay
            }
        }

        return total
    }

    /// Largest amount no greater than `limit` that can be expressed as one or
    /// more blocks within the supplied bounds. For example, 55 minutes under
    /// 30...45-minute bounds contributes 45 usable minutes, while 60 can be
    /// represented by two 30-minute blocks. A sub-minimum daily remainder is
    /// not capacity that can be pooled with another day.
    private static func largestRepresentableMinutes(
        upTo limit: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        guard limit >= minimum, minimum > 0, maximum >= minimum else { return 0 }
        let blockCount = limit / minimum
        return min(limit, blockCount * maximum)
    }

    private static func isRepresentableByBlocks(
        _ minutes: Int,
        minimum: Int,
        maximum: Int
    ) -> Bool {
        guard minutes > 0, minimum > 0, maximum >= minimum else { return false }
        let minimumBlocks = Int(ceil(Double(minutes) / Double(maximum)))
        let maximumBlocks = minutes / minimum
        return minimumBlocks <= maximumBlocks
    }

    /// Pick the largest block that fits this particular slot while preserving
    /// a minimum-sized tail. This adapts `[90, 30]` into `[60, 60]` when the
    /// actual calendar offers two separate hour-long gaps.
    private static func fittingChunk(
        remaining: Int,
        from start: Date,
        to end: Date,
        minimum: Int,
        maximum: Int,
        focusCap: Int,
        minutesPerDay: [Date: Double]
    ) -> Int? {
        let available = Int(floor(end.timeIntervalSince(start) / 60.0 + 0.000_001))
        let largest = min(remaining, maximum, available)
        let smallest = remaining < minimum ? remaining : minimum
        guard largest >= smallest else { return nil }

        for candidate in stride(from: largest, through: smallest, by: -1) {
            let tail = remaining - candidate
            guard tail == 0 || isRepresentableByBlocks(
                tail,
                minimum: minimum,
                maximum: maximum
            ) else { continue }

            let candidateEnd = start.addingTimeInterval(TimeInterval(candidate * 60))
            let portions = minutesByDay(from: start, to: candidateEnd)
            let fitsFocus = focusCap <= 0 || portions.allSatisfy { day, minutes in
                minutesPerDay[day, default: 0] + minutes <= Double(focusCap)
            }
            if fitsFocus { return candidate }
        }
        return nil
    }

    /// Coalesce the initially occupied timeline once before free-slot
    /// subtraction. Touching intervals are equivalent to one continuous hold.
    private static func mergeIntervals(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals
            .filter { $0.start < $0.end }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }

        var merged: [Interval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = Interval(start: current.start, end: max(current.end, interval.end))
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }

    /// Remove newly placed blocks from the shared rebalance timeline without
    /// rebuilding all occupied intervals and free slots for the next task.
    private static func subtract(
        blocks: [ScheduledBlock],
        from freeSlots: inout [Interval]
    ) {
        for block in blocks {
            let occupied = Interval(start: block.startTime, end: block.endTime)
            freeSlots = freeSlots.flatMap { slot in
                guard occupied.start < slot.end, occupied.end > slot.start else {
                    return [slot]
                }
                var remainder: [Interval] = []
                if occupied.start > slot.start {
                    remainder.append(Interval(start: slot.start, end: occupied.start))
                }
                if occupied.end < slot.end {
                    remainder.append(Interval(start: occupied.end, end: slot.end))
                }
                return remainder
            }
        }
    }

    /// Find free time slots between `from` and `to`, respecting wake/sleep and occupied intervals.
    private static func findFreeSlots(
        from: Date,
        to: Date,
        occupied: [Interval],
        settings: UserSettings,
        allowOvernight: Bool,
        minimumSlotMinutes: Int? = nil
    ) -> [Interval] {
        let calendar = Calendar.current
        var slots: [Interval] = []

        // Generate day-by-day awake windows
        var currentDay = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)

        while currentDay <= lastDay {
            guard let wakeStart = calendar.date(
                bySettingHour: settings.wakeHour,
                minute: settings.wakeMinute,
                second: 0,
                of: currentDay
            ), var sleepEnd = calendar.date(
                bySettingHour: settings.sleepHour,
                minute: settings.sleepMinute,
                second: 0,
                of: currentDay
            ), let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else {
                break
            }

            // A sleep time at or before wake time means "past midnight"
            // (e.g. wake 8:00, sleep 0:30) — the window runs into the next day.
            if sleepEnd <= wakeStart {
                sleepEnd = calendar.date(byAdding: .day, value: 1, to: sleepEnd) ?? sleepEnd
            }

            if allowOvernight {
                let dayStart = max(currentDay, from)
                let dayEnd = min(nextDay, to)
                if dayStart < dayEnd {
                    slots.append(Interval(start: dayStart, end: dayEnd))
                }
            } else {
                let windowStart = max(wakeStart, from)
                let windowEnd = min(sleepEnd, to)
                if windowStart < windowEnd {
                    slots.append(Interval(start: windowStart, end: windowEnd))
                }
            }

            currentDay = nextDay
        }

        // Degenerate records occupy no time. Letting one enter subtraction can
        // split a usable slot into two fragments that both fail the minimum.
        let occupied = occupied.filter { $0.start < $0.end }

        // Subtract occupied intervals from free slots
        var freeSlots: [Interval] = []
        for slot in slots {
            var remaining = [slot]
            for occ in occupied {
                var newRemaining: [Interval] = []
                for r in remaining {
                    // No overlap
                    if occ.end <= r.start || occ.start >= r.end {
                        newRemaining.append(r)
                    } else {
                        // Before occupied
                        if occ.start > r.start {
                            newRemaining.append(Interval(start: r.start, end: occ.start))
                        }
                        // After occupied
                        if occ.end < r.end {
                            newRemaining.append(Interval(start: occ.end, end: r.end))
                        }
                    }
                }
                remaining = newRemaining
            }
            freeSlots.append(contentsOf: remaining)
        }

        // A task whose whole remainder is shorter than the configured minimum
        // can opt into a correspondingly short slot. Generic callers retain
        // the configured floor.
        let minimum = minimumSlotMinutes ?? blockBounds(for: settings).minimum
        return freeSlots.filter { $0.durationMinutes >= Double(minimum) }
    }

    /// Split total effort into chunks respecting min/max block sizes.
    /// Rebalances the tail so no chunk lands below the minimum when avoidable
    /// (e.g. 100m with 30–90 becomes [70, 30], not [90, 10]).
    static func splitEffort(minutes: Int, minBlock: Int, maxBlock: Int) -> [Int] {
        guard minutes > 0 else { return [] }
        // A non-positive max (corrupted settings, a misconfigured focus cap)
        // must never reach the loop below — it would never shrink `remaining`.
        // A min above max would make the sub-minimum-tail branch below produce
        // a negative-sized "chunk" and grow `remaining` forever, so clamp both.
        let maxBlock = max(1, maxBlock)
        let minBlock = min(minBlock, maxBlock)
        guard minutes > maxBlock else { return [minutes] }

        var chunks: [Int] = []
        var remaining = minutes

        while remaining > 0 {
            if remaining <= maxBlock {
                chunks.append(remaining)
                remaining = 0
            } else if remaining - maxBlock < minBlock {
                // A full max chunk would strand a sub-minimum tail; split evenly.
                let first = remaining - minBlock
                chunks.append(min(first, maxBlock))
                remaining -= min(first, maxBlock)
            } else {
                chunks.append(maxBlock)
                remaining -= maxBlock
            }
        }

        return chunks
    }
}
