import Foundation
import SwiftData

/// A durable completion distilled into plain values. Presentation holds this
/// receipt instead of retaining a SwiftData model that has just moved between
/// active and completed queries.
struct TaskCompletionReceipt: Identifiable {
    var id: UUID { taskID }

    let taskID: UUID
    let title: String
    let context: TaskContext
    let deadline: Date
    let completedAt: Date
    let timeSpentMinutes: Int

    /// Factual timing copy anchored to the committed completion timestamp.
    /// It never reclassifies itself while the completion screen is open.
    var deadlineSummary: String {
        let seconds = deadline.timeIntervalSince(completedAt)
        let absoluteMinutes = Int(abs(seconds) / 60)

        if abs(seconds) < 1 {
            return "at deadline"
        }

        if seconds >= 0 {
            if absoluteMinutes >= 2 * 24 * 60 {
                return "\(absoluteMinutes / (24 * 60)) days early"
            }
            if absoluteMinutes >= 60 {
                return "\(absoluteMinutes / 60)h to spare"
            }
            if absoluteMinutes >= 1 {
                return "\(absoluteMinutes)m to spare"
            }
            return "under 1m to spare"
        }

        if absoluteMinutes >= 2 * 24 * 60 {
            return "\(absoluteMinutes / (24 * 60)) days after deadline"
        }
        if absoluteMinutes >= 60 {
            return "\(absoluteMinutes / 60)h after deadline"
        }
        if absoluteMinutes >= 1 {
            return "\(absoluteMinutes)m after deadline"
        }
        return "just after deadline"
    }
}

/// Plain, durable facts returned after a captured task and its reservations
/// have made it to the store. Views can safely keep this value after their
/// SwiftData queries move the newly inserted models between sections.
struct TaskCaptureReceipt: Equatable, Identifiable {
    var id: UUID { taskID }

    let taskID: UUID
    let title: String
    let context: TaskContext
    let deadline: Date
    let scheduledBlockCount: Int
    let scheduledMinutes: Int
    let unscheduledMinutes: Int
    let firstBlockStart: Date?
    let templateID: UUID?
}

/// Plain confirmation for a reminder whose row is already durable.
struct ReminderCaptureReceipt: Equatable, Identifiable {
    var id: UUID { reminderID }

    let reminderID: UUID
    let title: String
    let dueDate: Date
    let notificationID: String
}

/// The three user-visible changes an existing one-off reminder supports.
/// Keeping the intent explicit lets persistence and notification delivery stay
/// behind the same boundary instead of being independently driven by views.
enum ReminderMutation: Equatable {
    case complete
    case restore
    case delete
}

/// Immutable facts from a reminder mutation that has already reached the
/// store. In particular, delete publishers receive this scalar receipt rather
/// than retaining a SwiftData model whose lifetime just ended.
struct ReminderMutationReceipt: Equatable, Identifiable {
    var id: UUID { reminderID }

    let reminderID: UUID
    let title: String
    let dueDate: Date
    let notificationID: String
    let mutation: ReminderMutation
}

/// The complete, fallibly loaded snapshot used by task-capture planning.
/// `tasks` is empty during ordinary preparation and populated for Make Room.
struct TaskCapturePlanningInput {
    let settings: UserSettings
    let allBlocks: [ScheduledBlock]
    let blockedTimes: [BlockedTime]
    let busyEvents: [BusyEvent]
    let tasks: [FilumaTask]

    init(
        settings: UserSettings,
        allBlocks: [ScheduledBlock],
        blockedTimes: [BlockedTime],
        busyEvents: [BusyEvent],
        tasks: [FilumaTask] = []
    ) {
        self.settings = settings
        self.allBlocks = allBlocks
        self.blockedTimes = blockedTimes
        self.busyEvents = busyEvents
        self.tasks = tasks
    }
}

/// An entirely provisional capture. Neither the task nor any result block is
/// inserted until one of CaptureCoordinator's commit boundaries succeeds.
struct PreparedTaskCapture {
    let task: FilumaTask
    let result: ScheduleResult
}

/// One row of bulk entry, kept free of SwiftData identity so the complete
/// batch can be validated before any model graph is built.
struct BulkTaskCaptureDraft: Equatable {
    let title: String
    let context: TaskContext
    let deadline: Date
    let effortMinutes: Int
}

/// Durable facts for one atomic bulk capture. Counts are derived from the
/// receipts themselves, so summary copy cannot drift from the saved plan.
struct BulkCaptureReceipt: Equatable {
    let taskReceipts: [TaskCaptureReceipt]

    var fullyScheduledCount: Int {
        taskReceipts.filter { $0.unscheduledMinutes == 0 }.count
    }

    var needsAttentionCount: Int {
        taskReceipts.filter { $0.unscheduledMinutes > 0 }.count
    }
}

/// Plain values submitted by the task editor. Keeping the draft detached from
/// SwiftData lets a failed save leave both the durable task and its live UI
/// model exactly as they were before the user tapped Save.
struct TaskEditUpdate: Equatable {
    let title: String
    let firstStep: String?
    let taskContext: TaskContext
    let deadline: Date
    let effortMinutes: Int
}

enum TaskEditCoordinatorError: LocalizedError, Equatable {
    case emptyTitle
    case invalidEffortMinutes
    case deadlineNotFuture

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "Enter a task title before saving."
        case .invalidEffortMinutes:
            return "Choose a positive time estimate before saving."
        case .deadlineNotFuture:
            return "Choose a deadline that is still in the future."
        }
    }
}

/// Durable outcome of one foreground planning pass. Feedback is driven only
/// by this post-commit value, so a failed automatic save cannot announce a
/// plan the store never accepted.
struct ForegroundPlanRefreshResult: Equatable {
    let materializedTasks: Int
    let sweptOrphans: Int
    let catchUpSummary: CatchUpSummary
    let replannedConflicts: Int
}

enum CaptureCoordinatorError: LocalizedError, Equatable {
    case emptyTitle
    case emptyBatch
    case invalidEffortMinutes
    case missingSettings

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "Add a name before saving."
        case .emptyBatch:
            return "Add at least one task before scheduling."
        case .invalidEffortMinutes:
            return "Each task needs a positive time estimate."
        case .missingSettings:
            return "Filuma couldn't load your planning settings. Nothing was saved."
        }
    }
}

/// Atomic persistence boundary for the quick-capture sheet. Scheduling stays
/// speculative until a deliberate commit; widgets, calendars, and other
/// observers only hear about rows that are already durable.
@MainActor
enum CaptureCoordinator {
    typealias PlanningInputLoader = @MainActor (ModelContext) throws -> TaskCapturePlanningInput
    typealias Save = @MainActor (ModelContext) throws -> Void
    typealias TaskPublisher = @MainActor (ModelContext, TaskCaptureReceipt) -> Void
    typealias ReminderPublisher = @MainActor (ModelContext, ReminderCaptureReceipt) -> Void
    typealias BulkPublisher = @MainActor (ModelContext, BulkCaptureReceipt) -> Void

    /// Build and schedule an unmanaged task. A failed read or validation error
    /// cannot leave a task, block, or settings row behind.
    static func prepareTask(
        title: String,
        firstStep: String,
        taskContext: TaskContext,
        deadline: Date,
        effortMinutes: Int,
        preferredStart: Date? = nil,
        now: Date = Date(),
        context: ModelContext,
        load: PlanningInputLoader = loadPlanningInput
    ) throws -> PreparedTaskCapture {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CaptureCoordinatorError.emptyTitle
        }
        let trimmedStep = firstStep.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = try load(context)
        let task = FilumaTask(
            title: trimmedTitle,
            context: taskContext,
            deadline: deadline,
            effortMinutes: effortMinutes,
            firstStep: trimmedStep.isEmpty ? nil : trimmedStep
        )
        let start = preferredStart.map { max($0, now) }
            ?? now.addingTimeInterval(TimeInterval(input.settings.startBufferMinutes * 60))
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: input.allBlocks,
            blockedTimes: input.blockedTimes,
            busyEvents: input.busyEvents,
            settings: input.settings,
            from: start
        )
        return PreparedTaskCapture(task: task, result: result)
    }

    /// Commit the prepared task, its exact provisional reservations, and an
    /// optional weekly template as one store transaction.
    @discardableResult
    static func commit(
        _ prepared: PreparedTaskCapture,
        repeatWeeklyUntil: Date? = nil,
        context: ModelContext,
        save: Save = { try $0.save() },
        publish: TaskPublisher = { context, _ in
            PlanCoordinator.publishChange(context: context)
        }
    ) throws -> TaskCaptureReceipt {
        // `rollback()` is context-wide. Preserve any accepted, unrelated UI
        // edits before capture starts its own atomic boundary.
        try context.save()

        let blocks = provisionalBlocks(in: prepared.result)
        let template = weeklyTemplate(
            for: prepared.task,
            repeatWeeklyUntil: repeatWeeklyUntil
        )
        do {
            try context.transaction {
                context.insert(prepared.task)
                for block in blocks {
                    // `discard` deliberately severs this inverse. Reattach at
                    // the commit boundary so a retry can never persist an
                    // orphaned provisional block.
                    block.task = prepared.task
                    context.insert(block)
                }
                if let template {
                    context.insert(template)
                    prepared.task.templateId = template.id
                }
                try save(context)
            }
        } catch {
            context.rollback()
            discard(prepared)
            context.processPendingChanges()
            throw error
        }

        let receipt = taskReceipt(
            for: prepared.task,
            blocks: blocks,
            templateID: template?.id
        )
        publish(context, receipt)
        return receipt
    }

    /// Commit the new task and rebuild the complete active plan, allowing its
    /// earlier deadline to move later work. The provisional result must be
    /// detached first so those speculative blocks cannot sneak into the graph.
    @discardableResult
    static func commitMakingRoom(
        _ prepared: PreparedTaskCapture,
        repeatWeeklyUntil: Date? = nil,
        now: Date = Date(),
        context: ModelContext,
        load: PlanningInputLoader = loadPlanningInputIncludingTasks,
        save: Save = { try $0.save() },
        publish: TaskPublisher = { context, _ in
            PlanCoordinator.publishChange(context: context)
        }
    ) throws -> TaskCaptureReceipt {
        // Detachment only touches the unmanaged capture graph. It must happen
        // before inserting the task or SwiftData may cascade-in stale blocks.
        discard(prepared)
        try context.save()

        let input = try load(context)
        let originalBlocksByTask = Dictionary(grouping: input.allBlocks) {
            $0.task?.id
        }
        let originalMarker = input.settings.lastFutileAutomaticRebalanceFingerprint
        let template = weeklyTemplate(
            for: prepared.task,
            repeatWeeklyUntil: repeatWeeklyUntil
        )

        do {
            try context.transaction {
                context.insert(prepared.task)
                if let template {
                    context.insert(template)
                    prepared.task.templateId = template.id
                }
                let currentTasks = input.tasks.filter { $0.id != prepared.task.id }
                SchedulerService.rebalance(
                    tasks: currentTasks + [prepared.task],
                    allBlocks: input.allBlocks,
                    blockedTimes: input.blockedTimes,
                    busyEvents: input.busyEvents,
                    settings: input.settings,
                    now: now,
                    context: context
                )
                try save(context)
            }
        } catch {
            context.rollback()

            // Keep already-held models truthful as well as the backing store.
            // SwiftData can retain attempted inverse relationships after a
            // rollback even though a fresh context sees the correct rows.
            for task in input.tasks where task.id != prepared.task.id {
                task.scheduledBlocks = originalBlocksByTask[task.id] ?? []
            }
            input.settings.lastFutileAutomaticRebalanceFingerprint = originalMarker
            discard(prepared)
            context.processPendingChanges()
            throw error
        }

        // Reading the inverse after the save cannot turn a durable success
        // into a reported failure. Fetch when possible, with the held inverse
        // as a no-throw fallback.
        let finalBlocks = ((try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
            .filter { $0.task?.id == prepared.task.id }
        let receipt = taskReceipt(
            for: prepared.task,
            blocks: finalBlocks.isEmpty ? prepared.task.scheduledBlocks : finalBlocks,
            templateID: template?.id
        )
        publish(context, receipt)
        return receipt
    }

    /// Save a reminder and only then tell widgets/notification coordination to
    /// reload. The receipt prevents downstream work from retaining a transient
    /// SwiftData object after a failed write.
    @discardableResult
    static func saveReminder(
        title: String,
        dueDate: Date,
        context: ModelContext,
        save: Save = { try $0.save() },
        publish: ReminderPublisher = { _, _ in SharedStore.reloadWidgets() }
    ) throws -> ReminderCaptureReceipt {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CaptureCoordinatorError.emptyTitle
        }
        try context.save()

        let reminder = Reminder(title: trimmedTitle, dueDate: dueDate)
        do {
            try context.transaction {
                context.insert(reminder)
                try save(context)
            }
        } catch {
            context.rollback()
            throw error
        }

        let receipt = ReminderCaptureReceipt(
            reminderID: reminder.id,
            title: reminder.title,
            dueDate: reminder.dueDate,
            notificationID: reminder.notificationId
        )
        publish(context, receipt)
        return receipt
    }

    /// Schedule every validated row against one planning snapshot. Provisional
    /// blocks are accumulated in input order so later rows see the reservations
    /// made for earlier rows, while nothing reaches SwiftData until the entire
    /// batch is ready to commit.
    @discardableResult
    static func commitBulk(
        _ drafts: [BulkTaskCaptureDraft],
        now: Date = Date(),
        context: ModelContext,
        load: PlanningInputLoader = loadPlanningInput,
        save: Save = { try $0.save() },
        publish: BulkPublisher = { context, _ in
            PlanCoordinator.publishChange(context: context)
        }
    ) throws -> BulkCaptureReceipt {
        let normalizedDrafts = try normalizeBulkDrafts(drafts)

        // Protect unrelated accepted edits from the transaction-wide rollback
        // used if the batch save fails.
        try context.save()

        // Every read that can fail completes before the first model insertion.
        // A fetch failure therefore cannot leave a partially captured batch.
        let input = try load(context)
        let start = now.addingTimeInterval(
            TimeInterval(input.settings.startBufferMinutes * 60)
        )
        var occupiedBlocks = input.allBlocks
        var preparedCaptures: [PreparedTaskCapture] = []
        preparedCaptures.reserveCapacity(normalizedDrafts.count)

        for draft in normalizedDrafts {
            let task = FilumaTask(
                title: draft.title,
                context: draft.context,
                deadline: draft.deadline,
                effortMinutes: draft.effortMinutes,
                source: .bulkEntry
            )
            let result = SchedulerService.schedule(
                task: task,
                allBlocks: occupiedBlocks,
                blockedTimes: input.blockedTimes,
                busyEvents: input.busyEvents,
                settings: input.settings,
                from: start
            )
            let capture = PreparedTaskCapture(task: task, result: result)
            preparedCaptures.append(capture)
            occupiedBlocks.append(contentsOf: provisionalBlocks(in: result))
        }

        do {
            try context.transaction {
                for prepared in preparedCaptures {
                    context.insert(prepared.task)
                    for block in provisionalBlocks(in: prepared.result) {
                        block.task = prepared.task
                        context.insert(block)
                    }
                }
                try save(context)
            }
        } catch {
            context.rollback()
            for prepared in preparedCaptures {
                discard(prepared)
            }
            context.processPendingChanges()
            throw error
        }

        let receipt = BulkCaptureReceipt(
            taskReceipts: preparedCaptures.map { prepared in
                taskReceipt(
                    for: prepared.task,
                    blocks: provisionalBlocks(in: prepared.result),
                    templateID: nil
                )
            }
        )
        publish(context, receipt)
        return receipt
    }

    /// Sever every speculative result relationship so cancellation and Make
    /// Room cannot accidentally cascade-in provisional blocks with the task.
    static func discard(_ prepared: PreparedTaskCapture) {
        // Include blocks created by an attempted rebalance as well as the
        // original result. A failed Make Room transaction can leave those
        // transient inverse objects visible on the held task after rollback.
        let blocks = provisionalBlocks(in: prepared.result)
            + prepared.task.scheduledBlocks
        var detachedIDs = Set<UUID>()
        for block in blocks where detachedIDs.insert(block.id).inserted {
            block.task = nil
        }
        prepared.task.scheduledBlocks.removeAll()
        prepared.task.templateId = nil
    }

    private static func loadPlanningInput(
        context: ModelContext
    ) throws -> TaskCapturePlanningInput {
        guard let settings = try context.fetch(FetchDescriptor<UserSettings>()).first else {
            throw CaptureCoordinatorError.missingSettings
        }
        return TaskCapturePlanningInput(
            settings: settings,
            allBlocks: try context.fetch(FetchDescriptor<ScheduledBlock>()),
            blockedTimes: try context.fetch(FetchDescriptor<BlockedTime>()),
            busyEvents: try context.fetch(FetchDescriptor<BusyEvent>())
        )
    }

    private static func loadPlanningInputIncludingTasks(
        context: ModelContext
    ) throws -> TaskCapturePlanningInput {
        let input = try loadPlanningInput(context: context)
        return TaskCapturePlanningInput(
            settings: input.settings,
            allBlocks: input.allBlocks,
            blockedTimes: input.blockedTimes,
            busyEvents: input.busyEvents,
            tasks: try context.fetch(FetchDescriptor<FilumaTask>())
        )
    }

    private static func provisionalBlocks(in result: ScheduleResult) -> [ScheduledBlock] {
        switch result {
        case .success(let blocks), .partialFit(let blocks, _):
            return blocks
        case .noSlots:
            return []
        }
    }

    private static func normalizeBulkDrafts(
        _ drafts: [BulkTaskCaptureDraft]
    ) throws -> [BulkTaskCaptureDraft] {
        guard !drafts.isEmpty else {
            throw CaptureCoordinatorError.emptyBatch
        }
        return try drafts.map { draft in
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CaptureCoordinatorError.emptyTitle
            }
            guard draft.effortMinutes > 0 else {
                throw CaptureCoordinatorError.invalidEffortMinutes
            }
            return BulkTaskCaptureDraft(
                title: title,
                context: draft.context,
                deadline: draft.deadline,
                effortMinutes: draft.effortMinutes
            )
        }
    }

    private static func weeklyTemplate(
        for task: FilumaTask,
        repeatWeeklyUntil: Date?
    ) -> TaskTemplate? {
        guard let repeatWeeklyUntil,
              let nextDeadline = Calendar.current.date(
                  byAdding: .day,
                  value: 7,
                  to: task.deadline
              ),
              nextDeadline <= repeatWeeklyUntil else {
            return nil
        }
        return TaskTemplate(
            title: task.title,
            context: task.context,
            effortMinutes: task.effortMinutes,
            firstStep: task.firstStep,
            nextDeadline: nextDeadline,
            repeatUntil: repeatWeeklyUntil
        )
    }

    private static func taskReceipt(
        for task: FilumaTask,
        blocks: [ScheduledBlock],
        templateID: UUID?
    ) -> TaskCaptureReceipt {
        let scheduled = blocks.reduce(0) { $0 + $1.durationMinutes }
        return TaskCaptureReceipt(
            taskID: task.id,
            title: task.title,
            context: task.context,
            deadline: task.deadline,
            scheduledBlockCount: blocks.count,
            scheduledMinutes: scheduled,
            unscheduledMinutes: max(0, task.remainingMinutes - scheduled),
            firstBlockStart: blocks.map(\.startTime).min(),
            templateID: templateID
        )
    }
}

/// Atomic boundary for changing an existing one-off reminder. The view's held
/// model, the durable row, the local notification, and widgets must never tell
/// four different stories after a rejected save.
@MainActor
enum ReminderMutationCoordinator {
    typealias Save = @MainActor (ModelContext) throws -> Void
    typealias Publisher = @MainActor (ReminderMutationReceipt) -> Void

    private struct HeldSnapshot {
        let reminder: Reminder
        let id: UUID
        let title: String
        let dueDate: Date
        let isComplete: Bool
        let notificationID: String

        init(_ reminder: Reminder) {
            self.reminder = reminder
            id = reminder.id
            title = reminder.title
            dueDate = reminder.dueDate
            isComplete = reminder.isComplete
            notificationID = reminder.notificationId
        }

        /// SwiftData restores the store when its transaction throws, but an
        /// already-held object can continue projecting attempted values. Make
        /// that live projection match the durable snapshot before a retry.
        func repair(in context: ModelContext) {
            reminder.id = id
            reminder.title = title
            reminder.dueDate = dueDate
            reminder.isComplete = isComplete
            reminder.notificationId = notificationID
            context.processPendingChanges()
        }
    }

    /// Complete, restore, or delete exactly one reminder. The initial save is
    /// deliberately outside the transaction: rollback is context-wide, so
    /// unrelated work accepted earlier in the UI must become durable before
    /// this operation opens its own failure boundary.
    @discardableResult
    static func apply(
        _ mutation: ReminderMutation,
        to reminder: Reminder,
        context: ModelContext,
        save: Save = { try $0.save() },
        publish: Publisher = publishCommittedMutation
    ) throws -> ReminderMutationReceipt {
        try context.save()

        let snapshot = HeldSnapshot(reminder)
        let receipt = ReminderMutationReceipt(
            reminderID: snapshot.id,
            title: snapshot.title,
            dueDate: snapshot.dueDate,
            notificationID: snapshot.notificationID,
            mutation: mutation
        )

        do {
            try context.transaction {
                switch mutation {
                case .complete:
                    reminder.isComplete = true
                case .restore:
                    reminder.isComplete = false
                case .delete:
                    context.delete(reminder)
                }
                try save(context)
            }
        } catch {
            context.rollback()
            snapshot.repair(in: context)
            throw error
        }

        // Notifications and widgets only observe a row state the store has
        // accepted. A failed save therefore has a publish count of exactly 0.
        publish(receipt)
        return receipt
    }

    private static func publishCommittedMutation(_ receipt: ReminderMutationReceipt) {
        switch receipt.mutation {
        case .complete, .delete:
            NotificationService.cancel(notificationID: receipt.notificationID)
        case .restore:
            NotificationService.schedule(receipt: receipt)
        }
        SharedStore.reloadWidgets()
    }
}

/// Tiny state machine for busy-time repair requests that arrive while a work
/// session owns its scheduled block. Keeping this value separate makes the
/// defer/resume contract deterministic without putting SwiftData or App Group
/// state into policy tests.
struct DeferredBusyTimeConflictReplanState {
    private(set) var hasPendingRequest = false

    /// Returns `true` when the caller may repair conflicts immediately.
    mutating func request(canRewriteSchedule: Bool) -> Bool {
        guard canRewriteSchedule else {
            hasPendingRequest = true
            return false
        }
        hasPendingRequest = false
        return true
    }

    /// Consumes a deferred request only once schedule ownership is available.
    mutating func resume(canRewriteSchedule: Bool) -> Bool {
        guard hasPendingRequest, canRewriteSchedule else { return false }
        hasPendingRequest = false
        return true
    }
}

/// The app-level boundary for mutating an existing plan. Views report the
/// user's intent here; scheduling, calendar mirrors, widgets, and nudges stay
/// in sync behind one small surface.
@MainActor
enum PlanCoordinator {
    typealias RecurrenceStopLoader = @MainActor (
        UUID,
        ModelContext
    ) throws -> (template: TaskTemplate?, tasks: [FilumaTask])

    private static var deferredBusyTimeConflictReplan =
        DeferredBusyTimeConflictReplanState()

    private struct HeldTaskPlanSnapshot {
        let task: FilumaTask
        let isComplete: Bool
        let completedAt: Date?
        let progress: Int
        let scheduledBlocks: [ScheduledBlock]

        init(_ task: FilumaTask) {
            self.task = task
            isComplete = task.isComplete
            completedAt = task.completedAt
            progress = task.manualProgressPercent
            scheduledBlocks = task.scheduledBlocks
        }

        @MainActor
        func repair(in context: ModelContext) {
            PlanCoordinator.repairHeldTaskAfterRollback(
                task,
                isComplete: isComplete,
                completedAt: completedAt,
                progress: progress,
                scheduledBlocks: scheduledBlocks,
                context: context
            )
            for block in scheduledBlocks {
                block.task = task
            }
        }
    }

    /// Publish the current plan to every downstream consumer.
    static func publishChange(context: ModelContext, interactive: Bool = true) {
        if FilumaProAccess.isPro {
            CalendarExportService.syncIfEnabled(context: context)
            GoogleCalendarService.exportIfEnabled(context: context)
        }
        scheduleDidChange(context: context, interactive: interactive)
    }

    /// Save one editor draft and any replacement reservations as a single
    /// durable mutation. Views never write into the live SwiftData task before
    /// entering this boundary, so a rejected save cannot leak half-edited
    /// details or a half-rebuilt plan into the UI.
    @discardableResult
    static func saveTaskEdits(
        _ task: FilumaTask,
        update: TaskEditUpdate,
        context: ModelContext,
        now: Date = Date(),
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext) -> Void = { context in
            PlanCoordinator.publishChange(context: context)
        }
    ) throws -> ScheduleResult? {
        let trimmedTitle = update.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TaskEditCoordinatorError.emptyTitle
        }
        guard update.effortMinutes > 0 else {
            throw TaskEditCoordinatorError.invalidEffortMinutes
        }
        guard update.deadline > now else {
            throw TaskEditCoordinatorError.deadlineNotFuture
        }

        // `rollback()` is context-wide. Preserve any accepted, unrelated UI
        // work before the editor begins its own transactional boundary.
        try context.save()

        let needsReplan = update.deadline != task.deadline
            || update.effortMinutes != task.effortMinutes

        let originalTitle = task.title
        let originalFirstStep = task.firstStep
        let originalContext = task.context
        let originalDeadline = task.deadline
        let originalEffortMinutes = task.effortMinutes
        let originalUserModified = task.userModified
        let originalTaskBlocks = task.scheduledBlocks

        var result: ScheduleResult?
        var planningSettings: UserSettings?
        var shouldInsertPlanningSettings = false
        var blockedTimes: [BlockedTime] = []
        var busyEvents: [BusyEvent] = []

        if needsReplan {
            // Empty fallbacks would make a transient read failure look like an
            // open calendar and could replace a truthful plan with overlaps.
            let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
            if let existingSettings {
                planningSettings = existingSettings
            } else {
                planningSettings = UserSettings()
                shouldInsertPlanningSettings = true
            }
            blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
            busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        }

        do {
            try context.transaction {
                if shouldInsertPlanningSettings, let planningSettings {
                    // Keep a newly required defaults row inside the same
                    // rollback scope as the editor mutation. No failed read or
                    // rejected replacement-plan save can leak it into a later
                    // unrelated save.
                    context.insert(planningSettings)
                }
                task.title = trimmedTitle
                let trimmedStep = update.firstStep?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                task.firstStep = (trimmedStep?.isEmpty == false) ? trimmedStep : nil
                task.context = update.taskContext
                task.deadline = update.deadline
                task.effortMinutes = update.effortMinutes
                task.userModified = true

                if needsReplan, let settings = planningSettings {
                    let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
                    result = SchedulerService.reschedule(
                        task: task,
                        allBlocks: allBlocks,
                        blockedTimes: blockedTimes,
                        busyEvents: busyEvents,
                        settings: settings,
                        now: now,
                        context: context
                    )
                }
                try save(context)
            }
        } catch {
            context.rollback()
            task.title = originalTitle
            task.firstStep = originalFirstStep
            task.context = originalContext
            task.deadline = originalDeadline
            task.effortMinutes = originalEffortMinutes
            task.userModified = originalUserModified
            task.scheduledBlocks = originalTaskBlocks
            context.processPendingChanges()
            throw error
        }

        // Marker refresh and downstream mirrors observe only the committed
        // details and reservations. Their bookkeeping cannot turn a successful
        // durable edit into a misleading Save failure.
        if needsReplan, let settings = planningSettings {
            let resultingTasks = try? context.fetch(FetchDescriptor<FilumaTask>())
            let resultingBlocks = try? context.fetch(FetchDescriptor<ScheduledBlock>())

            // SchedulerService returns only newly placed rows because retained
            // locks were never replacements. The editor, however, describes
            // the complete durable future plan; include those retained rows so
            // its saved-state confirmation never understates real coverage.
            if let placementResult = result {
                result = resultIncludingRetainedLockedCoverage(
                    placementResult,
                    task: task,
                    allBlocks: resultingBlocks ?? task.scheduledBlocks,
                    settings: settings,
                    now: now
                )
            }

            if let resultingTasks, let resultingBlocks {
                SchedulerService.updateFutileAutomaticRebalanceMarker(
                    tasks: resultingTasks,
                    allBlocks: resultingBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings
                )
            }
        }
        publish(context)
        return result
    }

    /// Adapt replacement-only scheduler output for explicit task replans
    /// without changing SchedulerService semantics for every other caller.
    /// Returned blocks are real durable reservations, de-duplicated by identity.
    private static func resultIncludingRetainedLockedCoverage(
        _ placementResult: ScheduleResult,
        task: FilumaTask,
        allBlocks: [ScheduledBlock],
        settings: UserSettings,
        now: Date = Date()
    ) -> ScheduleResult {
        let windowEnd = task.deadline.addingTimeInterval(
            -Double(settings.deadlineBufferMinutes) * 60
        )
        let retainedLocked = allBlocks.filter {
            $0.task?.id == task.id
                && $0.isLocked
                && !$0.isComplete
                && $0.endTime > now
                && $0.startTime < windowEnd
        }

        func combined(with placed: [ScheduledBlock]) -> [ScheduledBlock] {
            var seen = Set<UUID>()
            return (retainedLocked + placed).filter { seen.insert($0.id).inserted }
        }

        switch placementResult {
        case .success(let placed):
            return .success(blocks: combined(with: placed))

        case .partialFit(let placed, let unscheduledMinutes):
            return .partialFit(
                scheduled: combined(with: placed),
                unscheduledMinutes: unscheduledMinutes
            )

        case .noSlots:
            let retainedMinutes = retainedLocked.reduce(0) { total, block in
                let overlapStart = max(block.startTime, now)
                let overlapEnd = min(block.endTime, windowEnd)
                guard overlapStart < overlapEnd else { return total }
                return total + max(
                    0,
                    Int(floor(overlapEnd.timeIntervalSince(overlapStart) / 60 + 0.000_001))
                )
            }
            guard retainedMinutes > 0 else { return .noSlots }
            let unscheduledMinutes = max(0, task.remainingMinutes - retainedMinutes)
            return unscheduledMinutes == 0
                ? .success(blocks: retainedLocked)
                : .partialFit(
                    scheduled: retainedLocked,
                    unscheduledMinutes: unscheduledMinutes
                )
        }
    }

    /// Replace one task's movable future blocks as a single durable mutation.
    /// Callers receive a result only after the replacement plan is saved;
    /// failed reads and writes preserve both the durable store and held model.
    @discardableResult
    static func rescheduleTask(
        _ task: FilumaTask,
        context: ModelContext,
        from startDate: Date? = nil,
        now: Date = Date(),
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> ScheduleResult {
        // `rollback()` is context-wide. Preserve accepted unrelated edits
        // before the task-specific replacement boundary begins.
        try context.save()

        let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let settings = existingSettings ?? UserSettings()
        let originalIsComplete = task.isComplete
        let originalCompletedAt = task.completedAt
        let originalProgress = task.manualProgressPercent
        let originalTaskBlocks = task.scheduledBlocks
        var result: ScheduleResult = .noSlots

        do {
            try context.transaction {
                if existingSettings == nil {
                    context.insert(settings)
                }
                result = SchedulerService.reschedule(
                    task: task,
                    allBlocks: allBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings,
                    from: startDate,
                    now: now,
                    context: context
                )
                try save(context)
            }
        } catch {
            context.rollback()
            repairHeldTaskAfterRollback(
                task,
                isComplete: originalIsComplete,
                completedAt: originalCompletedAt,
                progress: originalProgress,
                scheduledBlocks: originalTaskBlocks,
                context: context
            )
            throw error
        }

        // Automatic-repair bookkeeping and external mirrors observe only the
        // committed rows. Post-commit bookkeeping cannot turn a durable plan
        // into a misleading failure result.
        if let resultingTasks = try? context.fetch(FetchDescriptor<FilumaTask>()),
           let resultingBlocks = try? context.fetch(FetchDescriptor<ScheduledBlock>()) {
            result = resultIncludingRetainedLockedCoverage(
                result,
                task: task,
                allBlocks: resultingBlocks,
                settings: settings,
                now: now
            )
            SchedulerService.updateFutileAutomaticRebalanceMarker(
                tasks: resultingTasks,
                allBlocks: resultingBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                now: now
            )
        } else {
            // The plan is already durable. A post-commit bookkeeping read may
            // fail without inviting a destructive retry; adapt from the held
            // relationship so user-facing coverage still includes its locks.
            result = resultIncludingRetainedLockedCoverage(
                result,
                task: task,
                allBlocks: task.scheduledBlocks,
                settings: settings,
                now: now
            )
        }
        publish(context, interactive)
        return result
    }

    /// Progress changes remaining effort, so replace the task's movable future
    /// blocks with coverage for that smaller remainder.
    @discardableResult
    static func reconcileTaskAfterProgress(
        _ task: FilumaTask,
        context: ModelContext,
        now: Date = Date(),
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> ScheduleResult {
        try rescheduleTask(
            task,
            context: context,
            now: now,
            interactive: interactive,
            save: save,
            publish: publish
        )
    }

    /// Replace the remaining reservations after a timed session fulfills one
    /// scheduled block. The attendance row and completed block are already
    /// durable when this boundary begins; a rejected replacement-plan save
    /// must therefore preserve those facts while restoring the prior plan for
    /// a safe retry.
    @discardableResult
    static func reconcileTaskAfterAttendance(
        _ task: FilumaTask,
        context: ModelContext,
        now: Date = Date(),
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext) -> Void = { context in
            PlanCoordinator.publishChange(context: context)
        }
    ) throws -> ScheduleResult {
        try rescheduleTask(
            task,
            context: context,
            now: now,
            save: save,
            publish: { context, _ in publish(context) }
        )
    }

    /// Persist a schedule-row attendance toggle together with the active
    /// task's replacement reservations. The view submits intent rather than
    /// pre-mutating SwiftData, so a rejected save cannot strand a checked row
    /// beside the old plan or durably save the toggle during preflight.
    @discardableResult
    static func setBlockCompletion(
        _ block: ScheduledBlock,
        isComplete: Bool,
        context: ModelContext,
        now: Date = Date(),
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> ScheduleResult? {
        guard block.isComplete != isComplete else { return nil }

        try context.save()
        let task = block.task
        let needsReplan = task?.isComplete == false
        var existingSettings: UserSettings?
        var allBlocks: [ScheduledBlock] = []
        var blockedTimes: [BlockedTime] = []
        var busyEvents: [BusyEvent] = []
        var settings: UserSettings?
        if needsReplan {
            existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
            settings = existingSettings ?? UserSettings()
            allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
            blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
            busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        }

        let originalBlockCompletion = block.isComplete
        let originalIsComplete = task?.isComplete ?? false
        let originalCompletedAt = task?.completedAt
        let originalProgress = task?.manualProgressPercent ?? 0
        let originalTaskBlocks = task?.scheduledBlocks ?? []
        var result: ScheduleResult?

        do {
            try context.transaction {
                if needsReplan, existingSettings == nil, let settings {
                    context.insert(settings)
                }
                block.isComplete = isComplete
                if needsReplan, let task, let settings {
                    result = SchedulerService.reschedule(
                        task: task,
                        allBlocks: allBlocks,
                        blockedTimes: blockedTimes,
                        busyEvents: busyEvents,
                        settings: settings,
                        now: now,
                        context: context
                    )
                }
                try save(context)
            }
        } catch {
            context.rollback()
            block.isComplete = originalBlockCompletion
            if let task {
                repairHeldTaskAfterRollback(
                    task,
                    isComplete: originalIsComplete,
                    completedAt: originalCompletedAt,
                    progress: originalProgress,
                    scheduledBlocks: originalTaskBlocks,
                    context: context
                )
                block.task = task
            } else {
                context.processPendingChanges()
            }
            throw error
        }

        if needsReplan, let settings, let task, let placementResult = result {
            let resultingTasks = try? context.fetch(FetchDescriptor<FilumaTask>())
            let resultingBlocks = try? context.fetch(FetchDescriptor<ScheduledBlock>())
            result = resultIncludingRetainedLockedCoverage(
                placementResult,
                task: task,
                allBlocks: resultingBlocks ?? task.scheduledBlocks,
                settings: settings,
                now: now
            )
            if let resultingTasks, let resultingBlocks {
                SchedulerService.updateFutileAutomaticRebalanceMarker(
                    tasks: resultingTasks,
                    allBlocks: resultingBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings,
                    now: now
                )
            }
        }
        publish(context, interactive)
        return result
    }

    /// Delete a task and its complete child graph as one durable operation.
    /// Explicit child deletion protects stores whose historical cascade did
    /// not cleanly finish, while rollback repairs held inverse relationships.
    static func deleteTask(
        _ task: FilumaTask,
        context: ModelContext,
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws {
        try context.save()
        let originalBlocks = task.scheduledBlocks
        let originalSessions = task.workSessions

        do {
            try context.transaction {
                for block in originalBlocks {
                    context.delete(block)
                }
                for session in originalSessions {
                    context.delete(session)
                }
                context.delete(task)
                try save(context)
            }
        } catch {
            context.rollback()
            task.scheduledBlocks = originalBlocks
            task.workSessions = originalSessions
            for block in originalBlocks {
                block.task = task
            }
            for session in originalSessions {
                session.task = task
            }
            context.processPendingChanges()
            throw error
        }

        publish(context, interactive)
    }

    /// End a recurrence and detach every already-materialized occurrence as
    /// one durable change. A missing template is valid: an exhausted template
    /// may leave stale occurrence markers that should still be cleaned up.
    static func stopRepeating(
        templateID: UUID,
        context: ModelContext,
        interactive: Bool = true,
        load: RecurrenceStopLoader = { templateID, context in
            let template = try context.fetch(FetchDescriptor<TaskTemplate>())
                .first { $0.id == templateID }
            let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
                .filter { $0.templateId == templateID }
            return (template, tasks)
        },
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws {
        // rollback() is context-wide. First make unrelated pending edits
        // durable so a recurrence failure cannot erase them.
        try context.save()

        let input = try load(templateID, context)
        let originalMarkers = input.tasks.map { ($0, $0.templateId) }

        do {
            try context.transaction {
                if let template = input.template {
                    context.delete(template)
                }
                for task in input.tasks {
                    task.templateId = nil
                }
                try save(context)
            }
        } catch {
            context.rollback()
            for (task, marker) in originalMarkers {
                task.templateId = marker
            }
            context.processPendingChanges()
            throw error
        }

        publish(context, interactive)
    }

    /// Persist self-reported progress and its replacement reservations as one
    /// durable change. Partial progress is monotonic and cannot cross the
    /// completion boundary; a 100% report must use `completeTask` instead.
    @discardableResult
    static func savePartialProgress(
        _ task: FilumaTask,
        reportedProgress: Int,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() },
        interactive: Bool = true
    ) throws -> ScheduleResult {
        // `rollback()` is context-wide. Make any earlier, unrelated edits
        // durable before this operation starts so a rejected progress update
        // cannot erase work that was already accepted elsewhere in the UI.
        try context.save()

        // Scheduling with an empty fallback after a failed fetch could replace
        // a valid plan with overlapping reservations. Fetch every input
        // fallibly and leave the durable plan untouched if any read fails.
        let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let settings: UserSettings
        if let existingSettings {
            settings = existingSettings
        } else {
            settings = UserSettings()
            context.insert(settings)
        }

        let originalIsComplete = task.isComplete
        let originalCompletedAt = task.completedAt
        let originalProgress = task.manualProgressPercent
        let originalTaskBlocks = task.scheduledBlocks
        let clampedProgress = min(99, max(0, reportedProgress))
        var result: ScheduleResult = .noSlots

        do {
            try context.transaction {
                // Clamp the stored value as well as the report. Active tasks
                // must never persist the completion-only value of 100.
                task.manualProgressPercent = min(
                    99,
                    max(originalProgress, clampedProgress)
                )
                result = SchedulerService.reschedule(
                    task: task,
                    allBlocks: allBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings,
                    context: context
                )
                try save(context)
            }
        } catch {
            context.rollback()
            repairHeldTaskAfterRollback(
                task,
                isComplete: originalIsComplete,
                completedAt: originalCompletedAt,
                progress: originalProgress,
                scheduledBlocks: originalTaskBlocks,
                context: context
            )
            throw error
        }

        // Downstream state only observes the new progress after both the task
        // value and its replacement reservations are durable.
        // Marker refresh is downstream bookkeeping, not part of the durable
        // mutation boundary. A post-commit fetch failure must never tell the
        // caller that progress was not saved (and invite a misleading retry).
        if let resultingTasks = try? context.fetch(FetchDescriptor<FilumaTask>()),
           let resultingBlocks = try? context.fetch(FetchDescriptor<ScheduledBlock>()) {
            SchedulerService.updateFutileAutomaticRebalanceMarker(
                tasks: resultingTasks,
                allBlocks: resultingBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings
            )
        }
        publishChange(context: context, interactive: interactive)
        return result
    }

    /// Complete a task and release every incomplete reservation in one durable
    /// boundary. A 100% progress report enters through the same save, so the
    /// store can never preserve a 100%-but-active intermediate state.
    @discardableResult
    static func completeTask(
        _ task: FilumaTask,
        context: ModelContext,
        reportedProgress: Int? = nil,
        completedAt completionDate: Date = Date(),
        save: (ModelContext) throws -> Void = { try $0.save() },
        interactive: Bool = false
    ) throws -> TaskCompletionReceipt {
        // `rollback()` is context-wide. Flush any earlier, unrelated edits
        // before opening the completion transaction so a rejected completion
        // cannot also undo (for example) a reminder the user just checked.
        // This save happens before any completion field or reservation moves.
        try context.save()
        let originalIsComplete = task.isComplete
        let originalCompletedAt = task.completedAt
        let originalProgress = task.manualProgressPercent
        let originalTaskBlocks = task.scheduledBlocks

        if task.isComplete, let originalCompletion = task.completedAt {
            let receipt = TaskCompletionReceipt(
                taskID: task.id,
                title: task.title,
                context: task.context,
                deadline: task.deadline,
                completedAt: originalCompletion,
                timeSpentMinutes: task.timeSpentMinutes
            )
            let lingeringReservations = task.scheduledBlocks.filter { !$0.isComplete }
            guard !lingeringReservations.isEmpty else { return receipt }

            // Idempotent completion preserves the original timestamp, while
            // still repairing legacy/corrupt stores that left reservations on
            // an already-completed task.
            for block in lingeringReservations {
                context.delete(block)
            }
            do {
                try save(context)
            } catch {
                context.rollback()
                repairHeldTaskAfterRollback(
                    task,
                    isComplete: originalIsComplete,
                    completedAt: originalCompletedAt,
                    progress: originalProgress,
                    scheduledBlocks: originalTaskBlocks,
                    context: context
                )
                throw error
            }
            publishChange(context: context, interactive: interactive)
            return receipt
        }

        if let reportedProgress {
            task.manualProgressPercent = max(
                task.manualProgressPercent,
                min(100, max(0, reportedProgress))
            )
        }
        task.isComplete = true
        task.completedAt = completionDate
        for block in task.scheduledBlocks where !block.isComplete {
            context.delete(block)
        }

        let receipt = TaskCompletionReceipt(
            taskID: task.id,
            title: task.title,
            context: task.context,
            deadline: task.deadline,
            completedAt: completionDate,
            timeSpentMinutes: task.timeSpentMinutes
        )

        do {
            // Persist releases immediately. This prevents deleted child blocks
            // from resurfacing later as orphaned schedule rows. Rollback keeps
            // the task active if the store rejects the whole completion.
            try save(context)
        } catch {
            context.rollback()
            repairHeldTaskAfterRollback(
                task,
                isComplete: originalIsComplete,
                completedAt: originalCompletedAt,
                progress: originalProgress,
                scheduledBlocks: originalTaskBlocks,
                context: context
            )
            throw error
        }
        publishChange(context: context, interactive: interactive)
        return receipt
    }

    /// Bring completed work back through the same scheduling boundary used by
    /// all other progress changes. This is a restore-and-replan, not a promise
    /// that the task's former reservation times can be reconstructed exactly.
    @discardableResult
    static func restoreTask(
        _ task: FilumaTask,
        context: ModelContext,
        now: Date = Date(),
        save: (ModelContext) throws -> Void = { try $0.save() },
        interactive: Bool = true
    ) throws -> ScheduleResult {
        // Establish the same scoped rollback boundary as completion. The
        // restore, its progress adjustment, and its new reservations then
        // either persist together or return to the durable completed state.
        try context.save()

        // An empty fallback would make a transient read failure look like a
        // clear calendar. Defaults, when genuinely absent, join the restore's
        // transaction rather than leaking out of a failed Undo.
        let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let settings = existingSettings ?? UserSettings()
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let originalIsComplete = task.isComplete
        let originalCompletedAt = task.completedAt
        let originalProgress = task.manualProgressPercent
        let originalTaskBlocks = task.scheduledBlocks
        var result: ScheduleResult = .noSlots

        // The transaction restores the store when the injected save throws.
        // Registered model instances can still retain attempted values, so the
        // catch path below repairs that in-memory projection as well.
        do {
            try context.transaction {
                if existingSettings == nil {
                    context.insert(settings)
                }
                task.isComplete = false
                task.completedAt = nil
                if task.manualProgressPercent >= 100 {
                    task.manualProgressPercent = 90
                }
                result = SchedulerService.reschedule(
                    task: task,
                    allBlocks: allBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings,
                    now: now,
                    context: context
                )
                try save(context)
            }
        } catch {
            context.rollback()
            // SwiftData correctly restores the store, but a registered model
            // may retain the attempted values after rollback. Mirror the
            // durable snapshot back into that held instance so @Query and a
            // second Restore tap cannot act on a phantom active task.
            repairHeldTaskAfterRollback(
                task,
                isComplete: originalIsComplete,
                completedAt: originalCompletedAt,
                progress: originalProgress,
                scheduledBlocks: originalTaskBlocks,
                context: context
            )
            throw error
        }

        // Match the explicit reschedule path's automatic-repair baseline, but
        // only after the restored plan itself is durable.
        if let resultingTasks = try? context.fetch(FetchDescriptor<FilumaTask>()),
           let resultingBlocks = try? context.fetch(FetchDescriptor<ScheduledBlock>()) {
            result = resultIncludingRetainedLockedCoverage(
                result,
                task: task,
                allBlocks: resultingBlocks,
                settings: settings,
                now: now
            )
            SchedulerService.updateFutileAutomaticRebalanceMarker(
                tasks: resultingTasks,
                allBlocks: resultingBlocks,
                blockedTimes: blockedTimes,
                busyEvents: busyEvents,
                settings: settings,
                now: now
            )
        }
        publishChange(context: context, interactive: interactive)
        return result
    }

    /// SwiftData can leave an already-registered model projecting attempted
    /// values after the store itself rolls back. Keep the live UI aligned with
    /// the durable snapshot; a later save is semantically a no-op.
    private static func repairHeldTaskAfterRollback(
        _ task: FilumaTask,
        isComplete: Bool,
        completedAt: Date?,
        progress: Int,
        scheduledBlocks: [ScheduledBlock],
        context: ModelContext
    ) {
        task.isComplete = isComplete
        task.completedAt = completedAt
        task.manualProgressPercent = progress
        task.scheduledBlocks = scheduledBlocks
        context.processPendingChanges()
    }

    /// Planning preferences invalidate every active task's movable blocks.
    @discardableResult
    static func rebuildAfterPlanningPreferencesChange(
        context: ModelContext,
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> CatchUpSummary {
        try rebuildPlan(
            context: context,
            interactive: interactive,
            save: save,
            publish: publish
        )
    }

    /// Rebuild every active task by deadline and publish the resulting plan.
    /// This is also the application boundary for explicit "make room" actions.
    @discardableResult
    static func rebuildPlan(
        context: ModelContext,
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> CatchUpSummary {
        // Planning preferences are edited directly by Settings. Checkpoint
        // that accepted UI state before the context-wide rollback boundary.
        try context.save()

        let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let settings = existingSettings ?? UserSettings()
        let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let snapshots = tasks.map(HeldTaskPlanSnapshot.init)
        let originalMarker = existingSettings?.lastFutileAutomaticRebalanceFingerprint
        let originalPlanningRebuildPending = existingSettings?.planningRebuildPending
        var summary = CatchUpSummary()

        do {
            try context.transaction {
                if existingSettings == nil {
                    context.insert(settings)
                }
                summary = SchedulerService.rebalance(
                    tasks: tasks,
                    allBlocks: allBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings,
                    context: context
                )
                settings.planningRebuildPending = false
                try save(context)
            }
        } catch {
            context.rollback()
            if let existingSettings {
                existingSettings.lastFutileAutomaticRebalanceFingerprint = originalMarker
                existingSettings.planningRebuildPending =
                    originalPlanningRebuildPending ?? false
            }
            for snapshot in snapshots {
                snapshot.repair(in: context)
            }
            context.processPendingChanges()
            throw error
        }

        publish(context, interactive)
        return summary
    }

    /// Run every local foreground maintenance step inside one durable planning
    /// transaction. Calendar import may have staged changes immediately before
    /// this call; the preflight accepts those unrelated rows first so a later
    /// planning rollback cannot erase them.
    @discardableResult
    static func refreshForegroundPlan(
        context: ModelContext,
        now: Date = Date(),
        activeWorkSession: WorkSessionControlState? = WorkSessionControlStore.load(),
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> ForegroundPlanRefreshResult {
        try context.save()

        let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let settings = existingSettings ?? UserSettings()
        let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
        let templates = try context.fetch(FetchDescriptor<TaskTemplate>())
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let allSessions = try context.fetch(FetchDescriptor<WorkSession>())
        let blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let orphanBlocks = allBlocks.filter { $0.task == nil }
        let orphanSessions = allSessions.filter { $0.task == nil }
        let taskSnapshots = tasks.map(HeldTaskPlanSnapshot.init)
        let templateDeadlines = templates.map { ($0, $0.nextDeadline) }
        let originalMarker = existingSettings?.lastFutileAutomaticRebalanceFingerprint
        let originalPlanningRebuildPending = existingSettings?.planningRebuildPending
        let originalDeferredState = deferredBusyTimeConflictReplan
        let canRewriteSchedule = AutomaticPlanRefreshPolicy.canRewriteSchedule(
            activeWorkSession: activeWorkSession
        )
        var materializedTasks = 0
        var catchUpSummary = CatchUpSummary()
        var replannedConflicts = 0

        do {
            try context.transaction {
                if existingSettings == nil {
                    context.insert(settings)
                }
                for block in orphanBlocks {
                    context.delete(block)
                }
                for session in orphanSessions {
                    context.delete(session)
                }

                if FilumaProAccess.isPro {
                    materializedTasks = SchedulerService.materializeRecurringTasks(
                        templates: templates,
                        allBlocks: allBlocks.filter { $0.task != nil },
                        blockedTimes: blockedTimes,
                        busyEvents: busyEvents,
                        settings: settings,
                        now: now,
                        context: context
                    )
                }
                context.processPendingChanges()

                if canRewriteSchedule {
                    _ = deferredBusyTimeConflictReplan.request(
                        canRewriteSchedule: true
                    )
                    let currentTasks = try context.fetch(FetchDescriptor<FilumaTask>())
                    let currentBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
                        .filter { $0.task != nil }
                    if settings.planningRebuildPending {
                        catchUpSummary = SchedulerService.rebalance(
                            tasks: currentTasks,
                            allBlocks: currentBlocks,
                            blockedTimes: blockedTimes,
                            busyEvents: busyEvents,
                            settings: settings,
                            now: now,
                            context: context
                        )
                        catchUpSummary.adjustedTasks = currentTasks.filter {
                            !$0.isComplete && $0.deadline > now
                        }.count
                        settings.planningRebuildPending = false
                    } else {
                        catchUpSummary = SchedulerService.catchUpMissedBlocks(
                            tasks: currentTasks,
                            allBlocks: currentBlocks,
                            blockedTimes: blockedTimes,
                            busyEvents: busyEvents,
                            settings: settings,
                            now: now,
                            context: context
                        )

                        // A catch-up rebalance already rebuilt every active task
                        // around current busy inputs. Run the narrower repair only
                        // when catch-up did not rewrite the plan.
                        if catchUpSummary.adjustedTasks == 0 {
                            replannedConflicts = SchedulerService.replanConflicts(
                                tasks: currentTasks,
                                allBlocks: currentBlocks,
                                blockedTimes: blockedTimes,
                                busyEvents: busyEvents,
                                settings: settings,
                                now: now,
                                context: context
                            )
                        }
                    }
                } else {
                    _ = deferredBusyTimeConflictReplan.request(
                        canRewriteSchedule: false
                    )
                }
                try save(context)
            }
        } catch {
            context.rollback()
            deferredBusyTimeConflictReplan = originalDeferredState
            if let existingSettings {
                existingSettings.lastFutileAutomaticRebalanceFingerprint = originalMarker
                existingSettings.planningRebuildPending =
                    originalPlanningRebuildPending ?? false
            }
            for (template, deadline) in templateDeadlines {
                template.nextDeadline = deadline
            }
            for snapshot in taskSnapshots {
                snapshot.repair(in: context)
            }
            context.processPendingChanges()
            throw error
        }

        let result = ForegroundPlanRefreshResult(
            materializedTasks: materializedTasks,
            sweptOrphans: orphanBlocks.count + orphanSessions.count,
            catchUpSummary: catchUpSummary,
            replannedConflicts: replannedConflicts
        )
        publish(context, false)
        return result
    }

    /// Reconcile elapsed reservations at the one-shot block boundary. Reads,
    /// replacement rows, the futile-attempt marker, and the final save are one
    /// fail-closed unit; callers may present feedback only from this return.
    @discardableResult
    static func catchUpAtBlockBoundary(
        context: ModelContext,
        now: Date = Date(),
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> CatchUpSummary {
        try context.save()

        let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let settings = existingSettings ?? UserSettings()
        let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let snapshots = tasks.map(HeldTaskPlanSnapshot.init)
        let originalMarker = existingSettings?.lastFutileAutomaticRebalanceFingerprint
        var summary = CatchUpSummary()

        do {
            try context.transaction {
                if existingSettings == nil {
                    context.insert(settings)
                }
                summary = SchedulerService.catchUpMissedBlocks(
                    tasks: tasks,
                    allBlocks: allBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings,
                    now: now,
                    context: context
                )
                try save(context)
            }
        } catch {
            context.rollback()
            if let existingSettings {
                existingSettings.lastFutileAutomaticRebalanceFingerprint = originalMarker
            }
            for snapshot in snapshots {
                snapshot.repair(in: context)
            }
            context.processPendingChanges()
            throw error
        }

        if summary.adjustedTasks > 0 {
            publish(context, false)
        }
        return summary
    }

    /// Insert a recurring busy window and move conflicting work in the same
    /// durable transaction. A running timer retains schedule ownership: the
    /// window is saved, and the conflict request remains deferred for resume.
    @discardableResult
    static func addBlockedTime(
        _ blockedTime: BlockedTime,
        context: ModelContext,
        now: Date = Date(),
        activeWorkSession: WorkSessionControlState? = WorkSessionControlStore.load(),
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> Int {
        try context.save()

        let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let settings = existingSettings ?? UserSettings()
        let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let snapshots = tasks.map(HeldTaskPlanSnapshot.init)
        let originalMarker = existingSettings?.lastFutileAutomaticRebalanceFingerprint
        let originalDeferredState = deferredBusyTimeConflictReplan
        let canRewriteSchedule = AutomaticPlanRefreshPolicy.canRewriteSchedule(
            activeWorkSession: activeWorkSession
        )
        var replanned = 0

        do {
            try context.transaction {
                if existingSettings == nil {
                    context.insert(settings)
                }
                context.insert(blockedTime)
                if deferredBusyTimeConflictReplan.request(
                    canRewriteSchedule: canRewriteSchedule
                ) {
                    replanned = SchedulerService.replanConflicts(
                        tasks: tasks,
                        allBlocks: allBlocks,
                        blockedTimes: blockedTimes + [blockedTime],
                        busyEvents: busyEvents,
                        settings: settings,
                        now: now,
                        context: context
                    )
                }
                try save(context)
            }
        } catch {
            context.rollback()
            deferredBusyTimeConflictReplan = originalDeferredState
            if let existingSettings {
                existingSettings.lastFutileAutomaticRebalanceFingerprint = originalMarker
            }
            for snapshot in snapshots {
                snapshot.repair(in: context)
            }
            context.processPendingChanges()
            throw error
        }

        publish(context, interactive)
        return replanned
    }

    /// Remove a recurring busy window only when its deletion is durable. Freed
    /// time does not invalidate placement, but every mirror observes the saved
    /// row set rather than a pending delete.
    static func deleteBlockedTime(
        _ blockedTime: BlockedTime,
        context: ModelContext,
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws {
        try context.save()
        do {
            try context.transaction {
                context.delete(blockedTime)
                try save(context)
            }
        } catch {
            context.rollback()
            context.processPendingChanges()
            throw error
        }
        publish(context, interactive)
    }

    /// Move upcoming work that now overlaps recurring or imported busy time.
    @discardableResult
    static func replanBusyTimeConflicts(
        context: ModelContext,
        now: Date = Date(),
        activeWorkSession: WorkSessionControlState? = WorkSessionControlStore.load(),
        interactive: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> Int {
        let originalDeferredState = deferredBusyTimeConflictReplan
        let canRewriteSchedule = AutomaticPlanRefreshPolicy.canRewriteSchedule(
            activeWorkSession: activeWorkSession
        )
        guard deferredBusyTimeConflictReplan.request(
            canRewriteSchedule: canRewriteSchedule
        ) else {
            return 0
        }

        do {
            return try performBusyTimeConflictReplan(
                context: context,
                now: now,
                interactive: interactive,
                save: save,
                publish: publish
            )
        } catch {
            deferredBusyTimeConflictReplan = originalDeferredState
            throw error
        }
    }

    /// Finish only the conflict repair that was deferred by an active timer.
    /// WorkSessionView calls this after its attendance write is durable, so the
    /// repair can no longer delete the reservation that session fulfilled.
    @discardableResult
    static func resumeDeferredBusyTimeConflictReplan(
        context: ModelContext,
        now: Date = Date(),
        activeWorkSession: WorkSessionControlState? = WorkSessionControlStore.load(),
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() },
        publish: @MainActor (ModelContext, Bool) -> Void = { context, interactive in
            PlanCoordinator.publishChange(context: context, interactive: interactive)
        }
    ) throws -> Int {
        let originalDeferredState = deferredBusyTimeConflictReplan
        let canRewriteSchedule = AutomaticPlanRefreshPolicy.canRewriteSchedule(
            activeWorkSession: activeWorkSession
        )
        guard deferredBusyTimeConflictReplan.resume(
            canRewriteSchedule: canRewriteSchedule
        ) else {
            return 0
        }

        do {
            return try performBusyTimeConflictReplan(
                context: context,
                now: now,
                interactive: false,
                save: save,
                publish: publish
            )
        } catch {
            deferredBusyTimeConflictReplan = originalDeferredState
            throw error
        }
    }

    private static func performBusyTimeConflictReplan(
        context: ModelContext,
        now: Date,
        interactive: Bool,
        save: @MainActor (ModelContext) throws -> Void,
        publish: @MainActor (ModelContext, Bool) -> Void
    ) throws -> Int {
        try context.save()

        let existingSettings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let settings = existingSettings ?? UserSettings()
        let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
        let allBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let blockedTimes = try context.fetch(FetchDescriptor<BlockedTime>())
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let snapshots = tasks.map(HeldTaskPlanSnapshot.init)
        let originalMarker = existingSettings?.lastFutileAutomaticRebalanceFingerprint
        var replanned = 0

        do {
            try context.transaction {
                if existingSettings == nil {
                    context.insert(settings)
                }
                replanned = SchedulerService.replanConflicts(
                    tasks: tasks,
                    allBlocks: allBlocks,
                    blockedTimes: blockedTimes,
                    busyEvents: busyEvents,
                    settings: settings,
                    now: now,
                    context: context
                )
                try save(context)
            }
        } catch {
            context.rollback()
            if let existingSettings {
                existingSettings.lastFutileAutomaticRebalanceFingerprint = originalMarker
            }
            for snapshot in snapshots {
                snapshot.repair(in: context)
            }
            context.processPendingChanges()
            throw error
        }

        publish(context, interactive)
        return replanned
    }
}
