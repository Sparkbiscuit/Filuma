import XCTest
import SwiftData
@testable import Filuma

final class FilumaTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        let schema = Schema([
            FilumaTask.self, TaskTemplate.self, ScheduledBlock.self, WorkSession.self,
            BlockedTime.self, BusyEvent.self, Reminder.self, UserSettings.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - Helpers

    /// 9:00 AM tomorrow — a deterministic "now" safely inside the wake window.
    private var anchor: Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }

    private func makeSettings() -> UserSettings {
        let settings = UserSettings()
        settings.deadlineBufferMinutes = 120
        context.insert(settings)
        return settings
    }

    private func makeTask(effort: Int, deadlineHoursFromAnchor: Double) -> FilumaTask {
        let task = FilumaTask(
            title: "Test task",
            context: .school,
            deadline: anchor.addingTimeInterval(deadlineHoursFromAnchor * 3600),
            effortMinutes: effort
        )
        context.insert(task)
        return task
    }

    private func scheduledBlocks(from result: ScheduleResult) -> [ScheduledBlock] {
        switch result {
        case .success(let blocks): return blocks
        case .partialFit(let blocks, _): return blocks
        case .noSlots: return []
        }
    }

    private func assertFreshSchedulingDefaults(
        _ settings: UserSettings,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(settings.wakeHour, 8, file: file, line: line)
        XCTAssertEqual(settings.wakeMinute, 0, file: file, line: line)
        XCTAssertEqual(settings.sleepHour, 23, file: file, line: line)
        XCTAssertEqual(settings.sleepMinute, 0, file: file, line: line)
        XCTAssertEqual(settings.minBlockMinutes, 30, file: file, line: line)
        XCTAssertEqual(settings.maxBlockMinutes, 90, file: file, line: line)
        XCTAssertEqual(settings.deadlineBufferMinutes, 1440, file: file, line: line)
        XCTAssertEqual(settings.startBufferMinutes, 15, file: file, line: line)
        XCTAssertFalse(settings.planningRebuildPending, file: file, line: line)
    }

    // MARK: - User settings defaults

    func testFreeTierAllowsExactlyThreeActiveTasks() {
        XCTAssertTrue(SubscriptionPolicy.canAddTasks(
            activeTaskCount: 2,
            requestedCount: 1,
            isPro: false
        ))
        XCTAssertFalse(SubscriptionPolicy.canAddTasks(
            activeTaskCount: 3,
            requestedCount: 1,
            isPro: false
        ))
        XCTAssertFalse(SubscriptionPolicy.canAddTasks(
            activeTaskCount: 2,
            requestedCount: 2,
            isPro: false
        ))
        XCTAssertTrue(SubscriptionPolicy.canAddTasks(
            activeTaskCount: 500,
            requestedCount: 20,
            isPro: true
        ))
    }

    func testFreeTierRemainingCountNeverGoesNegative() {
        XCTAssertEqual(
            SubscriptionPolicy.remainingFreeTasks(activeTaskCount: 1, isPro: false),
            2
        )
        XCTAssertEqual(
            SubscriptionPolicy.remainingFreeTasks(activeTaskCount: 3, isPro: false),
            0
        )
        XCTAssertNil(
            SubscriptionPolicy.remainingFreeTasks(activeTaskCount: 9, isPro: true)
        )
    }

    func testFreshUserSettingsUsesCanonicalSchedulingDefaults() {
        let defaults = UserSettingsSchedulingDefaults.fresh

        XCTAssertEqual(defaults.wakeHour, 8)
        XCTAssertEqual(defaults.wakeMinute, 0)
        XCTAssertEqual(defaults.sleepHour, 23)
        XCTAssertEqual(defaults.sleepMinute, 0)
        XCTAssertEqual(defaults.minBlockMinutes, 30)
        XCTAssertEqual(defaults.maxBlockMinutes, 90)
        XCTAssertEqual(defaults.deadlineBufferMinutes, 1440)
        XCTAssertEqual(defaults.startBufferMinutes, 15)
        assertFreshSchedulingDefaults(UserSettings())
    }

    func testReapplyingFreshSchedulingDefaultsRestoresTheSamePolicyOnly() {
        let settings = UserSettings()
        settings.wakeHour = 5
        settings.wakeMinute = 45
        settings.sleepHour = 1
        settings.sleepMinute = 15
        settings.minBlockMinutes = 10
        settings.maxBlockMinutes = 240
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 90
        settings.hasCompletedOnboarding = true
        settings.blockRemindersEnabled = false

        settings.applyRecommendedSchedulingDefaults()

        assertFreshSchedulingDefaults(settings)
        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertFalse(settings.blockRemindersEnabled)
    }

    // MARK: - Settings side-effect durability

    @MainActor
    func testNudgePreferenceCommitsBeforeNotificationReconcile() throws {
        let settings = makeSettings()
        try context.save()
        var saveFinished = false
        var reconcileCount = 0

        try BlockNotificationService.updatePreference(
            .eveningReviewTime(hour: 19, minute: 45),
            settings: settings,
            context: context,
            save: { context in
                try context.save()
                saveFinished = true
            },
            reconcile: { _ in
                reconcileCount += 1
                XCTAssertTrue(saveFinished, "external reconciliation must follow the durable save")
                let fresh = ModelContext(self.container)
                let durable = try? fresh.fetch(FetchDescriptor<UserSettings>())
                XCTAssertEqual(durable?.first?.eveningReviewHour, 19)
                XCTAssertEqual(durable?.first?.eveningReviewMinute, 45)
            }
        )

        XCTAssertEqual(reconcileCount, 1)
    }

    @MainActor
    func testNudgePreferenceFailureRepairsHeldFieldsPreservesPreflightAndRetries() throws {
        let settings = makeSettings()
        settings.blockRemindersEnabled = true
        settings.blockReminderLeadMinutes = 10
        settings.morningPreviewEnabled = false
        settings.eveningReviewEnabled = true
        settings.eveningReviewHour = 20
        settings.eveningReviewMinute = 15
        let unrelated = makeTask(effort: 30, deadlineHoursFromAnchor: 24)
        try context.save()
        unrelated.title = "Accepted by preflight"
        var reconcileCount = 0

        XCTAssertThrowsError(
            try BlockNotificationService.updatePreference(
                .eveningReviewTime(hour: 6, minute: 45),
                settings: settings,
                context: context,
                save: { _ in throw CocoaError(.fileWriteUnknown) },
                reconcile: { _ in reconcileCount += 1 }
            )
        )

        XCTAssertTrue(settings.blockRemindersEnabled)
        XCTAssertEqual(settings.blockReminderLeadMinutes, 10)
        XCTAssertFalse(settings.morningPreviewEnabled)
        XCTAssertTrue(settings.eveningReviewEnabled)
        XCTAssertEqual(settings.eveningReviewHour, 20)
        XCTAssertEqual(settings.eveningReviewMinute, 15)
        XCTAssertEqual(reconcileCount, 0)

        var fresh = ModelContext(container)
        var durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        let durableTask = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<FilumaTask>()).first { $0.id == unrelated.id }
        )
        XCTAssertEqual(durableTask.title, "Accepted by preflight")
        XCTAssertEqual(durableSettings.eveningReviewHour, 20)
        XCTAssertEqual(durableSettings.eveningReviewMinute, 15)

        try BlockNotificationService.updatePreference(
            .eveningReviewTime(hour: 6, minute: 45),
            settings: settings,
            context: context,
            reconcile: { _ in reconcileCount += 1 }
        )

        XCTAssertEqual(reconcileCount, 1)
        fresh = ModelContext(container)
        durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertEqual(durableSettings.eveningReviewHour, 6)
        XCTAssertEqual(durableSettings.eveningReviewMinute, 45)
    }

    @MainActor
    func testAppleExportPreferenceCommitRollsBackFailureAndRetriesDurably() throws {
        let settings = makeSettings()
        try context.save()

        try CalendarExportService.setExportEnabled(
            true,
            settings: settings,
            context: context
        )
        XCTAssertTrue(settings.exportToAppleCalendar)
        var fresh = ModelContext(container)
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).exportToAppleCalendar)

        XCTAssertThrowsError(
            try CalendarExportService.setExportEnabled(
                false,
                settings: settings,
                context: context,
                save: { _ in throw CocoaError(.fileWriteUnknown) }
            )
        )
        XCTAssertTrue(settings.exportToAppleCalendar)
        fresh = ModelContext(container)
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).exportToAppleCalendar)

        try CalendarExportService.setExportEnabled(
            false,
            settings: settings,
            context: context
        )
        XCTAssertFalse(settings.exportToAppleCalendar)
        fresh = ModelContext(container)
        XCTAssertFalse(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).exportToAppleCalendar)
    }

    @MainActor
    func testCalendarIdentifierMirrorRepairsAllFieldsAndRetriesInSameContext() throws {
        let settings = makeSettings()
        settings.filumaCalendarIdentifier = "calendar-held"
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let first = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 30)
        let second = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(3600),
            durationMinutes: 30
        )
        first.appleCalendarEventId = "event-held-1"
        second.appleCalendarEventId = "event-held-2"
        context.insert(first)
        context.insert(second)
        try context.save()

        try CalendarExportService.persistExportIdentifiers(
            calendarIdentifier: "calendar-committed",
            blockIdentifiers: [
                (block: first, identifier: "event-committed-1"),
                (block: second, identifier: "event-committed-2")
            ],
            settings: settings,
            context: context
        )

        var fresh = ModelContext(container)
        var durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        var durableIDs = Dictionary(uniqueKeysWithValues:
            try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map {
                ($0.id, $0.appleCalendarEventId)
            }
        )
        XCTAssertEqual(durableSettings.filumaCalendarIdentifier, "calendar-committed")
        XCTAssertEqual(durableIDs[first.id]!, "event-committed-1")
        XCTAssertEqual(durableIDs[second.id]!, "event-committed-2")

        task.title = "Preflight survives identifier rollback"
        XCTAssertThrowsError(
            try CalendarExportService.persistExportIdentifiers(
                calendarIdentifier: "calendar-rejected",
                blockIdentifiers: [
                    (block: first, identifier: "event-rejected-1"),
                    (block: second, identifier: nil)
                ],
                settings: settings,
                context: context,
                save: { _ in throw CocoaError(.fileWriteUnknown) }
            )
        )

        XCTAssertEqual(settings.filumaCalendarIdentifier, "calendar-committed")
        XCTAssertEqual(first.appleCalendarEventId, "event-committed-1")
        XCTAssertEqual(second.appleCalendarEventId, "event-committed-2")
        fresh = ModelContext(container)
        durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        durableIDs = Dictionary(uniqueKeysWithValues:
            try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map {
                ($0.id, $0.appleCalendarEventId)
            }
        )
        XCTAssertEqual(durableSettings.filumaCalendarIdentifier, "calendar-committed")
        XCTAssertEqual(durableIDs[first.id]!, "event-committed-1")
        XCTAssertEqual(durableIDs[second.id]!, "event-committed-2")
        XCTAssertEqual(
            try XCTUnwrap(fresh.fetch(FetchDescriptor<FilumaTask>()).first).title,
            "Preflight survives identifier rollback"
        )

        try CalendarExportService.persistExportIdentifiers(
            calendarIdentifier: "calendar-retried",
            blockIdentifiers: [
                (block: first, identifier: "event-retried-1"),
                (block: second, identifier: nil)
            ],
            settings: settings,
            context: context
        )
        fresh = ModelContext(container)
        durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        durableIDs = Dictionary(uniqueKeysWithValues:
            try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map {
                ($0.id, $0.appleCalendarEventId)
            }
        )
        XCTAssertEqual(durableSettings.filumaCalendarIdentifier, "calendar-retried")
        XCTAssertEqual(durableIDs[first.id]!, "event-retried-1")
        XCTAssertNil(durableIDs[second.id]!)
    }

    func testAppleExportReconcileRejectsStaleRequestOrDurableToggle() {
        let captured = UUID()

        XCTAssertTrue(CalendarExportService.isReconciliationCurrent(
            expectedEnabled: true,
            durableEnabled: true,
            requestID: captured,
            currentRequestID: captured
        ))
        XCTAssertFalse(CalendarExportService.isReconciliationCurrent(
            expectedEnabled: true,
            durableEnabled: false,
            requestID: captured,
            currentRequestID: captured
        ), "a captured enable retry must stop after the durable toggle flips off")
        XCTAssertFalse(CalendarExportService.isReconciliationCurrent(
            expectedEnabled: true,
            durableEnabled: true,
            requestID: captured,
            currentRequestID: UUID()
        ), "an older request must not reconcile after a newer Settings action")
    }

    @MainActor
    func testOnboardingBootstrapFailureCanRetryWithoutDuplicateSettings() throws {
        var rejectedSaveCount = 0

        XCTAssertThrowsError(
            try OnboardingBootstrapCoordinator.ensureSettings(
                in: context,
                save: { _ in
                    rejectedSaveCount += 1
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        )
        XCTAssertEqual(rejectedSaveCount, 1)

        context.rollback()
        context.processPendingChanges()

        let settings = try OnboardingBootstrapCoordinator.ensureSettings(
            in: context
        )
        let stored = try context.fetch(FetchDescriptor<UserSettings>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, settings.id)
        assertFreshSchedulingDefaults(settings)
    }

    @MainActor
    func testOnboardingBootstrapReadFailureCannotCreateDuplicateSettings() throws {
        let original = makeSettings()
        try context.save()
        var saveCount = 0

        XCTAssertThrowsError(
            try OnboardingBootstrapCoordinator.ensureSettings(
                in: context,
                fetch: { _ in throw CocoaError(.fileReadUnknown) },
                save: { context in
                    saveCount += 1
                    try context.save()
                }
            )
        )

        XCTAssertEqual(saveCount, 0)
        let durable = ModelContext(container)
        let stored = try durable.fetch(FetchDescriptor<UserSettings>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, original.id)

        let retried = try OnboardingBootstrapCoordinator.ensureSettings(in: context)
        XCTAssertEqual(retried.id, original.id)
    }

    @MainActor
    func testExistingTaskReadFailureCannotChooseFirstRunPath() throws {
        _ = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        try context.save()

        XCTAssertThrowsError(
            try OnboardingBootstrapCoordinator.hasExistingTasks(
                in: context,
                fetchCount: { _ in throw CocoaError(.fileReadUnknown) }
            )
        )
        XCTAssertTrue(
            try OnboardingBootstrapCoordinator.hasExistingTasks(in: context)
        )
    }

    @MainActor
    func testOnboardingCompletionFirstSaveFailureKeepsDraftForRetry() throws {
        let settings = makeSettings()
        try context.save()
        settings.wakeHour = 6
        settings.wakeMinute = 45
        settings.minBlockMinutes = 45
        settings.maxBlockMinutes = 120
        settings.deadlineBufferMinutes = 180

        XCTAssertThrowsError(
            try OnboardingCompletionCoordinator.commit(
                settings,
                in: context,
                save: { _ in throw CocoaError(.fileWriteUnknown) }
            )
        )

        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertEqual(settings.wakeHour, 6)
        XCTAssertEqual(settings.wakeMinute, 45)
        XCTAssertEqual(settings.minBlockMinutes, 45)
        XCTAssertEqual(settings.maxBlockMinutes, 120)
        XCTAssertEqual(settings.deadlineBufferMinutes, 180)

        let beforeRetry = ModelContext(container)
        let durableBeforeRetry = try XCTUnwrap(
            beforeRetry.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertFalse(durableBeforeRetry.hasCompletedOnboarding)
        XCTAssertEqual(durableBeforeRetry.wakeHour, 8)

        try OnboardingCompletionCoordinator.commit(settings, in: context)

        let afterRetry = ModelContext(container)
        let durableAfterRetry = try XCTUnwrap(
            afterRetry.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertTrue(durableAfterRetry.hasCompletedOnboarding)
        XCTAssertEqual(durableAfterRetry.wakeHour, 6)
        XCTAssertEqual(durableAfterRetry.wakeMinute, 45)
        XCTAssertEqual(durableAfterRetry.minBlockMinutes, 45)
        XCTAssertEqual(durableAfterRetry.maxBlockMinutes, 120)
        XCTAssertEqual(durableAfterRetry.deadlineBufferMinutes, 180)
    }

    @MainActor
    func testOnboardingCompletionFinalSaveFailureKeepsRhythmButNotHandoff() throws {
        let settings = makeSettings()
        try context.save()
        settings.sleepHour = 1
        settings.sleepMinute = 15
        settings.minBlockMinutes = 60
        settings.maxBlockMinutes = 150
        settings.deadlineBufferMinutes = 240
        var saveCount = 0

        XCTAssertThrowsError(
            try OnboardingCompletionCoordinator.commit(
                settings,
                in: context,
                save: { context in
                    saveCount += 1
                    if saveCount == 2 {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try context.save()
                }
            )
        )

        XCTAssertEqual(saveCount, 2)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        let durable = ModelContext(container)
        let stored = try XCTUnwrap(
            durable.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertFalse(stored.hasCompletedOnboarding)
        XCTAssertEqual(stored.sleepHour, 1)
        XCTAssertEqual(stored.sleepMinute, 15)
        XCTAssertEqual(stored.minBlockMinutes, 60)
        XCTAssertEqual(stored.maxBlockMinutes, 150)
        XCTAssertEqual(stored.deadlineBufferMinutes, 240)
    }

    // MARK: - splitEffort

    func testSplitEffortRespectsBounds() {
        let cases: [(total: Int, minBlock: Int, maxBlock: Int)] = [
            (60, 30, 90), (200, 30, 90), (100, 30, 90), (95, 30, 90),
            (720, 15, 180), (45, 45, 60), (300, 30, 90)
        ]
        for c in cases {
            let chunks = SchedulerService.splitEffort(
                minutes: c.total, minBlock: c.minBlock, maxBlock: c.maxBlock
            )
            XCTAssertEqual(chunks.reduce(0, +), c.total, "chunks must sum to total for \(c)")
            for chunk in chunks {
                XCTAssertLessThanOrEqual(chunk, c.maxBlock, "chunk over max for \(c)")
                XCTAssertGreaterThanOrEqual(chunk, c.minBlock, "chunk under min for \(c)")
            }
        }
    }

    func testSplitEffortAvoidsSubMinimumTail() {
        // 100m with 30–90 must not produce [90, 10].
        let chunks = SchedulerService.splitEffort(minutes: 100, minBlock: 30, maxBlock: 90)
        XCTAssertEqual(chunks.reduce(0, +), 100)
        XCTAssertTrue(chunks.allSatisfy { $0 >= 30 }, "got \(chunks)")
    }

    func testSplitEffortSmallerThanMinimumIsSingleChunk() {
        XCTAssertEqual(SchedulerService.splitEffort(minutes: 20, minBlock: 30, maxBlock: 90), [20])
    }

    func testDistributedSchedulingUsesSeparatedDaysAndPreferredFinish() {
        let settings = makeSettings()
        settings.maxBlockMinutes = 60
        settings.deadlineBufferMinutes = 1440
        let task = makeTask(effort: 240, deadlineHoursFromAnchor: 9 * 24)
        let blocks = scheduledBlocks(from: SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )).sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(blocks.map(\.durationMinutes), [60, 60, 60, 60])
        let days = blocks.map { calendar.startOfDay(for: $0.startTime) }
        XCTAssertEqual(Set(days).count, 4)
        for pair in zip(days, days.dropFirst()) {
            XCTAssertGreaterThanOrEqual(calendar.dateComponents([.day], from: pair.0, to: pair.1).day!, 2)
        }
        XCTAssertLessThanOrEqual(blocks.last!.endTime, task.deadline.addingTimeInterval(-86400))
    }

    func testSafeZoneFallsBackThroughActualDeadlineBeforeReportingShortfall() {
        let settings = makeSettings()
        settings.deadlineBufferMinutes = 120
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 3)
        let result = SchedulerService.schedule(task: task, allBlocks: [], settings: settings, from: anchor)
        guard case .success(let blocks) = result else { return XCTFail("Work fits through the actual deadline") }
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertTrue(blocks.contains { $0.endTime > task.deadline.addingTimeInterval(-7200) })
        XCTAssertTrue(blocks.allSatisfy { $0.endTime <= task.deadline })
    }

    func testElapsedSafeZoneAndPerTaskNoneRemainSchedulable() {
        let settings = makeSettings()
        settings.deadlineBufferMinutes = 3 * 1440
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 2)
        var result = SchedulerService.schedule(task: task, allBlocks: [], settings: settings, from: anchor)
        XCTAssertEqual(scheduledBlocks(from: result).reduce(0) { $0 + $1.durationMinutes }, 60)
        // Detach uncommitted preview blocks before trying the override.
        for block in scheduledBlocks(from: result) { block.task = nil }
        task.safeZoneMinutes = 0
        result = SchedulerService.schedule(task: task, allBlocks: [], settings: settings, from: anchor)
        XCTAssertEqual(scheduledBlocks(from: result).reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertNotEqual(SchedulerService.pressure(for: task, allBlocks: [], settings: settings, now: anchor), .infinity)
    }

    func testDistributionDoesNotConsumeAnotherTasksOnlyLongGap() throws {
        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 0
        settings.minBlockMinutes = 60
        settings.maxBlockMinutes = 90
        settings.wakeHour = 9
        settings.sleepHour = 12
        let short = makeTask(effort: 60, deadlineHoursFromAnchor: 26)
        let long = makeTask(effort: 90, deadlineHoursFromAnchor: 27)
        let busy = BusyEvent(source: .appleCalendar, sourceId: "scarce-gap", title: "Busy",
            startTime: anchor.addingTimeInterval(3600), endTime: anchor.addingTimeInterval(24 * 3600))
        context.insert(busy)
        let summary = SchedulerService.rebalance(tasks: [short, long], allBlocks: [], blockedTimes: [],
            busyEvents: [busy], settings: settings, now: anchor, context: context)
        XCTAssertEqual(summary.unschedulableTasks, 0)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertEqual(all.filter { $0.task?.id == short.id }.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertEqual(all.filter { $0.task?.id == long.id }.reduce(0) { $0 + $1.durationMinutes }, 90)
        let chronological = all.sorted { $0.startTime < $1.startTime }
        for pair in zip(chronological, chronological.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.endTime, pair.1.startTime)
        }
    }

    func testUnchangedRefreshPreservesDistributedBlockIdentitiesAndDates() throws {
        let settings = makeSettings()
        settings.maxBlockMinutes = 60
        settings.deadlineBufferMinutes = 1440
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 240, deadlineHoursFromAnchor: 9 * 24)
        SchedulerService.rebalance(tasks: [task], allBlocks: [], blockedTimes: [], settings: settings,
            now: anchor, context: context)
        let before = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let dates = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.startTime) })
        let summary = SchedulerService.catchUpMissedBlocks(tasks: [task], allBlocks: before, blockedTimes: [],
            settings: settings, now: anchor.addingTimeInterval(300), context: context)
        XCTAssertEqual(summary.adjustedTasks, 0)
        let after = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.startTime) }), dates)
    }

    // MARK: - schedule()

    func testScheduleSuccessRespectsWindowAndBuffer() {
        let settings = makeSettings() // wake 8, sleep 23, buffer 120
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)

        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 120)

        let windowEnd = task.deadline.addingTimeInterval(-Double(settings.deadlineBufferMinutes) * 60)
        for block in blocks {
            XCTAssertGreaterThanOrEqual(block.startTime, anchor)
            XCTAssertLessThanOrEqual(block.endTime, windowEnd, "block must respect deadline buffer")
            let hour = calendar.component(.hour, from: block.startTime)
            XCTAssertGreaterThanOrEqual(hour, settings.wakeHour)
        }
    }

    func testScheduleAvoidsExistingBlocks() {
        let settings = makeSettings()
        let existingTask = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let occupying = ScheduledBlock(task: existingTask, startTime: anchor, durationMinutes: 120)
        context.insert(occupying)

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [occupying], settings: settings, from: anchor
        )

        let blocks = scheduledBlocks(from: result)
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            let overlaps = block.startTime < occupying.endTime && block.endTime > occupying.startTime
            XCTAssertFalse(overlaps, "new block overlaps an existing one")
        }
    }

    func testOvernightSleepTimeStillSchedules() {
        // Sleep at 00:30 used to produce an empty window every day (sleep < wake).
        let settings = makeSettings()
        settings.sleepHour = 0
        settings.sleepMinute = 30

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 36)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )

        guard case .success = result else {
            return XCTFail("overnight sleep time should still yield slots, got \(result)")
        }
    }

    func testScheduleAvoidsBlockedTimes() {
        let settings = makeSettings()
        // Blocked every day 9:00–17:00; wake 8, sleep 23.
        let blocked = BlockedTime(
            label: "Class", weekdays: Array(1...7),
            startHour: 9, startMinute: 0, durationMinutes: 8 * 60
        )
        context.insert(blocked)

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], blockedTimes: [blocked], settings: settings, from: anchor
        )

        let blocks = scheduledBlocks(from: result)
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            for occurrence in blocked.occurrences(from: anchor, to: task.deadline) {
                let overlaps = block.startTime < occurrence.end && block.endTime > occurrence.start
                XCTAssertFalse(overlaps, "block booked over a blocked time")
            }
        }
    }

    func testPastDeadlineReturnsNoSlots() {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: -1)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )
        guard case .noSlots = result else {
            return XCTFail("expected noSlots, got \(result)")
        }
    }

    func testTightWindowReturnsPartialFit() {
        let settings = makeSettings() // buffer 120
        // The actual deadline leaves 90 minutes, including the Safe Zone.
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 1.5)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )
        guard case .partialFit(let blocks, let unscheduled) = result else {
            return XCTFail("expected partialFit, got \(result)")
        }
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 90)
        XCTAssertEqual(unscheduled, 30)
    }

    func testScheduleAdaptsChunksToSeparateHourGaps() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 13

        let occupyingTask = makeTask(effort: 120, deadlineHoursFromAnchor: 24)
        let firstHold = ScheduledBlock(
            task: occupyingTask,
            startTime: anchor.addingTimeInterval(60 * 60),
            durationMinutes: 60
        )
        let secondHold = ScheduledBlock(
            task: occupyingTask,
            startTime: anchor.addingTimeInterval(3 * 60 * 60),
            durationMinutes: 60
        )
        context.insert(firstHold)
        context.insert(secondHold)

        // Buffered window ends at 13:00, leaving only 9–10 and 11–12.
        // A fixed [90, 30] split cannot use either first gap; slot-aware
        // placement should adapt it to [60, 60].
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 6)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [firstHold, secondHold],
            settings: settings,
            from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected both hour gaps to fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [60, 60])
        XCTAssertEqual(
            blocks.map(\.startTime),
            [anchor, anchor.addingTimeInterval(2 * 60 * 60)]
        )
    }

    func testScheduleLooksAheadAcrossThreeSeparateFortyFiveMinuteGaps() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 13
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 90
        settings.dailyFocusMinutes = 0

        let occupyingTask = makeTask(effort: 105, deadlineHoursFromAnchor: 24)
        let holds = [
            ScheduledBlock(
                task: occupyingTask,
                startTime: anchor.addingTimeInterval(45 * 60),
                durationMinutes: 15
            ),
            ScheduledBlock(
                task: occupyingTask,
                startTime: anchor.addingTimeInterval(105 * 60),
                durationMinutes: 15
            ),
            ScheduledBlock(
                task: occupyingTask,
                startTime: anchor.addingTimeInterval(165 * 60),
                durationMinutes: 75
            )
        ]
        for hold in holds { context.insert(hold) }

        // The usable window is exactly three independent 45-minute gaps.
        // Treating a 55-minute tail as one theoretical block would strand it;
        // looking at the actual future gaps yields 40 + 30 + 30 instead.
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 6)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: holds,
            settings: settings,
            from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected all three gaps to fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [40, 30, 30])
        for (block, minute) in zip(blocks, [0, 60, 120]) {
            XCTAssertGreaterThanOrEqual(block.startTime, anchor.addingTimeInterval(Double(minute * 60)))
            XCTAssertLessThanOrEqual(block.endTime, anchor.addingTimeInterval(Double((minute + 45) * 60)))
        }
    }

    func testScheduleAllowsShortRemainderInShortSlot() {
        let settings = makeSettings() // configured minimum is 30 minutes
        settings.wakeHour = 9
        settings.sleepHour = 10

        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "short-remainder",
            title: "Appointment",
            startTime: anchor.addingTimeInterval(20 * 60),
            endTime: anchor.addingTimeInterval(60 * 60)
        )
        context.insert(busy)

        let task = makeTask(effort: 20, deadlineHoursFromAnchor: 3)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [],
            busyEvents: [busy],
            settings: settings,
            from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected the 20-minute remainder to fit, got \(result)")
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.startTime, anchor)
        XCTAssertEqual(blocks.first?.durationMinutes, 20)
    }

    func testDailyFocusCapSpreadsWorkAcrossDays() {
        let settings = makeSettings()
        settings.dailyFocusMinutes = 60

        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 96)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: anchor
        )

        let blocks = scheduledBlocks(from: result)
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 120)

        var perDay: [Date: Int] = [:]
        for block in blocks {
            perDay[calendar.startOfDay(for: block.startTime), default: 0] += block.durationMinutes
        }
        for (_, minutes) in perDay {
            XCTAssertLessThanOrEqual(minutes, 60, "daily focus cap exceeded")
        }
        XCTAssertGreaterThanOrEqual(perDay.count, 2, "cap should force a second day")
    }

    func testDailyFocusCapPreservesRepresentableTailAcrossThreeDays() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 9
        settings.sleepMinute = 45
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 90
        settings.dailyFocusMinutes = 45

        // Three 45-minute days can hold 100 minutes, but taking 45 first would
        // strand 55 minutes, which cannot be expressed in 30...45 blocks.
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 74)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [],
            settings: settings,
            from: anchor
        )

        guard case .success(let blocks) = result else {
            return XCTFail("expected all three days to fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [40, 30, 30])
        XCTAssertEqual(Set(blocks.map { calendar.startOfDay(for: $0.startTime) }).count, 3)
    }

    func testDailyFocusCapSplitsOvernightBlocksAcrossCalendarDays() {
        let settings = makeSettings()
        settings.wakeHour = 22
        settings.sleepHour = 2
        settings.dailyFocusMinutes = 100
        settings.minBlockMinutes = 90
        settings.maxBlockMinutes = 90

        let day = calendar.startOfDay(for: anchor)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let start = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: day)!
        let existingStart = calendar.date(
            bySettingHour: 22, minute: 0, second: 0, of: nextDay
        )!
        let existingTask = makeTask(effort: 90, deadlineHoursFromAnchor: 120)
        let existing = ScheduledBlock(
            task: existingTask,
            startTime: existingStart,
            durationMinutes: 90
        )
        context.insert(existing)

        // Leave 23:00–02:00 open on the first overnight window. Charging a
        // 23:00–00:30 candidate only to its start day would put 120 minutes on
        // the following calendar day once the existing block is included.
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "overnight-cap",
            title: "Evening commitment",
            startTime: calendar.date(
                bySettingHour: 22, minute: 0, second: 0, of: day
            )!,
            endTime: calendar.date(
                bySettingHour: 23, minute: 0, second: 0, of: day
            )!
        )
        context.insert(busy)

        let task = makeTask(effort: 90, deadlineHoursFromAnchor: 120)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [existing],
            busyEvents: [busy],
            settings: settings,
            from: start
        )
        let blocks = scheduledBlocks(from: result)
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 90)

        var perDay: [Date: Double] = [:]
        for block in [existing] + blocks {
            var cursor = block.startTime
            while cursor < block.endTime {
                let calendarDay = calendar.startOfDay(for: cursor)
                let followingDay = calendar.date(
                    byAdding: .day, value: 1, to: calendarDay
                )!
                let portionEnd = min(block.endTime, followingDay)
                perDay[calendarDay, default: 0] += portionEnd.timeIntervalSince(cursor) / 60
                cursor = portionEnd
            }
        }
        for (_, minutes) in perDay {
            XCTAssertLessThanOrEqual(minutes, 100, "daily focus cap exceeded")
        }
    }

    // MARK: - Catch-up

    func testCatchUpReplansMissedBlocks() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)

        // A block that came and went, unfinished, before the anchor.
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-3 * 3600),
            durationMinutes: 60
        )
        context.insert(missed)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [missed],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.adjustedTasks, 1)
        XCTAssertEqual(summary.replannedTasks, 1)
        XCTAssertEqual(summary.unschedulableTasks, 0)
        let remaining = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(remaining.isEmpty, "replacement blocks should exist")
        for block in remaining {
            XCTAssertGreaterThanOrEqual(block.startTime, anchor, "missed block should be replanned into the future")
        }
    }

    func testCatchUpTopsUpUnderScheduledTasks() throws {
        let settings = makeSettings()
        // 120m task with only 60m of future coverage: nothing was missed, but
        // the plan is short, so catch-up rebalances and books the difference.
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)

        let done = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(-5 * 3600), durationMinutes: 60)
        done.isComplete = true
        let future = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        context.insert(done)
        context.insert(future)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [done, future],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.adjustedTasks, 1, "the topped-up plan should be surfaced")
        XCTAssertEqual(summary.replannedTasks, 0, "no blocks were missed")
        XCTAssertEqual(summary.unschedulableTasks, 0)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let futureMinutes = all.filter { !$0.isComplete }.reduce(0) { $0 + $1.durationMinutes }
        XCTAssertEqual(futureMinutes, 120, "coverage should be topped up to the full remaining effort")
        XCTAssertTrue(all.contains { $0.isComplete }, "completed blocks stay untouched")
    }

    func testCatchUpDoesNothingWhenPlanIsHealthy() throws {
        let settings = makeSettings()
        // 60m task fully covered by one future block: catch-up must not touch it.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let future = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        let futureId = future.id
        context.insert(future)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [future],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary, CatchUpSummary())
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertEqual(all.map(\.id), [futureId], "a healthy plan must not be rearranged")
    }

    func testCatchUpSuppressesRepeatedFutileRebalanceWithoutChurningBlocks() throws {
        let settings = makeSettings()
        let impossible = makeTask(effort: 60, deadlineHoursFromAnchor: 1)
        let unaffected = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(
            task: unaffected,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        context.insert(original)
        try context.save()

        let first = SchedulerService.catchUpMissedBlocks(
            tasks: [impossible, unaffected],
            allBlocks: [original],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(first.adjustedTasks, 1)
        XCTAssertEqual(first.replannedTasks, 0)
        XCTAssertEqual(first.unschedulableTasks, 1)
        XCTAssertNotNil(settings.lastFutileAutomaticRebalanceFingerprint)

        let afterFirst = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let unaffectedIds = Set(afterFirst
            .filter { $0.task?.id == unaffected.id }
            .map(\.id))
        XCTAssertFalse(unaffectedIds.isEmpty)

        let second = SchedulerService.catchUpMissedBlocks(
            tasks: [unaffected, impossible],
            allBlocks: Array(afterFirst.reversed()),
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(second, CatchUpSummary())
        let afterSecond = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertEqual(
            Set(afterSecond.filter { $0.task?.id == unaffected.id }.map(\.id)),
            unaffectedIds,
            "an identical futile pass must preserve unaffected block IDs"
        )
    }

    func testFutileRebalanceRetriesAfterAnySchedulingInputChanges() throws {
        let settings = makeSettings()
        let impossible = makeTask(effort: 60, deadlineHoursFromAnchor: 1)
        let unaffected = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(
            task: unaffected,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "fingerprint-busy",
            title: "Busy",
            startTime: anchor.addingTimeInterval(30 * 3600),
            endTime: anchor.addingTimeInterval(31 * 3600)
        )
        let blocked = BlockedTime(
            label: "Blocked",
            weekdays: Array(1...7),
            startHour: 18,
            startMinute: 0,
            durationMinutes: 30
        )
        context.insert(original)
        context.insert(busy)
        context.insert(blocked)
        try context.save()

        func runCatchUpAfterMutation(_ input: String) throws {
            let previousFingerprint = settings.lastFutileAutomaticRebalanceFingerprint
            let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
            let summary = SchedulerService.catchUpMissedBlocks(
                tasks: [impossible, unaffected],
                allBlocks: blocks,
                blockedTimes: [blocked],
                busyEvents: [busy],
                settings: settings,
                now: anchor,
                context: context
            )
            try context.save()
            XCTAssertGreaterThan(summary.adjustedTasks, 0, "\(input) must permit another attempt")
            XCTAssertEqual(summary.unschedulableTasks, 1)
            XCTAssertNotEqual(
                settings.lastFutileAutomaticRebalanceFingerprint,
                previousFingerprint,
                "\(input) must produce a new persisted plan fingerprint"
            )
        }

        try runCatchUpAfterMutation("initial plan")

        let block = try XCTUnwrap(
            context.fetch(FetchDescriptor<ScheduledBlock>())
                .first { $0.task?.id == unaffected.id }
        )
        block.isLocked.toggle()
        try runCatchUpAfterMutation("block mutation")

        busy.startTime = busy.startTime.addingTimeInterval(15 * 60)
        busy.endTime = busy.endTime.addingTimeInterval(15 * 60)
        try runCatchUpAfterMutation("busy-event mutation")

        blocked.durationMinutes += 15
        try runCatchUpAfterMutation("blocked-time mutation")

        impossible.effortMinutes += 15
        try runCatchUpAfterMutation("task effort mutation")

        settings.dailyFocusMinutes = 60
        try runCatchUpAfterMutation("focus-limit mutation")
    }

    func testMissedBlockBypassesMatchingFutileFingerprint() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 1)
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-2 * 3600),
            durationMinutes: 60
        )
        context.insert(missed)
        settings.lastFutileAutomaticRebalanceFingerprint =
            SchedulerService.automaticSchedulingFingerprint(
                tasks: [task],
                allBlocks: [missed],
                blockedTimes: [],
                busyEvents: [],
                settings: settings
            )
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [missed],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.replannedTasks, 1)
        XCTAssertEqual(summary.unschedulableTasks, 1)
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<ScheduledBlock>())
                .contains { $0.id == missed.id }
        )
    }

    func testFutileRebalanceFingerprintPersistsAcrossModelContexts() throws {
        let settings = makeSettings()
        settings.lastFutileAutomaticRebalanceFingerprint = "persisted-fingerprint"
        try context.save()

        let freshContext = ModelContext(container)
        let fetched = try XCTUnwrap(
            freshContext.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertEqual(
            fetched.lastFutileAutomaticRebalanceFingerprint,
            "persisted-fingerprint"
        )
    }

    func testAutomaticSchedulingFingerprintIsStableAcrossInputShuffling() {
        let settings = makeSettings()
        let firstTask = makeTask(effort: 30, deadlineHoursFromAnchor: 24)
        let secondTask = makeTask(effort: 45, deadlineHoursFromAnchor: 48)
        let firstBlock = ScheduledBlock(
            task: firstTask,
            startTime: anchor.addingTimeInterval(3600),
            durationMinutes: 30
        )
        let secondBlock = ScheduledBlock(
            task: secondTask,
            startTime: anchor.addingTimeInterval(3 * 3600),
            durationMinutes: 45
        )
        let firstBusy = BusyEvent(
            source: .appleCalendar,
            sourceId: "first",
            title: "First",
            startTime: anchor.addingTimeInterval(5 * 3600),
            endTime: anchor.addingTimeInterval(6 * 3600)
        )
        let secondBusy = BusyEvent(
            source: .googleCalendar,
            sourceId: "second",
            title: "Second",
            startTime: anchor.addingTimeInterval(7 * 3600),
            endTime: anchor.addingTimeInterval(8 * 3600)
        )
        let firstBlocked = BlockedTime(
            label: "First", weekdays: [2, 4],
            startHour: 10, startMinute: 15, durationMinutes: 30
        )
        let secondBlocked = BlockedTime(
            label: "Second", weekdays: [6, 3],
            startHour: 14, startMinute: 45, durationMinutes: 60
        )

        let original = SchedulerService.automaticSchedulingFingerprint(
            tasks: [firstTask, secondTask],
            allBlocks: [firstBlock, secondBlock],
            blockedTimes: [firstBlocked, secondBlocked],
            busyEvents: [firstBusy, secondBusy],
            settings: settings
        )
        let shuffled = SchedulerService.automaticSchedulingFingerprint(
            tasks: [secondTask, firstTask],
            allBlocks: [secondBlock, firstBlock],
            blockedTimes: [secondBlocked, firstBlocked],
            busyEvents: [secondBusy, firstBusy],
            settings: settings
        )

        XCTAssertEqual(original, shuffled)
    }

    func testZeroDurationOccupiedIntervalDoesNotSplitUsableGap() {
        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.minBlockMinutes = 30
        let occupyingTask = makeTask(effort: 30, deadlineHoursFromAnchor: 24)
        let zeroDuration = ScheduledBlock(
            task: occupyingTask,
            startTime: anchor.addingTimeInterval(20 * 60),
            durationMinutes: 0
        )
        let task = makeTask(effort: 30, deadlineHoursFromAnchor: 40.0 / 60.0)

        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [zeroDuration],
            settings: settings,
            from: anchor
        )

        XCTAssertEqual(
            scheduledBlocks(from: result).reduce(0) { $0 + $1.durationMinutes },
            30,
            "a zero-length record must leave the full 40-minute gap usable"
        )
    }

    func testCatchUpReleasesAndReplansMissedLockedBlock() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-3 * 3600),
            durationMinutes: 60
        )
        missed.isLocked = true
        let missedId = missed.id
        context.insert(missed)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [missed],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.adjustedTasks, 1)
        XCTAssertEqual(summary.replannedTasks, 1)
        let remaining = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(remaining.contains { $0.id == missedId }, "elapsed time cannot stay reserved by a lock")
        XCTAssertEqual(remaining.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(remaining.allSatisfy { $0.startTime >= anchor })
    }

    func testNextCatchUpRefreshDateChoosesEarliestRelevantBlock() {
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-2 * 3600),
            durationMinutes: 60
        )
        let future = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        let completed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-4 * 3600),
            durationMinutes: 60
        )
        completed.isComplete = true

        let overdueTask = FilumaTask(
            title: "Overdue",
            context: .school,
            deadline: anchor.addingTimeInterval(-3600),
            effortMinutes: 60
        )
        context.insert(overdueTask)
        let overdueBlock = ScheduledBlock(
            task: overdueTask,
            startTime: anchor.addingTimeInterval(-3 * 3600),
            durationMinutes: 60
        )

        let blocks = [future, completed, overdueBlock, missed]
        XCTAssertEqual(
            SchedulerService.nextCatchUpRefreshDate(blocks: blocks, now: anchor),
            missed.endTime,
            "an elapsed active block should trigger immediate catch-up instead of being skipped"
        )

        missed.isComplete = true
        XCTAssertEqual(
            SchedulerService.nextCatchUpRefreshDate(blocks: blocks, now: anchor),
            future.endTime,
            "completion should re-arm the one-shot refresh for the next block"
        )

        task.isComplete = true
        XCTAssertNil(SchedulerService.nextCatchUpRefreshDate(blocks: blocks, now: anchor))
    }

    func testCatchUpFeedbackKeepsVisualAndSpokenCopyInSync() {
        let refreshed = CatchUpSummary(adjustedTasks: 1, replannedTasks: 1)
        XCTAssertEqual(
            refreshed.accessibilityAnnouncement,
            "Plan refreshed after missed work. Your next steps are up to date."
        )

        let warning = CatchUpSummary(
            adjustedTasks: 2,
            replannedTasks: 1,
            unschedulableTasks: 2
        )
        XCTAssertEqual(
            warning.warningMessage,
            "2 tasks no longer fit before their deadlines. Extend them or trim the estimates."
        )
        XCTAssertEqual(
            warning.accessibilityAnnouncement,
            warning.feedbackMessage + " " + (warning.warningMessage ?? "")
        )
    }

    func testAutomaticPlanRefreshWaitsForActiveWorkSession() {
        XCTAssertTrue(
            AutomaticPlanRefreshPolicy.canRewriteSchedule(
                activeWorkSession: nil
            )
        )

        let activeSession = WorkSessionControlState(
            sessionID: UUID(),
            startedAt: anchor
        )
        XCTAssertFalse(
            AutomaticPlanRefreshPolicy.canRewriteSchedule(
                activeWorkSession: activeSession
            ),
            "catch-up and busy-time conflict repair must both defer while a timer owns its block"
        )
    }

    func testDeferredBusyTimeConflictReplanStateResumesExactlyOnce() {
        var state = DeferredBusyTimeConflictReplanState()

        XCTAssertFalse(state.request(canRewriteSchedule: false))
        XCTAssertTrue(state.hasPendingRequest)
        XCTAssertFalse(
            state.resume(canRewriteSchedule: false),
            "a second active session must preserve the deferred repair"
        )
        XCTAssertTrue(state.hasPendingRequest)
        XCTAssertTrue(state.resume(canRewriteSchedule: true))
        XCTAssertFalse(state.hasPendingRequest)
        XCTAssertFalse(
            state.resume(canRewriteSchedule: true),
            "the same deferred repair must not run twice"
        )
    }

    func testImmediateBusyTimeConflictRequestClearsOlderDeferral() {
        var state = DeferredBusyTimeConflictReplanState()

        XCTAssertFalse(state.request(canRewriteSchedule: false))
        XCTAssertTrue(state.request(canRewriteSchedule: true))
        XCTAssertFalse(state.hasPendingRequest)
        XCTAssertFalse(state.resume(canRewriteSchedule: true))
    }

    // MARK: - Reschedule

    func testRescheduleReplacesUnlockedBlocks() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let old = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        let oldId = old.id
        context.insert(old)
        try context.save()

        let result = SchedulerService.reschedule(
            task: task, allBlocks: [old], settings: settings, context: context
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.isEmpty, "reschedule must insert replacement blocks")
        XCTAssertFalse(all.contains { $0.id == oldId }, "old block should be gone")
    }

    // MARK: - Progress model

    func testBlockCompletionLogsTimeNotProgress() {
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 40)
        block.isComplete = true
        context.insert(block)

        // Checking a block means "I worked this time" — nothing more.
        XCTAssertEqual(task.timeSpentMinutes, 40)
        XCTAssertEqual(task.progressPercent, 0)
        XCTAssertEqual(task.remainingMinutes, 100)

        // Progress moves only when the user says so.
        task.manualProgressPercent = 70
        XCTAssertEqual(task.progressPercent, 70)
        XCTAssertEqual(task.remainingMinutes, 30)
    }

    func testLinkedTimedSessionReplacesCompletedBlockInTimeSpent() throws {
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 40)
        block.isComplete = true
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 20 * 60,
            scheduledBlockId: block.id
        )
        context.insert(block)
        context.insert(session)
        try context.save()

        XCTAssertEqual(task.workedBlockMinutes, 0)
        XCTAssertEqual(task.timeSpentMinutes, 20, "the linked reservation must not count twice")
    }

    func testUnlinkedCompletedBlockStillCountsInTimeSpent() throws {
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 40)
        block.isComplete = true
        let floatingSession = WorkSession(
            task: task,
            startedAt: anchor.addingTimeInterval(3600),
            durationSeconds: 20 * 60
        )
        context.insert(block)
        context.insert(floatingSession)
        try context.save()

        XCTAssertEqual(task.workedBlockMinutes, 40)
        XCTAssertEqual(task.timeSpentMinutes, 60)
    }

    // MARK: - Work session block selection

    func testWorkSessionBlockSelectorIgnoresCompletedOverlap() throws {
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let completed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-30 * 60),
            durationMinutes: 60
        )
        completed.isComplete = true
        let incomplete = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-15 * 60),
            durationMinutes: 60
        )

        let selected = try XCTUnwrap(
            WorkSessionBlockSelector.currentIncompleteBlock(
                in: [completed, incomplete],
                at: anchor
            )
        )

        XCTAssertEqual(selected.id, incomplete.id)
    }

    func testWorkSessionBlockSelectorDeterministicallyPrefersEarliestStart() throws {
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let earlier = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-20 * 60),
            durationMinutes: 60
        )
        let later = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-10 * 60),
            durationMinutes: 60
        )

        let forward = try XCTUnwrap(
            WorkSessionBlockSelector.currentIncompleteBlock(
                in: [earlier, later],
                at: anchor
            )
        )
        let reversed = try XCTUnwrap(
            WorkSessionBlockSelector.currentIncompleteBlock(
                in: [later, earlier],
                at: anchor
            )
        )

        XCTAssertEqual(forward.id, earlier.id)
        XCTAssertEqual(reversed.id, earlier.id)
    }

    func testWorkSessionReceiptNeverClaimsASubSecondSessionWasLogged() {
        let copy = WorkSessionReceiptCopy.make(
            loggedSeconds: 0,
            scheduledBlock: true
        )

        XCTAssertEqual(copy.eyebrow, "THREAD OPEN")
        XCTAssertEqual(copy.title, "Session ended")
        XCTAssertEqual(copy.durationLabel, "No time added")
        XCTAssertEqual(copy.detailLabel, "Your task and schedule are unchanged")
        XCTAssertFalse(copy.message.contains("safely banked"))
    }

    func testWorkSessionReceiptDescribesRecordedTimeWithoutOverclaimingAttendance() {
        let copy = WorkSessionReceiptCopy.make(
            loggedSeconds: 37,
            scheduledBlock: true
        )

        XCTAssertEqual(copy.eyebrow, "THREAD HELD")
        XCTAssertEqual(copy.title, "Session logged")
        XCTAssertEqual(copy.durationLabel, "00:37")
        XCTAssertEqual(copy.detailLabel, "Time logged to scheduled block")
        XCTAssertFalse(copy.detailLabel.contains("fulfilled"))
    }

    // MARK: - Shared work-session clock

    func testWorkSessionControlStateDecodesLegacyJournal() throws {
        let sessionID = UUID()
        let json = """
        {
          "sessionID": "\(sessionID.uuidString)",
          "startedAt": 0,
          "accumulatedPausedSeconds": 17
        }
        """

        let decoded = try JSONDecoder().decode(
            WorkSessionControlState.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.startedAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(decoded.accumulatedPausedSeconds, 17)
        XCTAssertNil(decoded.taskID)
        XCTAssertNil(decoded.scheduledBlockID)
        XCTAssertNil(decoded.blockEndsAt)
        XCTAssertNil(decoded.ringStartsAt)
        XCTAssertNil(decoded.ringEndsAt)
    }

    func testWorkSessionRecoveryDecision() {
        let now = anchor
        let taskID = UUID()
        let fresh = WorkSessionControlState(
            sessionID: UUID(),
            startedAt: now.addingTimeInterval(-60),
            taskID: taskID
        )
        let missingTaskID = WorkSessionControlState(
            sessionID: UUID(),
            startedAt: now.addingTimeInterval(-60)
        )
        let stale = WorkSessionControlState(
            sessionID: UUID(),
            startedAt: now.addingTimeInterval(-12 * 3600),
            taskID: taskID
        )

        XCTAssertEqual(
            WorkSessionRecovery.evaluate(journal: nil, taskExists: true, now: now),
            .discard
        )
        XCTAssertEqual(
            WorkSessionRecovery.evaluate(
                journal: missingTaskID,
                taskExists: true,
                now: now
            ),
            .discard
        )
        XCTAssertEqual(
            WorkSessionRecovery.evaluate(journal: fresh, taskExists: false, now: now),
            .discard
        )
        XCTAssertEqual(
            WorkSessionRecovery.evaluate(journal: fresh, taskExists: nil, now: now),
            .keep,
            "an unavailable lookup must leave the recovery journal untouched"
        )
        XCTAssertEqual(
            WorkSessionRecovery.evaluate(journal: stale, taskExists: true, now: now),
            .discard
        )
        XCTAssertEqual(
            WorkSessionRecovery.evaluate(journal: fresh, taskExists: true, now: now),
            .restore(fresh)
        )
    }

    func testWorkSessionControlStateJournalRoundTripPreservesElapsedMath() throws {
        let start = anchor
        let evaluatedAt = start.addingTimeInterval(50 * 60)
        let state = WorkSessionControlState(
            sessionID: UUID(),
            startedAt: start,
            accumulatedPausedSeconds: 8 * 60,
            pauseBeganAt: start.addingTimeInterval(45 * 60),
            taskID: UUID(),
            scheduledBlockID: UUID(),
            blockEndsAt: start.addingTimeInterval(60 * 60),
            ringStartsAt: start.addingTimeInterval(-15 * 60),
            ringEndsAt: start.addingTimeInterval(75 * 60)
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkSessionControlState.self, from: data)

        XCTAssertEqual(
            decoded.elapsedWorkedSeconds(at: evaluatedAt),
            state.elapsedWorkedSeconds(at: evaluatedAt)
        )
        XCTAssertEqual(decoded, state)
    }

    func testWorkSessionControlStateExcludesPausedWallTime() {
        let start = anchor
        var state = WorkSessionControlState(sessionID: UUID(), startedAt: start)

        XCTAssertEqual(state.elapsedWorkedSeconds(at: start.addingTimeInterval(10)), 10)

        state.setPaused(true, at: start.addingTimeInterval(10))
        XCTAssertTrue(state.isPaused)
        XCTAssertEqual(
            state.elapsedWorkedSeconds(at: start.addingTimeInterval(40)),
            10,
            "worked time must freeze while the Live Activity reports paused"
        )

        state.setPaused(false, at: start.addingTimeInterval(40))
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.accumulatedPausedSeconds, 30)
        XCTAssertEqual(state.elapsedWorkedSeconds(at: start.addingTimeInterval(55)), 25)
    }

    func testWorkSessionControlStatePauseTransitionsAreIdempotentAndCodable() throws {
        let start = anchor
        var state = WorkSessionControlState(sessionID: UUID(), startedAt: start)

        state.setPaused(true, at: start.addingTimeInterval(5))
        state.setPaused(true, at: start.addingTimeInterval(20))
        state.setPaused(false, at: start.addingTimeInterval(25))
        state.setPaused(false, at: start.addingTimeInterval(40))

        XCTAssertEqual(state.accumulatedPausedSeconds, 20)
        XCTAssertEqual(state.elapsedWorkedSeconds(at: start.addingTimeInterval(40)), 20)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkSessionControlState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testIdleWorkSessionDismissalDoesNotOwnAttendanceOrTeardown() {
        XCTAssertFalse(
            WorkSessionDismissalPolicy.shouldRecord(localSessionID: nil),
            "presenting and dismissing an unstarted task must not enter the attendance or shared teardown path"
        )
        XCTAssertTrue(
            WorkSessionDismissalPolicy.shouldRecord(localSessionID: UUID()),
            "a locally started or recovered session still records through the durable dismissal path"
        )
    }

    @MainActor
    func testSessionScopedTeardownPreservesForeignJournalAndClearsMatchingJournal() {
        let original = WorkSessionControlStore.load()
        defer {
            WorkSessionControlStore.clear()
            if let original {
                WorkSessionControlStore.save(original)
            }
        }

        let taskAID = UUID()
        let sessionAID = UUID()
        let foreignJournal = WorkSessionControlState(
            sessionID: sessionAID,
            startedAt: anchor.addingTimeInterval(-60),
            taskID: taskAID
        )
        WorkSessionControlStore.save(foreignJournal)

        WorkSessionActivityController.end(sessionID: UUID())
        XCTAssertEqual(
            WorkSessionControlStore.load(),
            foreignJournal,
            "a stale task B view must not clear task A's active recovery journal"
        )

        WorkSessionActivityController.end(sessionID: sessionAID)
        XCTAssertNil(
            WorkSessionControlStore.load(),
            "the task that owns the active session must still clear its journal after durable stop"
        )
    }

    // MARK: - Start rounding & buffer

    func testRoundUpToFiveMinutes() {
        let messy = anchor.addingTimeInterval(7 * 60 + 33) // 9:07:33
        XCTAssertEqual(
            SchedulerService.roundUpToFiveMinutes(messy),
            anchor.addingTimeInterval(10 * 60)
        )
        // Exact boundaries stay put.
        XCTAssertEqual(SchedulerService.roundUpToFiveMinutes(anchor), anchor)
    }

    func testScheduleStartsOnFiveMinuteBoundary() {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let messyStart = anchor.addingTimeInterval(2 * 60 + 41) // 9:02:41

        let result = SchedulerService.schedule(
            task: task, allBlocks: [], settings: settings, from: messyStart
        )
        let blocks = scheduledBlocks(from: result)
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            XCTAssertGreaterThanOrEqual(block.startTime, messyStart)
            let seconds = Int(block.startTime.timeIntervalSinceReferenceDate)
            XCTAssertEqual(seconds % 300, 0, "block should start on a 5-minute boundary")
        }
    }

    // MARK: - Blocked-time conflict replanning

    func testReplanBlockedTimeConflictsMovesOverlappingBlocks() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        // Booked 10:00–11:00, then a class lands on 10:00–12:00 every day.
        let block = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        context.insert(block)
        let blocked = BlockedTime(
            label: "Class", weekdays: Array(1...7),
            startHour: 10, startMinute: 0, durationMinutes: 120
        )
        context.insert(blocked)
        try context.save()

        let replanned = SchedulerService.replanConflicts(
            tasks: [task],
            allBlocks: [block],
            blockedTimes: [blocked],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(replanned, 1)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.isEmpty, "the conflicting block should be replaced, not just deleted")
        for b in all {
            XCTAssertTrue(
                blocked.occurrences(from: b.startTime, to: b.endTime).isEmpty,
                "replanned block still overlaps the blocked time"
            )
        }
    }

    func testReplanBlockedTimeConflictsIgnoresNonConflictingTasks() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        // Booked 13:00–14:00; the class is 10:00–11:00 — no overlap.
        let block = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(4 * 3600), durationMinutes: 60)
        context.insert(block)
        let blocked = BlockedTime(
            label: "Class", weekdays: Array(1...7),
            startHour: 10, startMinute: 0, durationMinutes: 60
        )
        context.insert(blocked)
        try context.save()

        let replanned = SchedulerService.replanConflicts(
            tasks: [task],
            allBlocks: [block],
            blockedTimes: [blocked],
            settings: settings,
            now: anchor,
            context: context
        )

        XCTAssertEqual(replanned, 0, "untouched schedules must stay untouched")
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - Busy events (imported calendar)

    func testScheduleAvoidsBusyEvents() {
        let settings = makeSettings()
        // Imported event 9:00–15:00 on the anchor day.
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "evt-1",
            title: "Conference",
            startTime: anchor,
            endTime: anchor.addingTimeInterval(6 * 3600)
        )
        context.insert(busy)

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        let result = SchedulerService.schedule(
            task: task, allBlocks: [], busyEvents: [busy], settings: settings, from: anchor
        )

        let blocks = scheduledBlocks(from: result)
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            let overlaps = block.startTime < busy.endTime && block.endTime > busy.startTime
            XCTAssertFalse(overlaps, "block booked over an imported calendar event")
        }
    }

    func testReplanConflictsMovesBlocksOffBusyEvents() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        // Booked 10:00–11:00, then an imported event lands right on top.
        let block = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(3600), durationMinutes: 60)
        context.insert(block)
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "evt-2",
            title: "Dentist",
            startTime: anchor.addingTimeInterval(3600),
            endTime: anchor.addingTimeInterval(2 * 3600)
        )
        context.insert(busy)
        try context.save()

        let replanned = SchedulerService.replanConflicts(
            tasks: [task],
            allBlocks: [block],
            blockedTimes: [],
            busyEvents: [busy],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(replanned, 1)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.isEmpty)
        for b in all {
            let overlaps = b.startTime < busy.endTime && b.endTime > busy.startTime
            XCTAssertFalse(overlaps, "replanned block still overlaps the imported event")
        }
    }

    // MARK: - Catch-up: no overbooking, clear surfacing

    func testCatchUpDoesNotOverbookTasksWithFutureBlocks() throws {
        let settings = makeSettings()
        // 120m task: 60m missed + 60m still scheduled in the future. Catch-up
        // must replan through the reschedule path so total coverage stays 120m.
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let missed = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(-3 * 3600), durationMinutes: 60)
        let future = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(6 * 3600), durationMinutes: 60)
        context.insert(missed)
        context.insert(future)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [missed, future],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.replannedTasks, 1)
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let totalMinutes = all.filter { !$0.isComplete }.reduce(0) { $0 + $1.durationMinutes }
        XCTAssertEqual(totalMinutes, 120, "catch-up must not double-book remaining effort")
        for block in all {
            XCTAssertGreaterThanOrEqual(block.endTime, anchor, "no dangling past block may survive")
        }
    }

    func testCatchUpSurfacesUnschedulableTasks() throws {
        let settings = makeSettings() // deadline buffer 120
        // Missed block, and the deadline is now too close for any replacement.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 1)
        let missed = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(-2 * 3600), durationMinutes: 60)
        context.insert(missed)
        try context.save()

        let summary = SchedulerService.catchUpMissedBlocks(
            tasks: [task],
            allBlocks: [missed],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.replannedTasks, 1)
        XCTAssertEqual(summary.unschedulableTasks, 1, "impossible fits must be surfaced, not silent")
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.contains { $0.id == missed.id }, "the dangling missed block must be removed")
        XCTAssertEqual(all.reduce(0) { $0 + $1.durationMinutes }, 45, "Use the remaining deadline window before reporting a shortfall")
    }

    // MARK: - Rebalance (earliest deadline first)

    func testRebalanceBumpsFartherDeadlineForUrgentTask() throws {
        let settings = makeSettings() // buffer 120, start buffer 15
        // A relaxed task holds the only slot an urgent task could use:
        // its block sits 9:00-11:00, and the urgent task is due in 3 hours
        // (usable window ends 10:00).
        let relaxed = makeTask(effort: 120, deadlineHoursFromAnchor: 30)
        let occupying = ScheduledBlock(task: relaxed, startTime: anchor, durationMinutes: 120)
        context.insert(occupying)

        let urgent = makeTask(effort: 30, deadlineHoursFromAnchor: 1)
        try context.save()

        // Gap-fill alone fails: the near window is taken.
        let gapFill = SchedulerService.schedule(
            task: urgent, allBlocks: [occupying], settings: settings,
            from: anchor.addingTimeInterval(15 * 60)
        )
        guard case .noSlots = gapFill else {
            return XCTFail("expected the urgent task not to fit as-is, got \(gapFill)")
        }

        // Rebalance moves the relaxed work aside.
        let summary = SchedulerService.rebalance(
            tasks: [relaxed, urgent],
            allBlocks: [occupying],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(summary.unschedulableTasks, 0, "both tasks should fit after rebalancing")

        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let urgentWindowEnd = urgent.deadline
        let urgentBlocks = all.filter { $0.task?.id == urgent.id }
        let relaxedBlocks = all.filter { $0.task?.id == relaxed.id }

        XCTAssertEqual(urgentBlocks.reduce(0) { $0 + $1.durationMinutes }, 30)
        for block in urgentBlocks {
            XCTAssertLessThanOrEqual(block.endTime, urgentWindowEnd, "urgent task must finish before its buffered deadline")
        }
        XCTAssertEqual(relaxedBlocks.reduce(0) { $0 + $1.durationMinutes }, 120, "bumped work is rescheduled, not dropped")

        // No overlaps anywhere.
        let sorted = all.sorted { $0.startTime < $1.startTime }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(a.endTime, b.startTime, "rebalanced blocks must not overlap")
        }
    }

    // MARK: - Estimate advisor

    /// A completed task with a real planned-vs-actual record: `spent` minutes
    /// of tracked sessions against an `effort`-minute estimate.
    @discardableResult
    private func makeCompletedTask(
        taskContext: TaskContext = .school,
        effort: Int,
        spent: Int,
        completedDaysAgo: Int = 1
    ) -> FilumaTask {
        let completedAt = anchor.addingTimeInterval(-Double(completedDaysAgo) * 86_400)
        let task = FilumaTask(
            title: "Done task",
            context: taskContext,
            deadline: completedAt,
            effortMinutes: effort
        )
        task.isComplete = true
        task.completedAt = completedAt
        context.insert(task)
        let session = WorkSession(
            task: task,
            startedAt: completedAt.addingTimeInterval(-Double(spent) * 60),
            durationSeconds: spent * 60
        )
        context.insert(session)
        return task
    }

    func testEstimateAdvisorNeedsThreeSamples() throws {
        makeCompletedTask(effort: 60, spent: 120)
        makeCompletedTask(effort: 60, spent: 120)
        try context.save()

        XCTAssertNil(
            EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context),
            "two samples are an anecdote, not a pattern"
        )
    }

    func testEstimateAdvisorSuggestsMedianOverrun() throws {
        makeCompletedTask(effort: 60, spent: 90)   // 1.5×
        makeCompletedTask(effort: 60, spent: 96)   // 1.6×
        makeCompletedTask(effort: 60, spent: 102)  // 1.7×
        try context.save()

        let advice = try XCTUnwrap(EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context))
        XCTAssertEqual(advice.sampleCount, 3)
        XCTAssertEqual(advice.ratio, 1.6, accuracy: 0.01)
        // 60 × 1.6 = 96, rounded to the nearest 15.
        XCTAssertEqual(advice.suggestedMinutes, 90)
    }

    func testEstimateAdvisorCapsSuggestionAtDouble() throws {
        makeCompletedTask(effort: 60, spent: 180)  // 3×
        makeCompletedTask(effort: 60, spent: 180)
        makeCompletedTask(effort: 60, spent: 180)
        try context.save()

        let advice = try XCTUnwrap(EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context))
        XCTAssertEqual(advice.ratio, 3.0, accuracy: 0.01, "the shown ratio stays honest")
        XCTAssertEqual(advice.suggestedMinutes, 120, "the suggestion is capped at 2× the guess")
    }

    func testEstimateAdvisorSilentWhenEstimatesAreHonest() throws {
        makeCompletedTask(effort: 60, spent: 55)
        makeCompletedTask(effort: 60, spent: 60)
        makeCompletedTask(effort: 60, spent: 66)
        try context.save()

        XCTAssertNil(
            EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context),
            "roughly accurate history should not interrupt capture"
        )
    }

    func testEstimateAdvisorIgnoresOtherContextsAndUntrackedTasks() throws {
        // Chronic over-runs, but all in Work…
        makeCompletedTask(taskContext: .work, effort: 60, spent: 150)
        makeCompletedTask(taskContext: .work, effort: 60, spent: 150)
        makeCompletedTask(taskContext: .work, effort: 60, spent: 150)
        // …and School completions with no tracked time say nothing.
        let untracked = makeTask(effort: 60, deadlineHoursFromAnchor: -24)
        untracked.isComplete = true
        untracked.completedAt = anchor
        try context.save()

        XCTAssertNil(
            EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context),
            "advice must come from the same context and only from tracked work"
        )
        XCTAssertNotNil(
            EstimateAdvisor.advice(for: .work, effortMinutes: 60, in: context),
            "the Work record itself should still advise Work captures"
        )
    }

    func testEstimateAdvisorUsesFiveMostRecentSamples() throws {
        // Old habit: wild over-runs, further in the past.
        for daysAgo in 10...14 {
            makeCompletedTask(effort: 60, spent: 180, completedDaysAgo: daysAgo)
        }
        // Recent record: dead-on estimates.
        for daysAgo in 1...5 {
            makeCompletedTask(effort: 60, spent: 60, completedDaysAgo: daysAgo)
        }
        try context.save()

        XCTAssertNil(
            EstimateAdvisor.advice(for: .school, effortMinutes: 60, in: context),
            "recent accuracy should outweigh an older over-run habit"
        )
    }

    // MARK: - Start streaks

    /// Noon on the day `daysAgo` days before the anchor.
    private func startDate(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: anchor)!
    }

    func testStreakCountsConsecutiveStartDays() {
        let starts = [0, 1, 2, 3].map(startDate(daysAgo:))
        XCTAssertEqual(StreakCalculator.startStreak(startDates: starts, now: anchor), 4)
    }

    func testStreakEmptyHistoryIsZero() {
        XCTAssertEqual(StreakCalculator.startStreak(startDates: [], now: anchor), 0)
    }

    func testStreakTodayWithoutStartDoesNotBreak() {
        // Started yesterday and the day before; nothing yet today.
        let starts = [1, 2].map(startDate(daysAgo:))
        XCTAssertEqual(
            StreakCalculator.startStreak(startDates: starts, now: anchor), 2,
            "an unfinished today must neither break nor count"
        )
    }

    func testStreakMendsBridgeShortGaps() {
        // Started 0, 1, 3, 4 days ago — the single missed day is mended and
        // counted, so the thread reads 5.
        let starts = [0, 1, 3, 4].map(startDate(daysAgo:))
        XCTAssertEqual(StreakCalculator.startStreak(startDates: starts, now: anchor), 5)
    }

    func testStreakBreaksWhenWeeklyMendsRunOut() {
        // A five-day gap can never be mended (at most 2 mends per week, and
        // the gap spans at most two calendar weeks), wherever the week breaks.
        let starts = [0, 6, 7].map(startDate(daysAgo:))
        XCTAssertEqual(
            StreakCalculator.startStreak(startDates: starts, now: anchor), 1,
            "a five-day gap should end the chain at today's start"
        )
    }

    // MARK: - Pace (schedule pressure)

    func testAvailableMinutesSubtractsOtherWork() {
        let settings = makeSettings() // wake 8, sleep 23
        let other = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: other, startTime: anchor, durationMinutes: 120)
        context.insert(block)

        // 9:00 → 14:00 = 300 minutes, minus the 120-minute block.
        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(5 * 3600),
            allBlocks: [block],
            settings: settings
        )
        XCTAssertEqual(available, 180)
    }

    func testAvailableMinutesIgnoresOwnBlocks() {
        let settings = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let ownBlock = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 120)
        context.insert(ownBlock)

        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(5 * 3600),
            excludingTaskId: task.id,
            allBlocks: [ownBlock],
            settings: settings
        )
        XCTAssertEqual(available, 300, "a task's own booked time still belongs to it")
    }

    func testAvailableMinutesRespectsDailyFocusRemainingAfterExistingWork() {
        let settings = makeSettings()
        settings.dailyFocusMinutes = 120

        let other = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        // This block ends exactly when the queried window begins. It does not
        // occupy the window, but it has already spent half today's focus cap.
        let earlierBlock = ScheduledBlock(
            task: other,
            startTime: anchor.addingTimeInterval(-60 * 60),
            durationMinutes: 60
        )
        context.insert(earlierBlock)

        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(5 * 3600),
            allBlocks: [earlierBlock],
            settings: settings
        )
        XCTAssertEqual(available, 60)
    }

    func testAvailableMinutesRoundsEachDayDownToValidBlockCapacity() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 9
        settings.sleepMinute = 55
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 45
        settings.dailyFocusMinutes = 55

        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(55 * 60),
            allBlocks: [],
            settings: settings
        )
        XCTAssertEqual(available, 45, "the unusable 10-minute tail is not capacity")
    }

    func testFragmentedFiftyFiveMinuteGapsHaveNinetyMinutesOfCapacity() {
        let settings = makeSettings()
        settings.wakeHour = 9
        settings.sleepHour = 11
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 45
        settings.dailyFocusMinutes = 0

        let occupyingTask = makeTask(effort: 10, deadlineHoursFromAnchor: 24)
        let hold = ScheduledBlock(
            task: occupyingTask,
            startTime: anchor.addingTimeInterval(55 * 60),
            durationMinutes: 10
        )
        context.insert(hold)

        let windowEnd = anchor.addingTimeInterval(2 * 60 * 60)
        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: windowEnd,
            allBlocks: [hold],
            settings: settings
        )
        XCTAssertEqual(
            available,
            90,
            "each 55-minute gap can hold one 45-minute block; their 10-minute tails cannot pool"
        )

        let task = makeTask(effort: 110, deadlineHoursFromAnchor: 4)
        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [hold],
            settings: settings,
            from: anchor
        )
        guard case .partialFit(let blocks, let unscheduledMinutes) = result else {
            return XCTFail("expected maximal partial fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [45, 45])
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 90)
        XCTAssertEqual(unscheduledMinutes, 20)
    }

    func testOvernightCapacityChargesFocusToTheAfterMidnightDay() throws {
        let settings = makeSettings()
        settings.wakeHour = 22
        settings.sleepHour = 2
        settings.dailyFocusMinutes = 120
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 90

        let day = calendar.startOfDay(for: anchor)
        let overnightStart = calendar.date(
            bySettingHour: 23,
            minute: 0,
            second: 0,
            of: day
        )!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let windowEnd = calendar.date(
            bySettingHour: 1,
            minute: 0,
            second: 0,
            of: nextDay
        )!

        // This reservation begins exactly when the query ends, so it does not
        // occupy the 23:00-01:00 gap. It does consume all of the next date's
        // focus budget, leaving only the hour before midnight available.
        let other = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let afterMidnightWork = ScheduledBlock(
            task: other,
            startTime: windowEnd,
            durationMinutes: 120
        )
        context.insert(afterMidnightWork)

        let available = SchedulerService.availableMinutes(
            from: overnightStart,
            to: windowEnd,
            allBlocks: [afterMidnightWork],
            settings: settings
        )
        XCTAssertEqual(available, 60)

        let task = FilumaTask(
            title: "Overnight task",
            context: .school,
            deadline: windowEnd.addingTimeInterval(
                TimeInterval(settings.deadlineBufferMinutes * 60)
            ),
            effortMinutes: 120
        )
        context.insert(task)
        let pace = try XCTUnwrap(SchedulerService.pressureAndAvailableMinutes(
            for: task,
            allBlocks: [afterMidnightWork],
            settings: settings,
            now: overnightStart
        ))
        XCTAssertEqual(pace.availableMinutes, 60)
        XCTAssertEqual(pace.pressure, 2.0, accuracy: 0.01)
    }

    func testOvernightCapacityPreservesAContinuousMinimumBlockAcrossMidnight() throws {
        let settings = makeSettings()
        settings.wakeHour = 23
        settings.wakeMinute = 45
        settings.sleepHour = 0
        settings.sleepMinute = 15
        settings.dailyFocusMinutes = 30
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 30

        let day = calendar.startOfDay(for: anchor)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let windowStart = calendar.date(
            bySettingHour: 23,
            minute: 45,
            second: 0,
            of: day
        )!
        let windowEnd = calendar.date(
            bySettingHour: 0,
            minute: 15,
            second: 0,
            of: nextDay
        )!

        // Fifteen focus minutes remain on each date. Neither side of midnight
        // is a valid block alone, but the real continuous gap holds one 30m
        // block whose focus cost is split 15 + 15.
        let other = makeTask(effort: 30, deadlineHoursFromAnchor: 72)
        let before = ScheduledBlock(
            task: other,
            startTime: windowStart.addingTimeInterval(-45 * 60),
            durationMinutes: 15
        )
        let after = ScheduledBlock(
            task: other,
            startTime: windowEnd.addingTimeInterval(15 * 60),
            durationMinutes: 15
        )
        context.insert(before)
        context.insert(after)

        let existing = [before, after]
        let available = SchedulerService.availableMinutes(
            from: windowStart,
            to: windowEnd,
            allBlocks: existing,
            settings: settings
        )
        XCTAssertEqual(available, 30)

        let task = FilumaTask(
            title: "Midnight seam",
            context: .school,
            deadline: windowEnd.addingTimeInterval(
                TimeInterval(settings.deadlineBufferMinutes * 60)
            ),
            effortMinutes: 30
        )
        context.insert(task)

        let pace = try XCTUnwrap(SchedulerService.pressureAndAvailableMinutes(
            for: task,
            allBlocks: existing,
            settings: settings,
            now: windowStart
        ))
        XCTAssertEqual(pace.availableMinutes, 30)
        XCTAssertEqual(pace.pressure, 1.0, accuracy: 0.01)

        let result = SchedulerService.schedule(
            task: task,
            allBlocks: existing,
            settings: settings,
            from: windowStart
        )
        guard case .success(let blocks) = result else {
            return XCTFail("expected seam block to fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [30])
        XCTAssertEqual(blocks.first?.startTime, windowStart)
    }

    func testMixedSameDayAndMidnightGapsMaximizePartialFitAndMatchCapacity() throws {
        let settings = makeSettings()
        settings.wakeHour = 22
        settings.sleepHour = 1
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 45
        settings.dailyFocusMinutes = 0

        let day = calendar.startOfDay(for: anchor)
        let windowStart = calendar.date(
            bySettingHour: 22,
            minute: 0,
            second: 0,
            of: day
        )!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let windowEnd = calendar.date(
            bySettingHour: 0,
            minute: 30,
            second: 0,
            of: nextDay
        )!

        // Free time is 22:00-22:45 (45m) plus 23:35-00:30 (55m).
        // The second gap crosses midnight, but both can still hold a 45m block.
        let occupyingTask = makeTask(effort: 50, deadlineHoursFromAnchor: 72)
        let hold = ScheduledBlock(
            task: occupyingTask,
            startTime: windowStart.addingTimeInterval(45 * 60),
            durationMinutes: 50
        )
        context.insert(hold)

        let available = SchedulerService.availableMinutes(
            from: windowStart,
            to: windowEnd,
            allBlocks: [hold],
            settings: settings
        )
        XCTAssertEqual(available, 90)

        let task = FilumaTask(
            title: "Mixed midnight gaps",
            context: .school,
            deadline: windowEnd,
            effortMinutes: 100
        )
        context.insert(task)

        let result = SchedulerService.schedule(
            task: task,
            allBlocks: [hold],
            settings: settings,
            from: windowStart
        )
        guard case .partialFit(let blocks, let unscheduledMinutes) = result else {
            return XCTFail("expected a maximal partial fit, got \(result)")
        }
        XCTAssertEqual(blocks.map(\.durationMinutes), [45, 45])
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, available)
        XCTAssertEqual(unscheduledMinutes, 10)
    }

    func testAvailableMinutesCreditsOnlyOwnBlockPortionInsideWindow() {
        let settings = makeSettings()
        settings.dailyFocusMinutes = 120

        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        // Only 13:00-14:00 overlaps the query. The locked 14:00-15:00
        // portion remains real focus usage and leaves 60 minutes of capacity.
        let ownBlock = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(4 * 60 * 60),
            durationMinutes: 120
        )
        ownBlock.isLocked = true
        context.insert(ownBlock)

        let available = SchedulerService.availableMinutes(
            from: anchor,
            to: anchor.addingTimeInterval(5 * 60 * 60),
            excludingTaskId: task.id,
            allBlocks: [ownBlock],
            settings: settings
        )
        XCTAssertEqual(available, 60)
    }

    func testPressureReflectsRemainingVersusFreeTime() throws {
        let settings = makeSettings() // buffer 120
        // Pressure measures achievable capacity through the actual deadline: 420 minutes.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 7)
        let pressure = try XCTUnwrap(SchedulerService.pressure(
            for: task, allBlocks: [], settings: settings, now: anchor
        ))
        XCTAssertEqual(pressure, 60.0 / 420.0, accuracy: 0.01)
    }

    func testPressureRespectsDailyFocusRemainingAfterExistingWork() throws {
        let settings = makeSettings()
        settings.dailyFocusMinutes = 120

        let other = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let earlierBlock = ScheduledBlock(
            task: other,
            startTime: anchor.addingTimeInterval(-60 * 60),
            durationMinutes: 60
        )
        context.insert(earlierBlock)

        // The wall-clock window is 300 minutes, but only 60 minutes of today's
        // focus budget remain, so 60 minutes of work creates full pressure.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 7)
        let pace = try XCTUnwrap(SchedulerService.pressureAndAvailableMinutes(
            for: task,
            allBlocks: [earlierBlock],
            settings: settings,
            now: anchor
        ))
        XCTAssertEqual(pace.availableMinutes, 60)
        XCTAssertEqual(pace.pressure, 1.0, accuracy: 0.01)
    }

    func testPressureRejectsSubMinimumDailyFocusRemainder() throws {
        let settings = makeSettings()
        settings.minBlockMinutes = 30
        settings.maxBlockMinutes = 90
        settings.dailyFocusMinutes = 45

        let other = makeTask(effort: 20, deadlineHoursFromAnchor: 48)
        let earlierBlock = ScheduledBlock(
            task: other,
            startTime: anchor.addingTimeInterval(-20 * 60),
            durationMinutes: 20
        )
        context.insert(earlierBlock)

        // Twenty-five focus minutes remain today, but this task's 60-minute
        // remainder requires blocks of at least 30 minutes.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 7)
        let pace = try XCTUnwrap(SchedulerService.pressureAndAvailableMinutes(
            for: task,
            allBlocks: [earlierBlock],
            settings: settings,
            now: anchor
        ))
        XCTAssertEqual(pace.availableMinutes, 0)
        XCTAssertTrue(pace.pressure.isInfinite)
    }

    func testPressureInfiniteWhenNoWindowRemains() throws {
        let settings = makeSettings() // buffer 120
        // The actual deadline has passed.
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: -1)
        let pressure = try XCTUnwrap(SchedulerService.pressure(
            for: task, allBlocks: [], settings: settings, now: anchor
        ))
        XCTAssertTrue(pressure.isInfinite)
    }

    func testPressureNilWithoutRemainingEffort() {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 24)
        task.manualProgressPercent = 100
        XCTAssertNil(SchedulerService.pressure(
            for: task, allBlocks: [], settings: settings, now: anchor
        ))
    }

    // MARK: - Daily digests

    private func digestBlock(
        title: String = "Lab report",
        startHour: Double,
        minutes: Int = 60,
        isComplete: Bool = false
    ) -> BlockNotificationService.DigestBlock {
        let start = anchor.addingTimeInterval((startHour - 9) * 3600)
        return BlockNotificationService.DigestBlock(
            title: title,
            start: start,
            end: start.addingTimeInterval(Double(minutes) * 60),
            isComplete: isComplete
        )
    }

    func testMorningDigestNamesFirstBlockAndDayShape() throws {
        let body = try XCTUnwrap(BlockNotificationService.morningDigestBody(dayBlocks: [
            digestBlock(title: "Lab report", startHour: 9),
            digestBlock(title: "Essay", startHour: 13, minutes: 90),
            digestBlock(title: "Reading", startHour: 11)
        ]))
        XCTAssertTrue(body.contains("Lab report"), "leads with the first block: \(body)")
        XCTAssertTrue(body.contains("3 blocks"), "names the day's shape: \(body)")
        XCTAssertTrue(body.contains("2:30"), "ends with when the day is done: \(body)")
    }

    func testMorningDigestNilOnEmptyDay() {
        XCTAssertNil(BlockNotificationService.morningDigestBody(dayBlocks: []))
    }

    func testEveningDigestCountsAndPreviewsTomorrow() throws {
        let body = try XCTUnwrap(BlockNotificationService.eveningDigestBody(
            todayBlocks: [
                digestBlock(startHour: 9, isComplete: true),
                digestBlock(startHour: 11, isComplete: true),
                digestBlock(startHour: 14)
            ],
            tomorrowFirst: digestBlock(title: "Problem set", startHour: 10)
        ))
        XCTAssertTrue(body.contains("2 of 3"), "honest done count: \(body)")
        XCTAssertTrue(body.contains("Problem set"), "pre-loads tomorrow's opener: \(body)")
    }

    func testEveningDigestNilWhenNothingToSay() {
        XCTAssertNil(BlockNotificationService.eveningDigestBody(
            todayBlocks: [], tomorrowFirst: nil
        ))
    }

    func testBlockAlertBudgetPreservesDigestsThenNearestStartsAndLeads() {
        let starts = (0..<20).map { index in
            BlockNotificationService.BlockAlertCandidate(
                identifier: "block-\(index)",
                fireDate: anchor.addingTimeInterval(Double(index) * 3600),
                isLead: false
            )
        }
        let leads = (0..<20).map { index in
            BlockNotificationService.BlockAlertCandidate(
                identifier: "block-\(index)-lead",
                fireDate: anchor.addingTimeInterval(Double(index) * 3600 - 600),
                isLead: true
            )
        }

        let selected = BlockNotificationService.selectBlockAlerts(
            candidates: starts + leads,
            digestCount: 6,
            otherPendingCount: 19
        )

        XCTAssertEqual(selected.count + 6 + 19, 55)
        XCTAssertEqual(selected.filter { !$0.isLead }, starts)
        XCTAssertEqual(selected.filter(\.isLead), Array(leads.prefix(10)))

        let startsOnly = BlockNotificationService.selectBlockAlerts(
            candidates: starts + leads,
            digestCount: 6,
            otherPendingCount: 34
        )
        XCTAssertEqual(startsOnly, Array(starts.prefix(15)))
    }

    func testBlockAlertBudgetFitsAllCandidatesWithNoOtherPendingRequests() {
        let candidates = (0..<20).flatMap { index in
            let start = anchor.addingTimeInterval(Double(index) * 3600)
            return [
                BlockNotificationService.BlockAlertCandidate(
                    identifier: "block-\(index)", fireDate: start, isLead: false
                ),
                BlockNotificationService.BlockAlertCandidate(
                    identifier: "block-\(index)-lead",
                    fireDate: start.addingTimeInterval(-600),
                    isLead: true
                )
            ]
        }

        let selected = BlockNotificationService.selectBlockAlerts(
            candidates: candidates,
            digestCount: 6,
            otherPendingCount: 0
        )

        XCTAssertEqual(selected.count, 40)
        XCTAssertEqual(selected.filter { !$0.isLead }.count, 20)
        XCTAssertEqual(selected.filter(\.isLead).count, 20)
    }

    func testBlockAlertBudgetOrderingIsDeterministic() {
        let candidates = [
            BlockNotificationService.BlockAlertCandidate(
                identifier: "block-b-lead", fireDate: anchor, isLead: true
            ),
            BlockNotificationService.BlockAlertCandidate(
                identifier: "block-b", fireDate: anchor, isLead: false
            ),
            BlockNotificationService.BlockAlertCandidate(
                identifier: "block-a-lead", fireDate: anchor, isLead: true
            ),
            BlockNotificationService.BlockAlertCandidate(
                identifier: "block-a", fireDate: anchor, isLead: false
            )
        ]
        let expected = ["block-a", "block-b", "block-a-lead", "block-b-lead"]

        let forward = BlockNotificationService.selectBlockAlerts(
            candidates: candidates,
            digestCount: 0,
            otherPendingCount: 0
        )
        let reversed = BlockNotificationService.selectBlockAlerts(
            candidates: Array(candidates.reversed()),
            digestCount: 0,
            otherPendingCount: 0
        )

        XCTAssertEqual(forward.map(\.identifier), expected)
        XCTAssertEqual(reversed.map(\.identifier), expected)
    }

    // MARK: - Recurring tasks

    func testMaterializeStampsOccurrencesTwoWeeksAhead() throws {
        let settings = makeSettings()
        let template = TaskTemplate(
            title: "Weekly problem set",
            context: .school,
            effortMinutes: 60,
            nextDeadline: anchor.addingTimeInterval(3 * 86_400),
            repeatUntil: anchor.addingTimeInterval(60 * 86_400)
        )
        context.insert(template)
        try context.save()

        let created = SchedulerService.materializeRecurringTasks(
            templates: [template],
            allBlocks: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        // Deadlines at day 3 and day 10 fall inside the 14-day horizon; day 17 doesn't.
        XCTAssertEqual(created, 2)
        let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
            .filter { $0.source == .recurring }
        XCTAssertEqual(tasks.count, 2)
        for task in tasks {
            XCTAssertEqual(task.templateId, template.id)
            XCTAssertFalse(task.scheduledBlocks.isEmpty, "occurrences arrive already scheduled")
        }
        XCTAssertEqual(
            template.nextDeadline,
            anchor.addingTimeInterval(17 * 86_400),
            "the template must remember where it left off"
        )

        // A second pass right away must not duplicate anything.
        let secondPass = SchedulerService.materializeRecurringTasks(
            templates: [template],
            allBlocks: try context.fetch(FetchDescriptor<ScheduledBlock>()),
            settings: settings,
            now: anchor,
            context: context
        )
        XCTAssertEqual(secondPass, 0)
    }

    func testMaterializeSkipsMissedOccurrencesWithoutGuilt() throws {
        let settings = makeSettings()
        // The app wasn't opened for a while: one occurrence is already past.
        let template = TaskTemplate(
            title: "Weekly reading",
            context: .school,
            effortMinutes: 30,
            nextDeadline: anchor.addingTimeInterval(-3 * 86_400),
            repeatUntil: anchor.addingTimeInterval(60 * 86_400)
        )
        context.insert(template)
        try context.save()

        let created = SchedulerService.materializeRecurringTasks(
            templates: [template],
            allBlocks: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        // Day −3 is skipped; days +4 and +11 materialize.
        XCTAssertEqual(created, 2)
        let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
        XCTAssertTrue(
            tasks.allSatisfy { $0.deadline > anchor },
            "a recurrence must never spawn an already-overdue task"
        )
    }

    func testMaterializeRetiresExhaustedTemplates() throws {
        let settings = makeSettings()
        let template = TaskTemplate(
            title: "Short-lived chore",
            context: .personal,
            effortMinutes: 30,
            nextDeadline: anchor.addingTimeInterval(2 * 86_400),
            repeatUntil: anchor.addingTimeInterval(5 * 86_400)
        )
        context.insert(template)
        try context.save()

        let created = SchedulerService.materializeRecurringTasks(
            templates: [template],
            allBlocks: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        XCTAssertEqual(created, 1, "only the day-2 occurrence fits before repeatUntil")
        let remaining = try context.fetch(FetchDescriptor<TaskTemplate>())
        XCTAssertTrue(remaining.isEmpty, "an exhausted template deletes itself")
    }

    @MainActor
    func testStopRepeatingDurablyDeletesTemplateAndClearsEveryOccurrence() throws {
        let template = TaskTemplate(
            title: "Weekly reading",
            context: .school,
            effortMinutes: 45,
            nextDeadline: anchor.addingTimeInterval(7 * 86_400),
            repeatUntil: anchor.addingTimeInterval(60 * 86_400)
        )
        let first = makeTask(effort: 45, deadlineHoursFromAnchor: 24)
        let second = makeTask(effort: 45, deadlineHoursFromAnchor: 48)
        let unrelated = makeTask(effort: 30, deadlineHoursFromAnchor: 72)
        first.templateId = template.id
        second.templateId = template.id
        let unrelatedMarker = UUID()
        unrelated.templateId = unrelatedMarker
        context.insert(template)
        try context.save()

        var finalSaveFinished = false
        var publishCount = 0
        try PlanCoordinator.stopRepeating(
            templateID: template.id,
            context: context,
            save: { context in
                try context.save()
                finalSaveFinished = true
            },
            publish: { _, _ in
                XCTAssertTrue(finalSaveFinished, "publish must follow the durable save")
                publishCount += 1
            }
        )

        XCTAssertNil(first.templateId)
        XCTAssertNil(second.templateId)
        XCTAssertEqual(unrelated.templateId, unrelatedMarker)
        XCTAssertEqual(publishCount, 1)

        let fresh = ModelContext(container)
        XCTAssertFalse(
            try fresh.fetch(FetchDescriptor<TaskTemplate>()).contains { $0.id == template.id }
        )
        let durableTasks = try fresh.fetch(FetchDescriptor<FilumaTask>())
        XCTAssertNil(durableTasks.first { $0.id == first.id }?.templateId)
        XCTAssertNil(durableTasks.first { $0.id == second.id }?.templateId)
        XCTAssertEqual(
            durableTasks.first { $0.id == unrelated.id }?.templateId,
            unrelatedMarker
        )
    }

    @MainActor
    func testStopRepeatingSaveFailureRestoresHeldAndDurableRecurrenceForRetry() throws {
        enum ExpectedFailure: Error { case save }

        let template = TaskTemplate(
            title: "Weekly review",
            context: .work,
            effortMinutes: 30,
            nextDeadline: anchor.addingTimeInterval(7 * 86_400),
            repeatUntil: anchor.addingTimeInterval(60 * 86_400)
        )
        let first = makeTask(effort: 30, deadlineHoursFromAnchor: 24)
        let second = makeTask(effort: 30, deadlineHoursFromAnchor: 48)
        first.templateId = template.id
        second.templateId = template.id
        context.insert(template)
        try context.save()

        var publishCount = 0
        XCTAssertThrowsError(
            try PlanCoordinator.stopRepeating(
                templateID: template.id,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(first.templateId, template.id)
        XCTAssertEqual(second.templateId, template.id)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<TaskTemplate>()).contains { $0.id == template.id }
        )
        XCTAssertEqual(publishCount, 0)

        let fresh = ModelContext(container)
        XCTAssertTrue(
            try fresh.fetch(FetchDescriptor<TaskTemplate>()).contains { $0.id == template.id }
        )
        let durableTasks = try fresh.fetch(FetchDescriptor<FilumaTask>())
        XCTAssertEqual(durableTasks.first { $0.id == first.id }?.templateId, template.id)
        XCTAssertEqual(durableTasks.first { $0.id == second.id }?.templateId, template.id)

        try PlanCoordinator.stopRepeating(
            templateID: template.id,
            context: context,
            interactive: false,
            publish: { _, _ in publishCount += 1 }
        )
        XCTAssertNil(first.templateId)
        XCTAssertNil(second.templateId)
        XCTAssertEqual(publishCount, 1)

        let afterRetry = ModelContext(container)
        XCTAssertFalse(
            try afterRetry.fetch(FetchDescriptor<TaskTemplate>())
                .contains { $0.id == template.id }
        )
        let retryTasks = try afterRetry.fetch(FetchDescriptor<FilumaTask>())
        XCTAssertNil(retryTasks.first { $0.id == first.id }?.templateId)
        XCTAssertNil(retryTasks.first { $0.id == second.id }?.templateId)
    }

    @MainActor
    func testStopRepeatingReadFailureLeavesEverythingUntouched() throws {
        enum ExpectedFailure: Error { case fetch }

        let template = TaskTemplate(
            title: "Weekly planning",
            context: .personal,
            effortMinutes: 30,
            nextDeadline: anchor.addingTimeInterval(7 * 86_400),
            repeatUntil: anchor.addingTimeInterval(60 * 86_400)
        )
        let task = makeTask(effort: 30, deadlineHoursFromAnchor: 24)
        task.templateId = template.id
        context.insert(template)
        try context.save()

        var saveCount = 0
        var publishCount = 0
        XCTAssertThrowsError(
            try PlanCoordinator.stopRepeating(
                templateID: template.id,
                context: context,
                load: { _, _ in throw ExpectedFailure.fetch },
                save: { _ in saveCount += 1 },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(task.templateId, template.id)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<TaskTemplate>()).contains { $0.id == template.id }
        )
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(publishCount, 0)
    }

    @MainActor
    func testStopRepeatingClearsStaleMarkersWhenTemplateAlreadyRetired() throws {
        let staleTemplateID = UUID()
        let task = makeTask(effort: 30, deadlineHoursFromAnchor: 24)
        task.templateId = staleTemplateID
        try context.save()

        var publishCount = 0
        try PlanCoordinator.stopRepeating(
            templateID: staleTemplateID,
            context: context,
            publish: { _, _ in publishCount += 1 }
        )

        XCTAssertNil(task.templateId)
        XCTAssertEqual(publishCount, 1)
        let fresh = ModelContext(container)
        XCTAssertNil(
            try fresh.fetch(FetchDescriptor<FilumaTask>())
                .first { $0.id == task.id }?.templateId
        )
    }

    // MARK: - Weave

    func testWeaveAggregatesSessionsAndCheckedBlocksByDay() throws {
        let school = makeTask(effort: 300, deadlineHoursFromAnchor: 48)
        let personal = FilumaTask(
            title: "Chores", context: .personal,
            deadline: anchor.addingTimeInterval(48 * 3600), effortMinutes: 120
        )
        context.insert(personal)

        // Today: two school sessions and a checked personal block.
        let s1 = WorkSession(task: school, startedAt: anchor, durationSeconds: 60 * 60)
        let s2 = WorkSession(task: school, startedAt: anchor.addingTimeInterval(3 * 3600), durationSeconds: 30 * 60)
        let checked = ScheduledBlock(task: personal, startTime: anchor.addingTimeInterval(3600), durationMinutes: 45)
        checked.isComplete = true
        // Yesterday: one personal session. An unchecked block must not count.
        let s3 = WorkSession(task: personal, startedAt: anchor.addingTimeInterval(-24 * 3600), durationSeconds: 20 * 60)
        let unchecked = ScheduledBlock(task: school, startTime: anchor.addingTimeInterval(-24 * 3600), durationMinutes: 90)
        context.insert(s1)
        context.insert(s2)
        context.insert(checked)
        context.insert(s3)
        context.insert(unchecked)
        try context.save()

        let days = WeaveBuilder.days(
            sessions: [s1, s2, s3],
            blocks: [checked, unchecked],
            daysBack: 7,
            now: anchor
        )

        XCTAssertEqual(days.count, 7)
        let today = try XCTUnwrap(days.last)
        XCTAssertEqual(today.minutesByContext[.school], 90)
        XCTAssertEqual(today.minutesByContext[.personal], 45)
        XCTAssertEqual(today.sessionCount, 2, "checked blocks add minutes, not starts")

        let yesterday = days[5]
        XCTAssertEqual(yesterday.minutesByContext[.personal], 20)
        XCTAssertNil(yesterday.minutesByContext[.school], "unchecked blocks contribute nothing")
        XCTAssertEqual(yesterday.sessionCount, 1)

        XCTAssertEqual(days[0].totalMinutes, 0, "untouched days stay empty")
    }

    func testWeaveExcludesCompletedBlockLinkedToTimedSession() throws {
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 45)
        block.isComplete = true
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 20 * 60,
            scheduledBlockId: block.id
        )
        context.insert(block)
        context.insert(session)
        try context.save()

        let days = WeaveBuilder.days(
            sessions: [session],
            blocks: [block],
            daysBack: 1,
            now: anchor
        )

        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day.totalMinutes, 20)
        XCTAssertEqual(day.minutesByContext[.school], 20)
        XCTAssertEqual(day.sessionCount, 1)
    }

    func testWeaveEstimateHeatIsMedianAcrossContexts() {
        makeCompletedTask(taskContext: .school, effort: 60, spent: 90)    // 1.5×
        makeCompletedTask(taskContext: .work, effort: 60, spent: 60)      // 1.0×
        makeCompletedTask(taskContext: .personal, effort: 60, spent: 120) // 2.0×
        let tasks = (try? context.fetch(FetchDescriptor<FilumaTask>())) ?? []

        let heat = WeaveBuilder.estimateHeat(tasks: tasks)
        XCTAssertEqual(heat ?? 0, 1.5, accuracy: 0.01)
    }

    func testWeaveEstimateHeatNeedsThreeSamples() {
        makeCompletedTask(effort: 60, spent: 120)
        let tasks = (try? context.fetch(FetchDescriptor<FilumaTask>())) ?? []
        XCTAssertNil(WeaveBuilder.estimateHeat(tasks: tasks))
    }

    // MARK: - Block push ("can't right now")

    func testRescheduleHonorsEarliestStart() throws {
        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 72)
        let soon = ScheduledBlock(task: task, startTime: anchor.addingTimeInterval(600), durationMinutes: 60)
        context.insert(soon)
        try context.save()

        // "Push to tomorrow": nothing may land before the requested start.
        let tomorrowWake = calendar.date(
            bySettingHour: 8, minute: 0, second: 0,
            of: calendar.date(byAdding: .day, value: 1, to: anchor)!
        )!
        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: [soon],
            settings: settings,
            from: tomorrowWake,
            context: context
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected the pushed task to fit, got \(result)")
        }
        let all = try context.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertFalse(all.isEmpty)
        for block in all {
            XCTAssertGreaterThanOrEqual(
                block.startTime, tomorrowWake,
                "a pushed plan must not sneak work back before the chosen start"
            )
        }
    }

    func testRescheduleCountsFutureLockBeforeCustomStartWithoutMovingIt() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        settings.deadlineBufferMinutes = 0
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let locked = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(60 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(3 * 3600),
            durationMinutes: 60
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()
        let customStart = anchor.addingTimeInterval(24 * 3600)

        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: [locked, movable],
            settings: settings,
            from: customStart,
            now: anchor,
            context: context
        )
        try context.save()

        guard case .success(let replacements) = result else {
            return XCTFail("expected the uncovered remainder to fit, got \(result)")
        }
        XCTAssertEqual(replacements.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(replacements.allSatisfy { $0.startTime >= customStart })
        let durable = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertTrue(durable.contains { $0.id == locked.id })
        XCTAssertFalse(durable.contains { $0.id == movable.id })
        XCTAssertEqual(durable.reduce(0) { $0 + $1.durationMinutes }, 120)
    }

    // MARK: - Plan coordinator

    @MainActor
    func testProgressReconciliationTrimsExcessFutureCoverage() throws {
        _ = makeSettings()
        let task = makeTask(effort: 180, deadlineHoursFromAnchor: 72)
        let first = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 90)
        let second = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 90
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        task.manualProgressPercent = 50
        try PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete && $0.endTime > Date()
        }
        XCTAssertEqual(task.remainingMinutes, 90)
        XCTAssertEqual(
            future.reduce(0) { $0 + $1.durationMinutes },
            task.remainingMinutes,
            "future reservations should shrink to the newly reported remainder"
        )
        XCTAssertFalse(future.contains { $0.id == first.id || $0.id == second.id })
    }

    @MainActor
    func testProgressReconciliationCountsLockedCoverageTowardRemainder() throws {
        _ = makeSettings()
        let task = makeTask(effort: 180, deadlineHoursFromAnchor: 72)
        let locked = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 120
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        task.manualProgressPercent = 50
        try PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete && $0.endTime > Date()
        }
        XCTAssertEqual(task.remainingMinutes, 90)
        XCTAssertTrue(future.contains { $0.id == locked.id })
        XCTAssertFalse(future.contains { $0.id == movable.id })
        XCTAssertEqual(future.reduce(0) { $0 + $1.durationMinutes }, 90)
        XCTAssertEqual(
            future.filter { !$0.isLocked }.reduce(0) { $0 + $1.durationMinutes },
            30,
            "only effort not already covered by the locked block should be placed"
        )
    }

    func testRescheduleCountsOnlyFutureOverlapOfInProgressLockedBlock() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 8)
        let locked = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-30 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 120
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: [locked, movable],
            settings: settings,
            from: anchor,
            now: anchor,
            context: context
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected clipped locked coverage to leave a full fit, got \(result)")
        }
        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        let replacements = blocks.filter { !$0.isLocked }
        XCTAssertTrue(blocks.contains { $0.id == locked.id })
        XCTAssertFalse(blocks.contains { $0.id == movable.id })
        XCTAssertEqual(
            replacements.reduce(0) { $0 + $1.durationMinutes },
            90,
            "only the locked block's 30 future minutes may cover the 120-minute remainder"
        )
    }

    func testRescheduleDoesNotCountLockedBlockAfterActualDeadline() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 4)
        let windowEnd = task.deadline
        let locked = ScheduledBlock(
            task: task,
            startTime: windowEnd.addingTimeInterval(60 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(30 * 60),
            durationMinutes: 60
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        let result = SchedulerService.reschedule(
            task: task,
            allBlocks: [locked, movable],
            settings: settings,
            from: anchor,
            context: context
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected replacement work before the deadline, got \(result)")
        }
        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        let replacements = blocks.filter { !$0.isLocked }
        XCTAssertTrue(blocks.contains { $0.id == locked.id }, "locks remain in place")
        XCTAssertFalse(blocks.contains { $0.id == movable.id })
        XCTAssertEqual(replacements.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(replacements.allSatisfy { $0.endTime <= windowEnd })
    }

    func testRebalanceCountsOnlyFutureOverlapOfInProgressLockedBlock() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 8)
        let locked = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-30 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 120
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        let summary = SchedulerService.rebalance(
            tasks: [task],
            allBlocks: [locked, movable],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        let replacements = blocks.filter { !$0.isLocked }
        XCTAssertEqual(summary.unschedulableTasks, 0)
        XCTAssertTrue(blocks.contains { $0.id == locked.id })
        XCTAssertFalse(blocks.contains { $0.id == movable.id })
        XCTAssertEqual(replacements.reduce(0) { $0 + $1.durationMinutes }, 90)
    }

    func testRebalanceDoesNotCountLockedBlockAfterActualDeadline() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 4)
        let windowEnd = task.deadline
        let locked = ScheduledBlock(
            task: task,
            startTime: windowEnd.addingTimeInterval(60 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(30 * 60),
            durationMinutes: 60
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        let summary = SchedulerService.rebalance(
            tasks: [task],
            allBlocks: [locked, movable],
            blockedTimes: [],
            settings: settings,
            now: anchor,
            context: context
        )
        try context.save()

        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        let replacements = blocks.filter { !$0.isLocked }
        XCTAssertEqual(summary.unschedulableTasks, 0)
        XCTAssertTrue(blocks.contains { $0.id == locked.id }, "locks remain in place")
        XCTAssertFalse(blocks.contains { $0.id == movable.id })
        XCTAssertEqual(replacements.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(replacements.allSatisfy { $0.endTime <= windowEnd })
    }

    @MainActor
    func testLinkedBlockAttendanceReconciliationRestoresUnchangedCoverage() throws {
        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let attended = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let existingFuture = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 25 * 60,
            scheduledBlockId: attended.id
        )
        context.insert(attended)
        context.insert(existingFuture)
        context.insert(session)
        try context.save()

        attended.isComplete = true
        let result = try PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        guard case .success = result else {
            return XCTFail("expected full replacement coverage, got \(result)")
        }

        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        let futureCoverage = blocks
            .filter { !$0.isComplete && $0.endTime > Date() }
            .reduce(0) { $0 + $1.durationMinutes }
        XCTAssertEqual(task.remainingMinutes, 120, "attendance alone must not imply progress")
        XCTAssertEqual(futureCoverage, task.remainingMinutes)
        XCTAssertTrue(blocks.contains { $0.id == attended.id && $0.isComplete })
        XCTAssertFalse(blocks.contains { $0.id == existingFuture.id })
    }

    @MainActor
    func testAttendanceReconciliationPublishesOnlyAfterReplacementPlanIsDurable() throws {
        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let attended = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let existingFuture = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        let sessionID = UUID()
        let session = WorkSession(
            id: sessionID,
            task: task,
            startedAt: anchor,
            durationSeconds: 25 * 60,
            scheduledBlockId: attended.id
        )
        context.insert(attended)
        context.insert(existingFuture)
        context.insert(session)
        try context.save()
        attended.isComplete = true
        try context.save()

        var finalSaveFinished = false
        var publishCount = 0
        var durableCoverageSeenDuringPublish = 0
        let result = try PlanCoordinator.reconcileTaskAfterAttendance(
            task,
            context: context,
            save: { context in
                try context.save()
                finalSaveFinished = true
            },
            publish: { _ in
                publishCount += 1
                XCTAssertTrue(finalSaveFinished)
                let fresh = ModelContext(self.container)
                durableCoverageSeenDuringPublish = ((try? fresh.fetch(
                    FetchDescriptor<ScheduledBlock>()
                )) ?? [])
                    .filter {
                        $0.task?.id == task.id
                            && !$0.isComplete
                            && $0.endTime > Date()
                    }
                    .reduce(0) { $0 + $1.durationMinutes }
            }
        )

        guard case .success = result else {
            return XCTFail("expected full replacement coverage, got \(result)")
        }
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(durableCoverageSeenDuringPublish, task.remainingMinutes)
        let verificationContext = ModelContext(container)
        let durableSessions = try verificationContext.fetch(FetchDescriptor<WorkSession>())
        XCTAssertEqual(durableSessions.map(\.id), [sessionID])
    }

    @MainActor
    func testAttendanceReconciliationFailurePreservesLoggedSessionAndPlanForSameIdentityRetry() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let attended = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let existingFuture = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        let sessionID = UUID()
        let session = WorkSession(
            id: sessionID,
            task: task,
            startedAt: anchor,
            durationSeconds: 25 * 60,
            scheduledBlockId: attended.id
        )
        let reminder = Reminder(
            title: "Earlier accepted edit",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(attended)
        context.insert(existingFuture)
        context.insert(session)
        context.insert(reminder)
        try context.save()

        // These mirror recordSession's already-durable attendance boundary;
        // the unrelated edit arrives before reconciliation's preflight.
        attended.isComplete = true
        try context.save()
        reminder.isComplete = true
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.reconcileTaskAfterAttendance(
                task,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(attended.isComplete)
        XCTAssertEqual(Set(task.scheduledBlocks.map(\.id)), Set([attended.id, existingFuture.id]))

        var verificationContext = ModelContext(container)
        var durableSessions = try verificationContext.fetch(FetchDescriptor<WorkSession>())
        var durableBlocks = try verificationContext.fetch(FetchDescriptor<ScheduledBlock>())
            .filter { $0.task?.id == task.id }
        let durableReminder = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<Reminder>()).first {
                $0.id == reminder.id
            }
        )
        XCTAssertEqual(durableSessions.map(\.id), [sessionID])
        XCTAssertTrue(durableBlocks.contains { $0.id == attended.id && $0.isComplete })
        XCTAssertTrue(durableBlocks.contains { $0.id == existingFuture.id && !$0.isComplete })
        XCTAssertTrue(durableReminder.isComplete)

        // A later End tap reuses the retained WorkSession identity and retries
        // only the plan. Its longer elapsed time updates that row; the
        // successful retry still leaves exactly one attendance record.
        session.durationSeconds = 30 * 60
        try context.save()
        _ = try PlanCoordinator.reconcileTaskAfterAttendance(
            task,
            context: context,
            publish: { _ in publishCount += 1 }
        )
        XCTAssertEqual(publishCount, 1)
        verificationContext = ModelContext(container)
        durableSessions = try verificationContext.fetch(FetchDescriptor<WorkSession>())
        durableBlocks = try verificationContext.fetch(FetchDescriptor<ScheduledBlock>())
            .filter { $0.task?.id == task.id }
        XCTAssertEqual(durableSessions.map(\.id), [sessionID])
        XCTAssertEqual(durableSessions.first?.durationSeconds, 30 * 60)
        XCTAssertEqual(
            durableBlocks
                .filter { !$0.isComplete && $0.endTime > Date() }
                .reduce(0) { $0 + $1.durationMinutes },
            task.remainingMinutes
        )
    }

    @MainActor
    func testUncheckingAttendedBlockReconciliationAvoidsDuplicateCoverage() throws {
        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let attended = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let existingFuture = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        context.insert(attended)
        context.insert(existingFuture)
        try context.save()

        attended.isComplete = true
        try PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        attended.isComplete = false
        try PlanCoordinator.reconcileTaskAfterProgress(
            task,
            context: context,
            interactive: false
        )
        try context.save()

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete && $0.endTime > Date()
        }
        let futureCoverage = future.reduce(0) { $0 + $1.durationMinutes }

        XCTAssertEqual(task.remainingMinutes, 120, "attendance changes must not imply progress")
        XCTAssertEqual(
            futureCoverage,
            task.remainingMinutes,
            "undoing attendance must replace, not stack on, the reconciled coverage"
        )
        XCTAssertNotEqual(futureCoverage, task.remainingMinutes + attended.durationMinutes)
        XCTAssertFalse(future.contains { $0.id == attended.id })
    }

    @MainActor
    func testExplicitRescheduleReturnsTotalDurableCoverageAfterSave() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        settings.deadlineBufferMinutes = 0
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 72)
        let locked = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(60 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(3 * 3600),
            durationMinutes: 60
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()
        let customStart = anchor.addingTimeInterval(24 * 3600)
        var finalSaveFinished = false
        var publishCount = 0
        var durableCoverageDuringPublish = 0

        let result = try PlanCoordinator.rescheduleTask(
            task,
            context: context,
            from: customStart,
            now: anchor,
            interactive: false,
            save: { context in
                try context.save()
                finalSaveFinished = true
            },
            publish: { _, _ in
                publishCount += 1
                XCTAssertTrue(finalSaveFinished)
                let fresh = ModelContext(self.container)
                durableCoverageDuringPublish = ((try? fresh.fetch(
                    FetchDescriptor<ScheduledBlock>()
                )) ?? [])
                    .filter { $0.task?.id == task.id && !$0.isComplete }
                    .reduce(0) { $0 + $1.durationMinutes }
            }
        )

        guard case .success(let durableCoverage) = result else {
            return XCTFail("expected complete durable coverage, got \(result)")
        }
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(durableCoverageDuringPublish, 120)
        XCTAssertEqual(durableCoverage.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertTrue(durableCoverage.contains { $0.id == locked.id })
        XCTAssertTrue(durableCoverage.filter { !$0.isLocked }.allSatisfy {
            $0.startTime >= customStart
        })
    }

    @MainActor
    func testExplicitRescheduleFailureRestoresHeldAndDurableGraphsWithoutPublish() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 90, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 90)
        let reminder = Reminder(
            title: "Earlier accepted edit",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(original)
        context.insert(reminder)
        try context.save()
        reminder.isComplete = true
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.rescheduleTask(
                task,
                context: context,
                now: anchor,
                interactive: false,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [original.id])
        XCTAssertEqual(original.task?.id, task.id)
        let fresh = ModelContext(container)
        let durableBlocks = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        let durableReminder = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<Reminder>()).first { $0.id == reminder.id }
        )
        XCTAssertEqual(durableBlocks.map(\.id), [original.id])
        XCTAssertTrue(durableReminder.isComplete)
    }

    @MainActor
    func testBlockCompletionFailureRestoresToggleAndPlanWithoutPublish() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let toggled = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let future = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        context.insert(toggled)
        context.insert(future)
        try context.save()
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.setBlockCompletion(
                toggled,
                isComplete: true,
                context: context,
                now: anchor,
                interactive: false,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertFalse(toggled.isComplete)
        XCTAssertEqual(Set(task.scheduledBlocks.map(\.id)), Set([toggled.id, future.id]))
        XCTAssertEqual(toggled.task?.id, task.id)
        let fresh = ModelContext(container)
        let durableBlocks = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        XCTAssertEqual(Set(durableBlocks.map(\.id)), Set([toggled.id, future.id]))
        XCTAssertTrue(durableBlocks.allSatisfy { !$0.isComplete })
    }

    @MainActor
    func testTaskDeleteFailureRestoresChildrenAndRetryPublishesOnlyAfterCommit() throws {
        enum ExpectedFailure: Error { case save }

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 15 * 60,
            scheduledBlockId: block.id
        )
        let reminder = Reminder(
            title: "Earlier accepted edit",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(block)
        context.insert(session)
        context.insert(reminder)
        try context.save()
        reminder.isComplete = true
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.deleteTask(
                task,
                context: context,
                interactive: false,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [block.id])
        XCTAssertEqual(task.workSessions.map(\.id), [session.id])
        XCTAssertEqual(block.task?.id, task.id)
        XCTAssertEqual(session.task?.id, task.id)
        var fresh = ModelContext(container)
        XCTAssertNotNil(try fresh.fetch(FetchDescriptor<FilumaTask>()).first {
            $0.id == task.id
        })
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [block.id])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<WorkSession>()).map(\.id), [session.id])
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<Reminder>()).first { $0.id == reminder.id }
        ).isComplete)

        var finalSaveFinished = false
        try PlanCoordinator.deleteTask(
            task,
            context: context,
            interactive: false,
            save: { context in
                try context.save()
                finalSaveFinished = true
            },
            publish: { _, _ in
                publishCount += 1
                XCTAssertTrue(finalSaveFinished)
                let verification = ModelContext(self.container)
                XCTAssertFalse(((try? verification.fetch(
                    FetchDescriptor<FilumaTask>()
                )) ?? []).contains { $0.id == task.id })
                XCTAssertFalse(((try? verification.fetch(
                    FetchDescriptor<ScheduledBlock>()
                )) ?? []).contains { $0.id == block.id })
                XCTAssertFalse(((try? verification.fetch(
                    FetchDescriptor<WorkSession>()
                )) ?? []).contains { $0.id == session.id })
            }
        )

        XCTAssertEqual(publishCount, 1)
        fresh = ModelContext(container)
        XCTAssertFalse(try fresh.fetch(FetchDescriptor<FilumaTask>()).contains {
            $0.id == task.id
        })
        XCTAssertFalse(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).contains {
            $0.id == block.id
        })
        XCTAssertFalse(try fresh.fetch(FetchDescriptor<WorkSession>()).contains {
            $0.id == session.id
        })
    }

    @MainActor
    func testPlanningPreferenceRebuildCountsLockedCoverageTowardRemainder() throws {
        let settings = makeSettings()
        settings.minBlockMinutes = 15
        settings.planningRebuildPending = true
        let task = makeTask(effort: 180, deadlineHoursFromAnchor: 72)
        task.manualProgressPercent = 50
        let locked = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        locked.isLocked = true
        let movable = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 120
        )
        context.insert(locked)
        context.insert(movable)
        try context.save()

        try PlanCoordinator.rebuildAfterPlanningPreferencesChange(
            context: context,
            interactive: false
        )
        try context.save()

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete && $0.endTime > Date()
        }
        XCTAssertEqual(task.remainingMinutes, 90)
        XCTAssertTrue(future.contains { $0.id == locked.id })
        XCTAssertFalse(future.contains { $0.id == movable.id })
        XCTAssertEqual(future.reduce(0) { $0 + $1.durationMinutes }, 90)
        XCTAssertEqual(future.filter { !$0.isLocked }.reduce(0) { $0 + $1.durationMinutes }, 30)
        XCTAssertFalse(settings.planningRebuildPending)
    }

    @MainActor
    func testPlanningPreferenceRebuildFailureKeepsDurablePlanAndDoesNotPublish() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(
            task: task,
            startTime: anchor,
            durationMinutes: 60
        )
        context.insert(original)
        try context.save()

        // Mirrors the Settings UI: the chosen preference is accepted before
        // the derived plan rebuild begins.
        settings.minBlockMinutes = 15
        settings.planningRebuildPending = true
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.rebuildAfterPlanningPreferencesChange(
                context: context,
                interactive: false,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(settings.minBlockMinutes, 15)
        XCTAssertTrue(settings.planningRebuildPending)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [original.id])
        let fresh = ModelContext(container)
        XCTAssertEqual(
            try fresh.fetch(FetchDescriptor<UserSettings>()).first?.minBlockMinutes,
            15
        )
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).planningRebuildPending)
        let durable = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        XCTAssertEqual(durable.map(\.id), [original.id])
    }

    @MainActor
    func testAppleImportFetchFailureLeavesExistingMirrorUntouched() throws {
        enum ExpectedFailure: Error { case fetch }

        let settings = makeSettings()
        settings.importFromAppleCalendar = true
        let existing = BusyEvent(
            source: .appleCalendar,
            sourceId: "apple-existing",
            title: "Existing class",
            startTime: anchor,
            endTime: anchor.addingTimeInterval(3600)
        )
        context.insert(existing)
        try context.save()
        CalendarImportService.loadBusyEvents = { _ in
            throw ExpectedFailure.fetch
        }
        defer {
            CalendarImportService.loadBusyEvents = {
                try $0.fetch(FetchDescriptor<BusyEvent>())
            }
        }

        XCTAssertThrowsError(
            try CalendarImportService.syncNow(
                context: context,
                settings: settings
            )
        )

        XCTAssertEqual(settings.importFromAppleCalendar, true)
        let durable = try ModelContext(container).fetch(FetchDescriptor<BusyEvent>())
        XCTAssertEqual(durable.map(\.id), [existing.id])
    }

    @MainActor
    func testAppleImportEnableFailureKeepsToggleAndMirrorUndurableUntilRetry() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        try context.save()
        let transient = BusyEvent(
            source: .appleCalendar,
            sourceId: "apple-enable-transient",
            title: "New class",
            startTime: anchor,
            endTime: anchor.addingTimeInterval(3600)
        )

        XCTAssertThrowsError(
            try CalendarImportService.enableImport(
                settings: settings,
                context: context,
                sync: { context, _ in context.insert(transient) },
                save: { _ in throw ExpectedFailure.save }
            )
        )

        XCTAssertFalse(settings.importFromAppleCalendar)
        XCTAssertTrue(try context.fetch(FetchDescriptor<BusyEvent>()).isEmpty)
        var fresh = ModelContext(container)
        XCTAssertFalse(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).importFromAppleCalendar)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<BusyEvent>()).isEmpty)

        var durableEventID: UUID?
        try CalendarImportService.enableImport(
            settings: settings,
            context: context,
            sync: { context, _ in
                let event = BusyEvent(
                    source: .appleCalendar,
                    sourceId: "apple-enable-durable",
                    title: "New class",
                    startTime: self.anchor,
                    endTime: self.anchor.addingTimeInterval(3600)
                )
                durableEventID = event.id
                context.insert(event)
            }
        )

        XCTAssertTrue(settings.importFromAppleCalendar)
        fresh = ModelContext(container)
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).importFromAppleCalendar)
        XCTAssertEqual(
            try fresh.fetch(FetchDescriptor<BusyEvent>()).map(\.id),
            [try XCTUnwrap(durableEventID)]
        )
    }

    @MainActor
    func testAppleImportDisableFailureKeepsPreferenceAndMirrorForRetry() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        settings.importFromAppleCalendar = true
        let existing = BusyEvent(
            source: .appleCalendar,
            sourceId: "apple-disable-existing",
            title: "Existing class",
            startTime: anchor,
            endTime: anchor.addingTimeInterval(3600)
        )
        context.insert(existing)
        try context.save()

        XCTAssertThrowsError(
            try CalendarImportService.disableImport(
                settings: settings,
                context: context,
                save: { _ in throw ExpectedFailure.save }
            )
        )

        XCTAssertTrue(settings.importFromAppleCalendar)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<BusyEvent>()).map(\.id),
            [existing.id]
        )
        var fresh = ModelContext(container)
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).importFromAppleCalendar)
        XCTAssertEqual(
            try fresh.fetch(FetchDescriptor<BusyEvent>()).map(\.id),
            [existing.id]
        )

        try CalendarImportService.disableImport(
            settings: settings,
            context: context
        )
        fresh = ModelContext(container)
        XCTAssertFalse(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).importFromAppleCalendar)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<BusyEvent>()).isEmpty)
    }

    @MainActor
    func testAppleCalendarExclusionFailureKeepsChoiceAndMirrorTogetherForRetry() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        settings.importFromAppleCalendar = true
        let existing = BusyEvent(
            source: .appleCalendar,
            sourceId: "apple-family-existing",
            title: "Family calendar",
            startTime: anchor,
            endTime: anchor.addingTimeInterval(3600),
            calendarName: "Family"
        )
        context.insert(existing)
        try context.save()
        let transient = BusyEvent(
            source: .appleCalendar,
            sourceId: "apple-transient",
            title: "Transient",
            startTime: anchor.addingTimeInterval(7200),
            endTime: anchor.addingTimeInterval(10_800)
        )

        XCTAssertThrowsError(
            try CalendarImportService.updateExcludedCalendars(
                ["family-calendar"],
                settings: settings,
                context: context,
                sync: { context, _ in
                    existing.title = "Changed before rejected save"
                    context.delete(existing)
                    context.insert(transient)
                },
                save: { _ in throw ExpectedFailure.save }
            )
        )

        XCTAssertEqual(settings.excludedCalendarIds, [])
        XCTAssertEqual(existing.title, "Family calendar")
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<BusyEvent>()).map(\.id),
            [existing.id]
        )
        var fresh = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(fresh.fetch(FetchDescriptor<UserSettings>()).first)
                .excludedCalendarIds,
            []
        )
        XCTAssertEqual(
            try fresh.fetch(FetchDescriptor<BusyEvent>()).map(\.id),
            [existing.id]
        )

        var replacementID: UUID?
        try CalendarImportService.updateExcludedCalendars(
            ["work-calendar", "family-calendar", "family-calendar"],
            settings: settings,
            context: context,
            sync: { context, _ in
                context.delete(existing)
                let replacement = BusyEvent(
                    source: .appleCalendar,
                    sourceId: "apple-work-kept",
                    title: "Work calendar",
                    startTime: self.anchor.addingTimeInterval(7200),
                    endTime: self.anchor.addingTimeInterval(10_800),
                    calendarName: "Work"
                )
                replacementID = replacement.id
                context.insert(replacement)
            }
        )

        XCTAssertEqual(
            settings.excludedCalendarIds,
            ["family-calendar", "work-calendar"]
        )
        fresh = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(fresh.fetch(FetchDescriptor<UserSettings>()).first)
                .excludedCalendarIds,
            ["family-calendar", "work-calendar"]
        )
        XCTAssertEqual(
            try fresh.fetch(FetchDescriptor<BusyEvent>()).map(\.id),
            [try XCTUnwrap(replacementID)]
        )
    }

    @MainActor
    func testTaskEditAtomicallyPersistsDetailsWithoutReplanning() throws {
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        task.firstStep = "Open the notes"
        try context.save()
        var publishCount = 0

        let result = try PlanCoordinator.saveTaskEdits(
            task,
            update: TaskEditUpdate(
                title: "  Revised task  ",
                firstStep: "  Draft the opening  ",
                taskContext: .work,
                deadline: task.deadline,
                effortMinutes: task.effortMinutes
            ),
            context: context,
            publish: { _ in publishCount += 1 }
        )

        XCTAssertNil(result)
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(task.title, "Revised task")
        XCTAssertEqual(task.firstStep, "Draft the opening")
        XCTAssertEqual(task.context, .work)
        XCTAssertTrue(task.userModified)

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        XCTAssertEqual(durableTask.title, "Revised task")
        XCTAssertEqual(durableTask.firstStep, "Draft the opening")
        XCTAssertEqual(durableTask.context, .work)
        XCTAssertTrue(durableTask.userModified)
    }

    @MainActor
    func testTaskEditAtomicallyPersistsDetailsAndReplacementPlan() throws {
        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        context.insert(original)
        try context.save()
        let revisedDeadline = task.deadline.addingTimeInterval(24 * 3600)

        let result = try PlanCoordinator.saveTaskEdits(
            task,
            update: TaskEditUpdate(
                title: "Expanded task",
                firstStep: nil,
                taskContext: .personal,
                deadline: revisedDeadline,
                effortMinutes: 120
            ),
            context: context,
            publish: { _ in }
        )

        guard let result, case .success(let replacementBlocks) = result else {
            return XCTFail("expected full replacement coverage, got \(String(describing: result))")
        }
        XCTAssertEqual(task.title, "Expanded task")
        XCTAssertEqual(task.context, .personal)
        XCTAssertEqual(task.deadline, revisedDeadline)
        XCTAssertEqual(task.effortMinutes, 120)
        XCTAssertEqual(replacementBlocks.reduce(0) { $0 + $1.durationMinutes }, 120)

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        let durableBlocks = try verificationContext
            .fetch(FetchDescriptor<ScheduledBlock>())
            .filter { $0.task?.id == task.id && !$0.isComplete }
        XCTAssertEqual(durableTask.title, "Expanded task")
        XCTAssertEqual(durableTask.context, .personal)
        XCTAssertEqual(durableTask.deadline, revisedDeadline)
        XCTAssertEqual(durableTask.effortMinutes, 120)
        XCTAssertEqual(durableBlocks.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertFalse(durableBlocks.contains { $0.id == original.id })
    }

    @MainActor
    func testTaskEditResultIncludesRetainedLockedCoverage() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        settings.deadlineBufferMinutes = 0
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let locked = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        locked.isLocked = true
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "task-edit-locked-coverage",
            title: "No other room",
            startTime: Date().addingTimeInterval(-3600),
            endTime: task.deadline.addingTimeInterval(24 * 3600)
        )
        context.insert(locked)
        context.insert(busy)
        try context.save()

        let result = try PlanCoordinator.saveTaskEdits(
            task,
            update: TaskEditUpdate(
                title: task.title,
                firstStep: nil,
                taskContext: task.context,
                deadline: task.deadline,
                effortMinutes: 120
            ),
            context: context,
            publish: { _ in }
        )

        guard let result,
              case .partialFit(let scheduled, let unscheduledMinutes) = result else {
            return XCTFail("expected retained coverage plus a shortfall, got \(String(describing: result))")
        }
        XCTAssertEqual(scheduled.map(\.id), [locked.id])
        XCTAssertEqual(scheduled.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertEqual(unscheduledMinutes, 60)
        XCTAssertTrue(locked.isLocked)
    }

    @MainActor
    func testTaskEditCreditsOnlyUsableOverlapOfInProgressRetainedLock() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        settings.deadlineBufferMinutes = 0
        let task = makeTask(effort: 30, deadlineHoursFromAnchor: 1)
        let locked = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-50 * 60),
            durationMinutes: 60
        )
        locked.isLocked = true
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "task-edit-clipped-lock",
            title: "No replacement room",
            startTime: anchor,
            endTime: task.deadline
        )
        context.insert(locked)
        context.insert(busy)
        try context.save()

        let result = try PlanCoordinator.saveTaskEdits(
            task,
            update: TaskEditUpdate(
                title: task.title,
                firstStep: nil,
                taskContext: task.context,
                deadline: task.deadline,
                effortMinutes: 60
            ),
            context: context,
            now: anchor,
            publish: { _ in }
        )

        guard let result,
              case .partialFit(let scheduled, let unscheduledMinutes) = result else {
            return XCTFail("expected clipped retained coverage, got \(String(describing: result))")
        }
        XCTAssertEqual(scheduled.map(\.id), [locked.id])
        XCTAssertEqual(scheduled.first?.durationMinutes, 60)
        XCTAssertEqual(unscheduledMinutes, 50)
        XCTAssertEqual(
            task.remainingMinutes - unscheduledMinutes,
            10,
            "Feedback must credit only the retained row's usable overlap after now."
        )
    }

    @MainActor
    func testTaskEditFailureDoesNotLeakNewDefaultSettings() throws {
        enum ExpectedFailure: Error { case save }

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<UserSettings>()).isEmpty)

        XCTAssertThrowsError(
            try PlanCoordinator.saveTaskEdits(
                task,
                update: TaskEditUpdate(
                    title: task.title,
                    firstStep: nil,
                    taskContext: task.context,
                    deadline: task.deadline.addingTimeInterval(24 * 3600),
                    effortMinutes: task.effortMinutes
                ),
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _ in XCTFail("failed edits must not publish") }
            )
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<UserSettings>()).isEmpty)
        let verificationContext = ModelContext(container)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<UserSettings>()).isEmpty)
    }

    @MainActor
    func testTaskEditSaveFailureRestoresHeldAndDurableTaskAndPlan() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        task.firstStep = "Open the notes"
        let originalDeadline = task.deadline
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        context.insert(original)
        try context.save()
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.saveTaskEdits(
                task,
                update: TaskEditUpdate(
                    title: "Rejected edit",
                    firstStep: "Rejected step",
                    taskContext: .work,
                    deadline: originalDeadline.addingTimeInterval(24 * 3600),
                    effortMinutes: 120
                ),
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(task.title, "Test task")
        XCTAssertEqual(task.firstStep, "Open the notes")
        XCTAssertEqual(task.context, .school)
        XCTAssertEqual(task.deadline, originalDeadline)
        XCTAssertEqual(task.effortMinutes, 60)
        XCTAssertFalse(task.userModified)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [original.id])

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        let durableBlocks = try verificationContext
            .fetch(FetchDescriptor<ScheduledBlock>())
            .filter { $0.task?.id == task.id }
        XCTAssertEqual(durableTask.title, "Test task")
        XCTAssertEqual(durableTask.firstStep, "Open the notes")
        XCTAssertEqual(durableTask.context, .school)
        XCTAssertEqual(durableTask.deadline, originalDeadline)
        XCTAssertEqual(durableTask.effortMinutes, 60)
        XCTAssertFalse(durableTask.userModified)
        XCTAssertEqual(durableBlocks.map(\.id), [original.id])
    }

    @MainActor
    func testTaskEditFailurePreservesEarlierPendingChanges() throws {
        enum ExpectedFailure: Error { case save }

        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let reminder = Reminder(
            title: "Take meds",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(reminder)
        try context.save()

        reminder.isComplete = true
        XCTAssertThrowsError(
            try PlanCoordinator.saveTaskEdits(
                task,
                update: TaskEditUpdate(
                    title: "Rejected edit",
                    firstStep: nil,
                    taskContext: .school,
                    deadline: task.deadline,
                    effortMinutes: task.effortMinutes
                ),
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _ in XCTFail("failed edits must not publish") }
            )
        )

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        let durableReminder = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<Reminder>()).first {
                $0.id == reminder.id
            }
        )
        XCTAssertEqual(durableTask.title, "Test task")
        XCTAssertTrue(durableReminder.isComplete)
    }

    @MainActor
    func testTaskEditRejectsDeadlineThatBecamePastBeforeSave() throws {
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        try context.save()
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.saveTaskEdits(
                task,
                update: TaskEditUpdate(
                    title: "Should not save",
                    firstStep: nil,
                    taskContext: .work,
                    deadline: anchor,
                    effortMinutes: 120
                ),
                context: context,
                now: anchor.addingTimeInterval(1),
                publish: { _ in publishCount += 1 }
            )
        ) { error in
            XCTAssertEqual(error as? TaskEditCoordinatorError, .deadlineNotFuture)
        }

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(task.title, "Test task")
        XCTAssertEqual(task.context, .school)
        XCTAssertEqual(task.effortMinutes, 60)
        let durable = ModelContext(container)
        let durableTask = try XCTUnwrap(
            durable.fetch(FetchDescriptor<FilumaTask>()).first { $0.id == task.id }
        )
        XCTAssertEqual(durableTask.title, "Test task")
        XCTAssertEqual(durableTask.effortMinutes, 60)
    }

    @MainActor
    func testPartialProgressSuccessReplansCoverageForSmallerRemainder() throws {
        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 120)
        context.insert(original)
        try context.save()

        let result = try PlanCoordinator.savePartialProgress(
            task,
            reportedProgress: 50,
            context: context,
            interactive: false
        )

        guard case .success(let replacementBlocks) = result else {
            return XCTFail("expected full replacement coverage, got \(result)")
        }
        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertEqual(task.manualProgressPercent, 50)
        XCTAssertEqual(task.remainingMinutes, 60)
        XCTAssertEqual(replacementBlocks.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertEqual(future.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertFalse(future.contains { $0.id == original.id })
    }

    @MainActor
    func testPartialProgressClampsBelowCompletion() throws {
        _ = makeSettings()
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 100)
        context.insert(original)
        try context.save()

        _ = try PlanCoordinator.savePartialProgress(
            task,
            reportedProgress: 140,
            context: context,
            interactive: false
        )

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertEqual(task.manualProgressPercent, 99)
        XCTAssertFalse(task.isComplete)
        XCTAssertEqual(task.remainingMinutes, 1)
        XCTAssertEqual(future.reduce(0) { $0 + $1.durationMinutes }, 1)
    }

    @MainActor
    func testPartialProgressNeverMovesBackward() throws {
        _ = makeSettings()
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        task.manualProgressPercent = 70
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 30)
        context.insert(original)
        try context.save()

        _ = try PlanCoordinator.savePartialProgress(
            task,
            reportedProgress: 35,
            context: context,
            interactive: false
        )

        let future = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertEqual(task.manualProgressPercent, 70)
        XCTAssertEqual(task.remainingMinutes, 30)
        XCTAssertEqual(future.reduce(0) { $0 + $1.durationMinutes }, 30)
    }

    @MainActor
    func testPartialProgressSaveFailureRestoresHeldAndDurablePlan() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        task.manualProgressPercent = 20
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 80)
        context.insert(original)
        try context.save()

        XCTAssertThrowsError(
            try PlanCoordinator.savePartialProgress(
                task,
                reportedProgress: 60,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                interactive: false
            )
        )

        XCTAssertEqual(task.manualProgressPercent, 20)
        XCTAssertFalse(task.isComplete)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [original.id])

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        let durableBlocks = try verificationContext
            .fetch(FetchDescriptor<ScheduledBlock>())
            .filter { $0.task?.id == task.id }
        XCTAssertEqual(durableTask.manualProgressPercent, 20)
        XCTAssertFalse(durableTask.isComplete)
        XCTAssertEqual(durableBlocks.map(\.id), [original.id])
    }

    @MainActor
    func testPartialProgressFailurePreservesEarlierPendingChanges() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 100, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 100)
        let reminder = Reminder(
            title: "Take meds",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(original)
        context.insert(reminder)
        try context.save()

        reminder.isComplete = true
        XCTAssertThrowsError(
            try PlanCoordinator.savePartialProgress(
                task,
                reportedProgress: 50,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                interactive: false
            )
        )

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        let durableReminder = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<Reminder>()).first {
                $0.id == reminder.id
            }
        )
        let durableBlocks = try verificationContext
            .fetch(FetchDescriptor<ScheduledBlock>())
            .filter { $0.task?.id == task.id }
        XCTAssertTrue(durableReminder.isComplete)
        XCTAssertEqual(durableTask.manualProgressPercent, 0)
        XCTAssertEqual(durableBlocks.map(\.id), [original.id])
    }

    @MainActor
    func testCompletionReleasesIncompleteLockedBlocks() throws {
        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let locked = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        locked.isLocked = true
        context.insert(locked)
        try context.save()

        try PlanCoordinator.completeTask(task, context: context, interactive: false)

        let surviving = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertTrue(task.isComplete)
        XCTAssertTrue(surviving.isEmpty, "explicit completion must release locked reservations")
    }

    @MainActor
    func testCompletionAtomicallyPersistsReportedProgressAndReceipt() throws {
        _ = makeSettings()
        let task = makeTask(effort: 90, deadlineHoursFromAnchor: 48)
        task.manualProgressPercent = 35
        let future = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let completionDate = anchor.addingTimeInterval(6 * 3600)
        context.insert(future)
        try context.save()

        let receipt = try PlanCoordinator.completeTask(
            task,
            context: context,
            reportedProgress: 100,
            completedAt: completionDate,
            interactive: false
        )

        let persisted = try XCTUnwrap(
            context.fetch(FetchDescriptor<FilumaTask>()).first { $0.id == task.id }
        )
        let remainingBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        XCTAssertTrue(persisted.isComplete)
        XCTAssertEqual(persisted.manualProgressPercent, 100)
        XCTAssertEqual(persisted.completedAt, completionDate)
        XCTAssertTrue(remainingBlocks.isEmpty)
        XCTAssertEqual(receipt.taskID, task.id)
        XCTAssertEqual(receipt.completedAt, completionDate)
        XCTAssertEqual(receipt.title, task.title)
    }

    @MainActor
    func testCompletionPreservesAttendanceAndAvoidsDoubleCountingReceiptTime() throws {
        _ = makeSettings()
        let task = makeTask(effort: 120, deadlineHoursFromAnchor: 48)
        let attended = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 30)
        attended.isComplete = true
        let future = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(2 * 3600),
            durationMinutes: 60
        )
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 25 * 60,
            scheduledBlockId: attended.id
        )
        context.insert(attended)
        context.insert(future)
        context.insert(session)
        try context.save()

        let receipt = try PlanCoordinator.completeTask(
            task,
            context: context,
            completedAt: anchor.addingTimeInterval(3600),
            interactive: false
        )

        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        let sessions = try context.fetch(FetchDescriptor<WorkSession>()).filter {
            $0.task?.id == task.id
        }
        XCTAssertEqual(blocks.map(\.id), [attended.id])
        XCTAssertEqual(sessions.map(\.id), [session.id])
        XCTAssertEqual(receipt.timeSpentMinutes, 25)
    }

    @MainActor
    func testCompletionIsIdempotentAndPreservesOriginalTimestamp() throws {
        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        try context.save()
        let originalDate = anchor.addingTimeInterval(2 * 3600)
        let laterDate = originalDate.addingTimeInterval(5 * 3600)

        let first = try PlanCoordinator.completeTask(
            task,
            context: context,
            completedAt: originalDate,
            interactive: false
        )
        let second = try PlanCoordinator.completeTask(
            task,
            context: context,
            reportedProgress: 100,
            completedAt: laterDate,
            interactive: false
        )

        XCTAssertEqual(task.completedAt, originalDate)
        XCTAssertEqual(first.completedAt, originalDate)
        XCTAssertEqual(second.completedAt, originalDate)
    }

    @MainActor
    func testCompletionSaveFailureRollsBackTaskAndReservations() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let future = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        context.insert(future)
        try context.save()

        XCTAssertThrowsError(
            try PlanCoordinator.completeTask(
                task,
                context: context,
                reportedProgress: 100,
                save: { _ in throw ExpectedFailure.save },
                interactive: false
            )
        )

        XCTAssertFalse(task.isComplete)
        XCTAssertNil(task.completedAt)
        XCTAssertEqual(task.manualProgressPercent, 0)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [future.id])

        let persisted = try XCTUnwrap(
            context.fetch(FetchDescriptor<FilumaTask>()).first { $0.id == task.id }
        )
        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        XCTAssertFalse(persisted.isComplete)
        XCTAssertNil(persisted.completedAt)
        XCTAssertEqual(persisted.manualProgressPercent, 0)
        XCTAssertEqual(blocks.map(\.id), [future.id])

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        let durableBlocks = try verificationContext
            .fetch(FetchDescriptor<ScheduledBlock>())
            .filter { $0.task?.id == task.id }
        XCTAssertFalse(durableTask.isComplete)
        XCTAssertEqual(durableTask.manualProgressPercent, 0)
        XCTAssertEqual(durableBlocks.map(\.id), [future.id])
    }

    @MainActor
    func testCompletionFailurePreservesEarlierPendingChanges() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let reminder = Reminder(
            title: "Take meds",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(reminder)
        try context.save()

        // Completion's rollback must not reach behind its own transaction and
        // reactivate an unrelated reminder the user already checked.
        reminder.isComplete = true
        XCTAssertThrowsError(
            try PlanCoordinator.completeTask(
                task,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                interactive: false
            )
        )

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        let durableReminder = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<Reminder>()).first {
                $0.id == reminder.id
            }
        )
        XCTAssertFalse(durableTask.isComplete)
        XCTAssertTrue(durableReminder.isComplete)
    }

    @MainActor
    func testRestoreAfterHundredPercentReopensAdjustableProgress() throws {
        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        try context.save()
        try PlanCoordinator.completeTask(
            task,
            context: context,
            reportedProgress: 100,
            interactive: false
        )

        _ = try PlanCoordinator.restoreTask(task, context: context, interactive: false)

        XCTAssertFalse(task.isComplete)
        XCTAssertNil(task.completedAt)
        XCTAssertEqual(task.manualProgressPercent, 90)
        XCTAssertEqual(task.remainingMinutes, 6)
    }

    @MainActor
    func testRestoreSaveFailureKeepsTaskDurablyCompleted() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        try context.save()
        let completedAt = anchor.addingTimeInterval(3600)
        try PlanCoordinator.completeTask(
            task,
            context: context,
            reportedProgress: 100,
            completedAt: completedAt,
            interactive: false
        )

        XCTAssertThrowsError(
            try PlanCoordinator.restoreTask(
                task,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                interactive: false
            )
        )

        XCTAssertTrue(task.isComplete)
        XCTAssertEqual(task.completedAt, completedAt)
        XCTAssertEqual(task.manualProgressPercent, 100)

        let verificationContext = ModelContext(container)
        let durableTask = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<FilumaTask>()).first {
                $0.id == task.id
            }
        )
        let durableBlocks = try verificationContext
            .fetch(FetchDescriptor<ScheduledBlock>())
            .filter { $0.task?.id == task.id }
        XCTAssertTrue(durableTask.isComplete)
        XCTAssertEqual(durableTask.completedAt, completedAt)
        XCTAssertEqual(durableTask.manualProgressPercent, 100)
        XCTAssertTrue(durableBlocks.isEmpty)
    }

    func testCompletionReceiptUsesCommittedTimestampForDeadlineCopy() {
        let deadline = anchor.addingTimeInterval(48 * 3600)
        let early = TaskCompletionReceipt(
            taskID: UUID(),
            title: "Early",
            context: .school,
            deadline: deadline,
            completedAt: deadline.addingTimeInterval(-3 * 3600),
            timeSpentMinutes: 0
        )
        let overdue = TaskCompletionReceipt(
            taskID: UUID(),
            title: "Overdue",
            context: .work,
            deadline: deadline,
            completedAt: deadline.addingTimeInterval(90 * 60),
            timeSpentMinutes: 0
        )
        let exact = TaskCompletionReceipt(
            taskID: UUID(),
            title: "Exact",
            context: .personal,
            deadline: deadline,
            completedAt: deadline,
            timeSpentMinutes: 0
        )

        XCTAssertEqual(early.deadlineSummary, "3h to spare")
        XCTAssertEqual(overdue.deadlineSummary, "1h after deadline")
        XCTAssertEqual(exact.deadlineSummary, "at deadline")
        XCTAssertFalse(overdue.deadlineSummary.contains("wire"))
    }

    @MainActor
    func testBusyTimeReconciliationMovesConflictingBlock() throws {
        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "coordinator-conflict",
            title: "New meeting",
            startTime: original.startTime,
            endTime: original.endTime
        )
        context.insert(original)
        context.insert(busy)
        try context.save()
        var finalSaveFinished = false
        var publishCount = 0

        let replanned = try PlanCoordinator.replanBusyTimeConflicts(
            context: context,
            now: anchor,
            activeWorkSession: nil,
            interactive: false,
            save: { context in
                try context.save()
                finalSaveFinished = true
            },
            publish: { _, _ in
                publishCount += 1
                XCTAssertTrue(finalSaveFinished)
                let fresh = ModelContext(self.container)
                let durable = ((try? fresh.fetch(FetchDescriptor<ScheduledBlock>())) ?? [])
                    .filter { $0.task?.id == task.id && !$0.isComplete }
                XCTAssertTrue(durable.allSatisfy {
                    $0.startTime >= busy.endTime || $0.endTime <= busy.startTime
                })
            }
        )

        let replacements = try context.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertEqual(replanned, 1)
        XCTAssertEqual(publishCount, 1)
        XCTAssertFalse(replacements.isEmpty)
        XCTAssertFalse(replacements.contains { $0.id == original.id })
        XCTAssertTrue(replacements.allSatisfy {
            $0.startTime >= busy.endTime || $0.endTime <= busy.startTime
        })
    }

    @MainActor
    func testBusyTimeReplanFailureRestoresHeldAndDurablePlanWithoutPublish() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        let busy = BusyEvent(
            source: .appleCalendar,
            sourceId: "coordinator-conflict-failure",
            title: "New meeting",
            startTime: original.startTime,
            endTime: original.endTime
        )
        context.insert(original)
        context.insert(busy)
        try context.save()
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.replanBusyTimeConflicts(
                context: context,
                now: anchor,
                activeWorkSession: nil,
                interactive: false,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [original.id])
        XCTAssertEqual(original.task?.id, task.id)
        let fresh = ModelContext(container)
        let durable = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        XCTAssertEqual(durable.map(\.id), [original.id])
        XCTAssertEqual(durable.first?.startTime, anchor)
    }

    @MainActor
    func testBlockedTimeAddFailureRollsBackPlanAndSameObjectCanRetry() throws {
        enum ExpectedFailure: Error { case save }

        _ = makeSettings()
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let original = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 60)
        context.insert(original)
        try context.save()
        let blocked = BlockedTime(
            label: "Class",
            weekdays: [calendar.component(.weekday, from: anchor)],
            startHour: calendar.component(.hour, from: anchor),
            startMinute: calendar.component(.minute, from: anchor),
            durationMinutes: 60
        )
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.addBlockedTime(
                blocked,
                context: context,
                now: anchor,
                activeWorkSession: nil,
                interactive: false,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<BlockedTime>()).isEmpty)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [original.id])
        var fresh = ModelContext(container)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<BlockedTime>()).isEmpty)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [original.id])

        let replanned = try PlanCoordinator.addBlockedTime(
            blocked,
            context: context,
            now: anchor,
            activeWorkSession: nil,
            interactive: false,
            publish: { _, _ in publishCount += 1 }
        )
        XCTAssertEqual(replanned, 1)
        XCTAssertEqual(publishCount, 1)
        fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<BlockedTime>()).map(\.id), [blocked.id])
        let durableBlocks = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertFalse(durableBlocks.contains { $0.id == original.id })
        XCTAssertTrue(durableBlocks.allSatisfy {
            $0.startTime >= original.endTime || $0.endTime <= original.startTime
        })
    }

    @MainActor
    func testBlockedTimeDeleteFailureKeepsRowAndPublishesOnlyAfterRetryCommit() throws {
        enum ExpectedFailure: Error { case save }

        let blocked = BlockedTime(
            label: "Class",
            weekdays: [2, 4],
            startHour: 10,
            startMinute: 30,
            durationMinutes: 90
        )
        context.insert(blocked)
        try context.save()
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.deleteBlockedTime(
                blocked,
                context: context,
                interactive: false,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BlockedTime>()).map(\.id), [blocked.id])
        var fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<BlockedTime>()).map(\.id), [blocked.id])

        var finalSaveFinished = false
        try PlanCoordinator.deleteBlockedTime(
            blocked,
            context: context,
            interactive: false,
            save: { context in
                try context.save()
                finalSaveFinished = true
            },
            publish: { _, _ in
                publishCount += 1
                XCTAssertTrue(finalSaveFinished)
                let verification = ModelContext(self.container)
                XCTAssertFalse(((try? verification.fetch(
                    FetchDescriptor<BlockedTime>()
                )) ?? []).contains { $0.id == blocked.id })
            }
        )

        XCTAssertEqual(publishCount, 1)
        fresh = ModelContext(container)
        XCTAssertFalse(try fresh.fetch(FetchDescriptor<BlockedTime>()).contains {
            $0.id == blocked.id
        })
    }

    @MainActor
    func testBlockBoundaryFailureRollsBackCatchUpWithoutPublish() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        settings.startBufferMinutes = 0
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-2 * 3600),
            durationMinutes: 60
        )
        context.insert(missed)
        try context.save()
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.catchUpAtBlockBoundary(
                context: context,
                now: anchor,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [missed.id])
        let fresh = ModelContext(container)
        let durable = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id
        }
        XCTAssertEqual(durable.map(\.id), [missed.id])
        XCTAssertEqual(durable.first?.startTime, missed.startTime)
    }

    @MainActor
    func testForegroundPlanningFailureRollsBackMaterializationAndCatchUpWithoutPublish() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        settings.startBufferMinutes = 0
        settings.planningRebuildPending = true
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let missed = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(-2 * 3600),
            durationMinutes: 60
        )
        let nextDeadline = anchor.addingTimeInterval(24 * 3600)
        let template = TaskTemplate(
            title: "Weekly review",
            context: .work,
            effortMinutes: 30,
            nextDeadline: nextDeadline,
            repeatUntil: nextDeadline
        )
        context.insert(missed)
        context.insert(template)
        try context.save()
        let originalMarker = settings.lastFutileAutomaticRebalanceFingerprint
        var publishCount = 0

        XCTAssertThrowsError(
            try PlanCoordinator.refreshForegroundPlan(
                context: context,
                now: anchor,
                activeWorkSession: nil,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(template.nextDeadline, nextDeadline)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [missed.id])
        XCTAssertEqual(settings.lastFutileAutomaticRebalanceFingerprint, originalMarker)
        XCTAssertTrue(settings.planningRebuildPending)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FilumaTask>()).map(\.id), [task.id])
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<FilumaTask>()).map(\.id), [task.id])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [missed.id])
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).planningRebuildPending)
        let durableTemplate = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<TaskTemplate>()).first { $0.id == template.id }
        )
        XCTAssertEqual(durableTemplate.nextDeadline, nextDeadline)
    }

    @MainActor
    func testForegroundRefreshConsumesDurablePlanningRebuildIntent() throws {
        let settings = makeSettings()
        settings.startBufferMinutes = 0
        settings.deadlineBufferMinutes = 0
        settings.planningRebuildPending = true
        let task = makeTask(effort: 60, deadlineHoursFromAnchor: 48)
        let oldBlock = ScheduledBlock(
            task: task,
            startTime: anchor.addingTimeInterval(6 * 3600),
            durationMinutes: 60
        )
        context.insert(oldBlock)
        try context.save()
        var publishCount = 0

        let result = try PlanCoordinator.refreshForegroundPlan(
            context: context,
            now: anchor,
            activeWorkSession: nil,
            publish: { _, _ in publishCount += 1 }
        )

        XCTAssertEqual(publishCount, 1)
        XCTAssertFalse(settings.planningRebuildPending)
        XCTAssertEqual(result.catchUpSummary.adjustedTasks, 1)
        XCTAssertFalse(task.scheduledBlocks.contains { $0.id == oldBlock.id })
        XCTAssertEqual(
            task.scheduledBlocks.filter { !$0.isComplete }.reduce(0) {
                $0 + $1.durationMinutes
            },
            60
        )

        let fresh = ModelContext(container)
        let durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertFalse(durableSettings.planningRebuildPending)
        let durableBlocks = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == task.id && !$0.isComplete
        }
        XCTAssertFalse(durableBlocks.contains { $0.id == oldBlock.id })
        XCTAssertEqual(durableBlocks.reduce(0) { $0 + $1.durationMinutes }, 60)
    }

    // MARK: - Tasks focus timeline

    @MainActor
    func testTaskFocusTimelineAdvancesHeroAndQueueAtOneBoundary() throws {
        let firstTask = FilumaTask(
            title: "First thread",
            context: .school,
            deadline: anchor.addingTimeInterval(24 * 3600),
            effortMinutes: 30
        )
        let secondTask = FilumaTask(
            title: "Second thread",
            context: .work,
            deadline: anchor.addingTimeInterval(36 * 3600),
            effortMinutes: 45
        )
        let firstBlock = ScheduledBlock(
            task: firstTask,
            startTime: anchor.addingTimeInterval(-30 * 60),
            durationMinutes: 30
        )
        let secondBlock = ScheduledBlock(
            task: secondTask,
            startTime: anchor,
            durationMinutes: 45
        )
        context.insert(firstTask)
        context.insert(secondTask)
        context.insert(firstBlock)
        context.insert(secondBlock)
        try context.save()

        let beforeBoundary = TaskFocusTimeline.blocks(
            from: [firstTask, secondTask],
            at: anchor.addingTimeInterval(-1)
        )
        XCTAssertEqual(beforeBoundary.map(\.id), [firstBlock.id, secondBlock.id])

        let atBoundary = TaskFocusTimeline.blocks(
            from: [firstTask, secondTask],
            at: anchor
        )
        XCTAssertEqual(atBoundary.map(\.id), [secondBlock.id])
        XCTAssertTrue(atBoundary.dropFirst().isEmpty)

        let afterFinalBlock = TaskFocusTimeline.blocks(
            from: [firstTask, secondTask],
            at: secondBlock.endTime
        )
        XCTAssertTrue(afterFinalBlock.isEmpty)
    }

    // MARK: - Atomic capture coordination

    @MainActor
    func testTaskCaptureCommitsTaskBlocksAndWeeklyTemplateBeforePublishingReceipt() throws {
        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 0
        try context.save()
        let deadline = anchor.addingTimeInterval(48 * 3600)
        let repeatUntil = calendar.date(byAdding: .day, value: 14, to: deadline)!
        let prepared = try CaptureCoordinator.prepareTask(
            title: "  Draft methods  \n",
            firstStep: "  Open the protocol  \n",
            taskContext: .school,
            deadline: deadline,
            effortMinutes: 60,
            preferredStart: anchor,
            now: anchor,
            context: context
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<FilumaTask>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ScheduledBlock>()).isEmpty)
        var publishedReceipt: TaskCaptureReceipt?
        var finalSaveCount = 0

        let receipt = try CaptureCoordinator.commit(
            prepared,
            repeatWeeklyUntil: repeatUntil,
            context: context,
            save: { context in
                finalSaveCount += 1
                try context.save()
            },
            publish: { _, receipt in publishedReceipt = receipt }
        )

        XCTAssertEqual(finalSaveCount, 1)
        XCTAssertEqual(publishedReceipt, receipt)
        XCTAssertEqual(receipt.taskID, prepared.task.id)
        XCTAssertEqual(receipt.title, "Draft methods")
        XCTAssertEqual(receipt.scheduledMinutes, 60)
        XCTAssertEqual(receipt.unscheduledMinutes, 0)
        XCTAssertEqual(receipt.scheduledBlockCount, 1)
        XCTAssertEqual(receipt.firstBlockStart, prepared.task.scheduledBlocks.map(\.startTime).min())
        XCTAssertNotNil(receipt.templateID)
        XCTAssertEqual(prepared.task.firstStep, "Open the protocol")

        let heldTasks = try context.fetch(FetchDescriptor<FilumaTask>())
        let heldBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let heldTemplates = try context.fetch(FetchDescriptor<TaskTemplate>())
        XCTAssertEqual(heldTasks.map(\.id), [receipt.taskID])
        XCTAssertEqual(heldBlocks.map(\.task?.id), [receipt.taskID])
        XCTAssertEqual(
            heldTemplates.map(\.id),
            receipt.templateID.map { [$0] } ?? []
        )
        XCTAssertEqual(heldTemplates.first?.title, "Draft methods")
        XCTAssertEqual(heldTemplates.first?.firstStep, "Open the protocol")

        let fresh = ModelContext(container)
        let durableTask = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<FilumaTask>()).first { $0.id == receipt.taskID }
        )
        let durableBlocks = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == receipt.taskID
        }
        let durableTemplate = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<TaskTemplate>()).first { $0.id == receipt.templateID }
        )
        XCTAssertEqual(durableTask.title, receipt.title)
        XCTAssertEqual(durableTask.templateId, durableTemplate.id)
        XCTAssertEqual(durableBlocks.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertEqual(durableTemplate.repeatUntil, repeatUntil)
    }

    @MainActor
    func testTaskCaptureSaveFailureRollsBackEveryCaptureRowAndDoesNotPublish() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 0
        let unrelatedReminder = Reminder(
            title: "Already accepted",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(unrelatedReminder)
        try context.save()
        unrelatedReminder.isComplete = true

        let prepared = try CaptureCoordinator.prepareTask(
            title: "Atomic task",
            firstStep: "Begin",
            taskContext: .work,
            deadline: anchor.addingTimeInterval(48 * 3600),
            effortMinutes: 60,
            preferredStart: anchor,
            now: anchor,
            context: context
        )
        let provisionalBlocks = scheduledBlocks(from: prepared.result)
        var publishCount = 0

        XCTAssertThrowsError(
            try CaptureCoordinator.commit(
                prepared,
                repeatWeeklyUntil: anchor.addingTimeInterval(21 * 86_400),
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(prepared.task.scheduledBlocks.isEmpty)
        XCTAssertTrue(provisionalBlocks.allSatisfy { $0.task == nil })
        XCTAssertTrue(try context.fetch(FetchDescriptor<FilumaTask>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ScheduledBlock>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TaskTemplate>()).isEmpty)

        // A later unrelated save must not resurrect a rolled-back insertion.
        try context.save()
        let fresh = ModelContext(container)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<FilumaTask>()).isEmpty)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).isEmpty)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<TaskTemplate>()).isEmpty)
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<Reminder>()).first {
                $0.id == unrelatedReminder.id
            }
        ).isComplete, "capture preflight must preserve unrelated accepted edits")
    }

    @MainActor
    func testTaskCapturePreparationFetchFailureLeavesTheExistingPlanUntouched() throws {
        enum ExpectedFailure: Error { case fetch }

        _ = makeSettings()
        let existingTask = makeTask(effort: 45, deadlineHoursFromAnchor: 24)
        let existingBlock = ScheduledBlock(
            task: existingTask,
            startTime: anchor,
            durationMinutes: 45
        )
        context.insert(existingBlock)
        try context.save()

        XCTAssertThrowsError(
            try CaptureCoordinator.prepareTask(
                title: "Never materialized",
                firstStep: "",
                taskContext: .personal,
                deadline: anchor.addingTimeInterval(48 * 3600),
                effortMinutes: 30,
                now: anchor,
                context: context,
                load: { _ in throw ExpectedFailure.fetch }
            )
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<FilumaTask>()).map(\.id), [existingTask.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [existingBlock.id])
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<FilumaTask>()).map(\.id), [existingTask.id])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [existingBlock.id])
    }

    @MainActor
    func testTaskCapturePreparationRejectsBlankTitleAndMissingSettings() throws {
        XCTAssertThrowsError(
            try CaptureCoordinator.prepareTask(
                title: " \n ",
                firstStep: "Anything",
                taskContext: .personal,
                deadline: anchor.addingTimeInterval(3600),
                effortMinutes: 30,
                now: anchor,
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? CaptureCoordinatorError, .emptyTitle)
        }
        XCTAssertThrowsError(
            try CaptureCoordinator.prepareTask(
                title: "Needs settings",
                firstStep: "",
                taskContext: .personal,
                deadline: anchor.addingTimeInterval(3600),
                effortMinutes: 30,
                now: anchor,
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? CaptureCoordinatorError, .missingSettings)
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<FilumaTask>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ScheduledBlock>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<UserSettings>()).isEmpty)
    }

    @MainActor
    func testMakeRoomReceiptReflectsTheFinalRebalancedBlocks() throws {
        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 0
        let laterTask = FilumaTask(
            title: "Later work",
            context: .school,
            deadline: anchor.addingTimeInterval(24 * 3600),
            effortMinutes: 60
        )
        let occupied = ScheduledBlock(
            task: laterTask,
            startTime: anchor,
            durationMinutes: 60
        )
        context.insert(laterTask)
        context.insert(occupied)
        try context.save()

        let prepared = try CaptureCoordinator.prepareTask(
            title: "Urgent work",
            firstStep: "Open it",
            taskContext: .work,
            deadline: anchor.addingTimeInterval(60 * 60),
            effortMinutes: 30,
            preferredStart: anchor,
            now: anchor,
            context: context
        )
        guard case .noSlots = prepared.result else {
            return XCTFail("The occupied urgent window should require Make Room")
        }
        var publishedReceipt: TaskCaptureReceipt?

        let receipt = try CaptureCoordinator.commitMakingRoom(
            prepared,
            now: anchor,
            context: context,
            publish: { _, receipt in publishedReceipt = receipt }
        )

        XCTAssertEqual(publishedReceipt, receipt)
        XCTAssertEqual(receipt.taskID, prepared.task.id)
        XCTAssertEqual(receipt.scheduledMinutes, 30)
        XCTAssertEqual(receipt.unscheduledMinutes, 0)
        XCTAssertEqual(receipt.scheduledBlockCount, 1)
        XCTAssertEqual(receipt.firstBlockStart, anchor)

        let heldBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let urgentHeld = heldBlocks.filter { $0.task?.id == prepared.task.id }
        let laterHeld = heldBlocks.filter { $0.task?.id == laterTask.id }
        XCTAssertEqual(urgentHeld.reduce(0) { $0 + $1.durationMinutes }, receipt.scheduledMinutes)
        XCTAssertEqual(laterHeld.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertFalse(heldBlocks.contains { $0.id == occupied.id })

        let fresh = ModelContext(container)
        let urgentDurable = try fresh.fetch(FetchDescriptor<ScheduledBlock>()).filter {
            $0.task?.id == receipt.taskID
        }
        XCTAssertEqual(urgentDurable.reduce(0) { $0 + $1.durationMinutes }, receipt.scheduledMinutes)
        XCTAssertEqual(
            max(0, 30 - urgentDurable.reduce(0) { $0 + $1.durationMinutes }),
            receipt.unscheduledMinutes
        )
    }

    @MainActor
    func testMakeRoomSaveFailureRestoresHeldAndDurablePlanWithoutPublishing() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 0
        let laterTask = FilumaTask(
            title: "Keep this plan",
            context: .school,
            deadline: anchor.addingTimeInterval(24 * 3600),
            effortMinutes: 60
        )
        let originalBlock = ScheduledBlock(
            task: laterTask,
            startTime: anchor,
            durationMinutes: 60
        )
        context.insert(laterTask)
        context.insert(originalBlock)
        try context.save()
        let originalMarker = settings.lastFutileAutomaticRebalanceFingerprint

        let prepared = try CaptureCoordinator.prepareTask(
            title: "Rejected urgent work",
            firstStep: "Open it",
            taskContext: .work,
            deadline: anchor.addingTimeInterval(60 * 60),
            effortMinutes: 30,
            preferredStart: anchor,
            now: anchor,
            context: context
        )
        var publishCount = 0

        XCTAssertThrowsError(
            try CaptureCoordinator.commitMakingRoom(
                prepared,
                repeatWeeklyUntil: anchor.addingTimeInterval(21 * 86_400),
                now: anchor,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(laterTask.scheduledBlocks.map(\.id), [originalBlock.id])
        XCTAssertEqual(settings.lastFutileAutomaticRebalanceFingerprint, originalMarker)
        XCTAssertTrue(prepared.task.scheduledBlocks.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FilumaTask>()).map(\.id), [laterTask.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [originalBlock.id])
        XCTAssertTrue(try context.fetch(FetchDescriptor<TaskTemplate>()).isEmpty)

        // Prove the repaired held projection cannot resurrect attempted rows.
        try context.save()
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<FilumaTask>()).map(\.id), [laterTask.id])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [originalBlock.id])
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<TaskTemplate>()).isEmpty)
    }

    @MainActor
    func testReminderCaptureSavesTrimmedRowBeforePublishingReceipt() throws {
        var publishedReceipt: ReminderCaptureReceipt?
        var finalSaveCount = 0

        let receipt = try CaptureCoordinator.saveReminder(
            title: "  Take meds  \n",
            dueDate: anchor,
            context: context,
            save: { context in
                finalSaveCount += 1
                try context.save()
            },
            publish: { _, receipt in publishedReceipt = receipt }
        )

        XCTAssertEqual(finalSaveCount, 1)
        XCTAssertEqual(publishedReceipt, receipt)
        XCTAssertEqual(receipt.title, "Take meds")
        XCTAssertEqual(receipt.dueDate, anchor)
        XCTAssertFalse(receipt.notificationID.isEmpty)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Reminder>()).map(\.id),
            [receipt.reminderID]
        )

        let fresh = ModelContext(container)
        let durable = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<Reminder>()).first { $0.id == receipt.reminderID }
        )
        XCTAssertEqual(durable.title, receipt.title)
        XCTAssertEqual(durable.dueDate, receipt.dueDate)
        XCTAssertEqual(durable.notificationId, receipt.notificationID)
    }

    @MainActor
    func testReminderCaptureSaveFailureLeavesNoRowAndDoesNotPublish() throws {
        enum ExpectedFailure: Error { case save }
        var publishCount = 0

        XCTAssertThrowsError(
            try CaptureCoordinator.saveReminder(
                title: "  Not durable  ",
                dueDate: anchor,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Reminder>()).isEmpty)
        try context.save()
        let fresh = ModelContext(container)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<Reminder>()).isEmpty)
    }

    // MARK: - Atomic reminder mutation coordination

    @MainActor
    func testReminderMutationsPublishScalarReceiptsOnlyAfterDurableSuccess() throws {
        let reminder = Reminder(
            title: "Take meds",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(reminder)
        try context.save()
        let expectedDueDate = reminder.dueDate
        var publishedReceipts: [ReminderMutationReceipt] = []

        let completed = try ReminderMutationCoordinator.apply(
            .complete,
            to: reminder,
            context: context,
            publish: { receipt in
                publishedReceipts.append(receipt)
                let fresh = ModelContext(self.container)
                let durable = try? fresh.fetch(FetchDescriptor<Reminder>())
                    .first { $0.id == receipt.reminderID }
                XCTAssertEqual(durable?.isComplete, true)
            }
        )
        XCTAssertEqual(completed.mutation, .complete)
        XCTAssertTrue(reminder.isComplete)

        let restored = try ReminderMutationCoordinator.apply(
            .restore,
            to: reminder,
            context: context,
            publish: { receipt in
                publishedReceipts.append(receipt)
                let fresh = ModelContext(self.container)
                let durable = try? fresh.fetch(FetchDescriptor<Reminder>())
                    .first { $0.id == receipt.reminderID }
                XCTAssertEqual(durable?.isComplete, false)
            }
        )
        XCTAssertEqual(restored.mutation, .restore)
        XCTAssertFalse(reminder.isComplete)

        let deleted = try ReminderMutationCoordinator.apply(
            .delete,
            to: reminder,
            context: context,
            publish: { receipt in
                publishedReceipts.append(receipt)
                let fresh = ModelContext(self.container)
                let durableIDs = (try? fresh.fetch(FetchDescriptor<Reminder>()).map(\.id)) ?? []
                XCTAssertFalse(durableIDs.contains(receipt.reminderID))
            }
        )

        XCTAssertEqual(publishedReceipts.map(\.mutation), [.complete, .restore, .delete])
        XCTAssertEqual(deleted.reminderID, completed.reminderID)
        XCTAssertEqual(deleted.title, "Take meds")
        XCTAssertEqual(deleted.dueDate, expectedDueDate)
        XCTAssertEqual(deleted.notificationID, completed.notificationID)
        let fresh = ModelContext(container)
        XCTAssertFalse(
            try fresh.fetch(FetchDescriptor<Reminder>()).contains {
                $0.id == deleted.reminderID
            }
        )
    }

    @MainActor
    func testReminderCompleteFailureRepairsHeldAndFreshStateThenSameContextRetrySucceeds() throws {
        enum ExpectedFailure: Error { case save }

        let reminder = Reminder(title: "Complete me", dueDate: anchor)
        let unrelated = Reminder(
            title: "Earlier accepted edit",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(reminder)
        context.insert(unrelated)
        try context.save()
        unrelated.isComplete = true
        var publishCount = 0

        XCTAssertThrowsError(
            try ReminderMutationCoordinator.apply(
                .complete,
                to: reminder,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertFalse(reminder.isComplete)
        XCTAssertTrue(unrelated.isComplete)
        var fresh = ModelContext(container)
        var durable = try fresh.fetch(FetchDescriptor<Reminder>())
        XCTAssertFalse(try XCTUnwrap(durable.first { $0.id == reminder.id }).isComplete)
        XCTAssertTrue(try XCTUnwrap(durable.first { $0.id == unrelated.id }).isComplete)

        _ = try ReminderMutationCoordinator.apply(
            .complete,
            to: reminder,
            context: context,
            publish: { _ in publishCount += 1 }
        )

        XCTAssertEqual(publishCount, 1)
        XCTAssertTrue(reminder.isComplete)
        fresh = ModelContext(container)
        durable = try fresh.fetch(FetchDescriptor<Reminder>())
        XCTAssertTrue(try XCTUnwrap(durable.first { $0.id == reminder.id }).isComplete)
        XCTAssertTrue(try XCTUnwrap(durable.first { $0.id == unrelated.id }).isComplete)
    }

    @MainActor
    func testReminderRestoreFailureRepairsHeldAndFreshStateThenSameContextRetrySucceeds() throws {
        enum ExpectedFailure: Error { case save }

        let reminder = Reminder(title: "Restore me", dueDate: anchor)
        reminder.isComplete = true
        let unrelated = Reminder(
            title: "Earlier accepted edit",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(reminder)
        context.insert(unrelated)
        try context.save()
        unrelated.isComplete = true
        var publishCount = 0

        XCTAssertThrowsError(
            try ReminderMutationCoordinator.apply(
                .restore,
                to: reminder,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertTrue(reminder.isComplete)
        XCTAssertTrue(unrelated.isComplete)
        var fresh = ModelContext(container)
        var durable = try fresh.fetch(FetchDescriptor<Reminder>())
        XCTAssertTrue(try XCTUnwrap(durable.first { $0.id == reminder.id }).isComplete)
        XCTAssertTrue(try XCTUnwrap(durable.first { $0.id == unrelated.id }).isComplete)

        _ = try ReminderMutationCoordinator.apply(
            .restore,
            to: reminder,
            context: context,
            publish: { _ in publishCount += 1 }
        )

        XCTAssertEqual(publishCount, 1)
        XCTAssertFalse(reminder.isComplete)
        fresh = ModelContext(container)
        durable = try fresh.fetch(FetchDescriptor<Reminder>())
        XCTAssertFalse(try XCTUnwrap(durable.first { $0.id == reminder.id }).isComplete)
        XCTAssertTrue(try XCTUnwrap(durable.first { $0.id == unrelated.id }).isComplete)
    }

    @MainActor
    func testReminderDeleteFailureKeepsHeldAndFreshRowThenSameContextRetrySucceeds() throws {
        enum ExpectedFailure: Error { case save }

        let reminder = Reminder(title: "Delete me", dueDate: anchor)
        reminder.isComplete = true
        let reminderID = reminder.id
        let notificationID = reminder.notificationId
        let unrelated = Reminder(
            title: "Earlier accepted edit",
            dueDate: anchor.addingTimeInterval(3600)
        )
        context.insert(reminder)
        context.insert(unrelated)
        try context.save()
        unrelated.isComplete = true
        var publishCount = 0

        XCTAssertThrowsError(
            try ReminderMutationCoordinator.apply(
                .delete,
                to: reminder,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(reminder.id, reminderID)
        XCTAssertEqual(reminder.notificationId, notificationID)
        XCTAssertTrue(reminder.isComplete)
        XCTAssertTrue(unrelated.isComplete)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<Reminder>()).contains {
                $0.id == reminderID
            }
        )
        var fresh = ModelContext(container)
        var durable = try fresh.fetch(FetchDescriptor<Reminder>())
        XCTAssertTrue(durable.contains { $0.id == reminderID && $0.isComplete })
        XCTAssertTrue(durable.contains { $0.id == unrelated.id && $0.isComplete })

        var publishedReceipt: ReminderMutationReceipt?
        _ = try ReminderMutationCoordinator.apply(
            .delete,
            to: reminder,
            context: context,
            publish: { receipt in
                publishCount += 1
                publishedReceipt = receipt
            }
        )

        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(publishedReceipt?.mutation, .delete)
        XCTAssertEqual(publishedReceipt?.reminderID, reminderID)
        XCTAssertEqual(publishedReceipt?.notificationID, notificationID)
        fresh = ModelContext(container)
        durable = try fresh.fetch(FetchDescriptor<Reminder>())
        XCTAssertFalse(durable.contains { $0.id == reminderID })
        XCTAssertTrue(durable.contains { $0.id == unrelated.id && $0.isComplete })
    }

    // MARK: - Atomic bulk capture coordination

    @MainActor
    func testBulkCaptureSchedulesSequentiallyWithoutOverlapAndReturnsFactualReceipt() throws {
        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 0
        try context.save()
        let drafts = [
            BulkTaskCaptureDraft(
                title: "  First row  ",
                context: .school,
                deadline: anchor.addingTimeInterval(60 * 60),
                effortMinutes: 30
            ),
            BulkTaskCaptureDraft(
                title: "Second row",
                context: .work,
                deadline: anchor.addingTimeInterval(90 * 60),
                effortMinutes: 30
            ),
            BulkTaskCaptureDraft(
                title: "Third row",
                context: .personal,
                deadline: anchor.addingTimeInterval(90 * 60),
                effortMinutes: 60
            )
        ]
        var publishCount = 0
        var publishedReceipt: BulkCaptureReceipt?

        let receipt = try CaptureCoordinator.commitBulk(
            drafts,
            now: anchor,
            context: context,
            publish: { _, receipt in
                publishCount += 1
                publishedReceipt = receipt
            }
        )

        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(publishedReceipt, receipt)
        XCTAssertEqual(receipt.taskReceipts.map(\.title), [
            "First row", "Second row", "Third row"
        ])
        XCTAssertEqual(receipt.taskReceipts.map(\.scheduledMinutes), [30, 30, 30])
        XCTAssertEqual(receipt.taskReceipts.map(\.unscheduledMinutes), [0, 0, 30])
        XCTAssertEqual(receipt.fullyScheduledCount, 2)
        XCTAssertEqual(receipt.needsAttentionCount, 1)

        let heldTasks = try context.fetch(FetchDescriptor<FilumaTask>())
        let heldBlocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
            .sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(Set(heldTasks.map(\.id)), Set(receipt.taskReceipts.map(\.taskID)))
        XCTAssertTrue(heldTasks.allSatisfy { $0.source == .bulkEntry })
        XCTAssertEqual(heldBlocks.count, 3)
        for pair in zip(heldBlocks, heldBlocks.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.endTime, pair.1.startTime)
        }
        for taskReceipt in receipt.taskReceipts {
            let minutes = heldBlocks
                .filter { $0.task?.id == taskReceipt.taskID }
                .reduce(0) { $0 + $1.durationMinutes }
            XCTAssertEqual(minutes, taskReceipt.scheduledMinutes)
        }

        let fresh = ModelContext(container)
        let durableTasks = try fresh.fetch(FetchDescriptor<FilumaTask>())
        let durableBlocks = try fresh.fetch(FetchDescriptor<ScheduledBlock>())
        XCTAssertEqual(Set(durableTasks.map(\.id)), Set(receipt.taskReceipts.map(\.taskID)))
        XCTAssertTrue(durableTasks.allSatisfy { $0.source == .bulkEntry })
        XCTAssertEqual(Set(durableBlocks.compactMap(\.task?.id)), Set(receipt.taskReceipts.map(\.taskID)))
    }

    @MainActor
    func testBulkCaptureSaveFailureIsAllOrNothingInHeldAndFreshContexts() throws {
        enum ExpectedFailure: Error { case save }

        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 0
        let existingTask = makeTask(effort: 30, deadlineHoursFromAnchor: 72)
        let existingBlock = ScheduledBlock(
            task: existingTask,
            startTime: anchor.addingTimeInterval(8 * 3600),
            durationMinutes: 30
        )
        context.insert(existingBlock)
        try context.save()
        let drafts = [
            BulkTaskCaptureDraft(
                title: "Rejected one",
                context: .school,
                deadline: anchor.addingTimeInterval(24 * 3600),
                effortMinutes: 30
            ),
            BulkTaskCaptureDraft(
                title: "Rejected two",
                context: .work,
                deadline: anchor.addingTimeInterval(36 * 3600),
                effortMinutes: 60
            )
        ]
        var publishCount = 0

        XCTAssertThrowsError(
            try CaptureCoordinator.commitBulk(
                drafts,
                now: anchor,
                context: context,
                save: { _ in throw ExpectedFailure.save },
                publish: { _, _ in publishCount += 1 }
            )
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FilumaTask>()).map(\.id), [existingTask.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [existingBlock.id])
        XCTAssertEqual(existingTask.scheduledBlocks.map(\.id), [existingBlock.id])
        XCTAssertTrue(try context.fetch(FetchDescriptor<FilumaTask>()).allSatisfy {
            $0.source != .bulkEntry
        })

        // A later save cannot resurrect any rolled-back bulk graph.
        try context.save()
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<FilumaTask>()).map(\.id), [existingTask.id])
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), [existingBlock.id])
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<FilumaTask>()).allSatisfy {
            $0.source != .bulkEntry
        })
    }

    @MainActor
    func testBulkCaptureReadAndValidationFailuresLeaveTheStoreUnchanged() throws {
        enum ExpectedFailure: Error { case fetch }

        let settings = makeSettings()
        let existingTask = makeTask(effort: 45, deadlineHoursFromAnchor: 48)
        let existingBlock = ScheduledBlock(
            task: existingTask,
            startTime: anchor,
            durationMinutes: 45
        )
        context.insert(existingBlock)
        try context.save()
        let baselineTaskIDs = [existingTask.id]
        let baselineBlockIDs = [existingBlock.id]
        let valid = BulkTaskCaptureDraft(
            title: "Read should fail",
            context: .personal,
            deadline: anchor.addingTimeInterval(24 * 3600),
            effortMinutes: 30
        )

        XCTAssertThrowsError(
            try CaptureCoordinator.commitBulk(
                [valid],
                now: anchor,
                context: context,
                load: { _ in throw ExpectedFailure.fetch },
                publish: { _, _ in XCTFail("read failure must not publish") }
            )
        )

        var validationLoadCount = 0
        XCTAssertThrowsError(
            try CaptureCoordinator.commitBulk(
                [
                    valid,
                    BulkTaskCaptureDraft(
                        title: " \n ",
                        context: .work,
                        deadline: anchor.addingTimeInterval(24 * 3600),
                        effortMinutes: 30
                    )
                ],
                now: anchor,
                context: context,
                load: { _ in
                    validationLoadCount += 1
                    return TaskCapturePlanningInput(
                        settings: settings,
                        allBlocks: [existingBlock],
                        blockedTimes: [],
                        busyEvents: []
                    )
                }
            )
        ) { error in
            XCTAssertEqual(error as? CaptureCoordinatorError, .emptyTitle)
        }
        XCTAssertThrowsError(
            try CaptureCoordinator.commitBulk(
                [],
                now: anchor,
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? CaptureCoordinatorError, .emptyBatch)
        }
        XCTAssertThrowsError(
            try CaptureCoordinator.commitBulk(
                [
                    BulkTaskCaptureDraft(
                        title: "No effort",
                        context: .school,
                        deadline: anchor.addingTimeInterval(24 * 3600),
                        effortMinutes: 0
                    )
                ],
                now: anchor,
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? CaptureCoordinatorError, .invalidEffortMinutes)
        }

        XCTAssertEqual(validationLoadCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FilumaTask>()).map(\.id), baselineTaskIDs)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), baselineBlockIDs)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<FilumaTask>()).map(\.id), baselineTaskIDs)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScheduledBlock>()).map(\.id), baselineBlockIDs)
    }

    @MainActor
    func testBulkCapturePublishesExactlyOnceAfterRowsAreDurable() throws {
        let settings = makeSettings()
        settings.deadlineBufferMinutes = 0
        settings.startBufferMinutes = 0
        try context.save()
        var finalSaveFinished = false
        var publishCount = 0
        var durableIDsSeenDuringPublish: [UUID] = []

        let receipt = try CaptureCoordinator.commitBulk(
            [
                BulkTaskCaptureDraft(
                    title: "Durable before publish",
                    context: .personal,
                    deadline: anchor.addingTimeInterval(24 * 3600),
                    effortMinutes: 30
                )
            ],
            now: anchor,
            context: context,
            save: { context in
                try context.save()
                finalSaveFinished = true
            },
            publish: { _, _ in
                publishCount += 1
                XCTAssertTrue(finalSaveFinished)
                let fresh = ModelContext(self.container)
                durableIDsSeenDuringPublish = (
                    try? fresh.fetch(FetchDescriptor<FilumaTask>()).map(\.id)
                ) ?? []
            }
        )

        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(durableIDsSeenDuringPublish, receipt.taskReceipts.map(\.taskID))
    }

    // MARK: - Data export

    func testDataExportRoundTrips() throws {
        let settings = makeSettings()
        settings.wakeHour = 7
        settings.dailyFocusMinutes = 240
        settings.importFromAppleCalendar = true
        settings.excludedCalendarIds = ["family-calendar"]
        settings.googleAccountEmail = "person@example.com"
        settings.morningPreviewEnabled = false
        let task = makeTask(effort: 90, deadlineHoursFromAnchor: 48)
        task.firstStep = "Open the doc"
        let block = ScheduledBlock(task: task, startTime: anchor, durationMinutes: 45)
        context.insert(block)
        let session = WorkSession(
            task: task,
            startedAt: anchor,
            durationSeconds: 1200,
            scheduledBlockId: block.id
        )
        context.insert(session)
        let reminder = Reminder(title: "Take meds", dueDate: anchor.addingTimeInterval(3600))
        context.insert(reminder)
        let blocked = BlockedTime(label: "Class", weekdays: [2, 4], startHour: 10, startMinute: 30, durationMinutes: 90)
        context.insert(blocked)
        let template = TaskTemplate(
            title: "Weekly set", context: .school, effortMinutes: 60,
            nextDeadline: anchor.addingTimeInterval(7 * 86_400),
            repeatUntil: anchor.addingTimeInterval(30 * 86_400)
        )
        context.insert(template)
        try context.save()

        let data = try DataExporter.exportJSON(context: context)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(DataExporter.Export.self, from: data)

        XCTAssertEqual(export.version, 5)
        XCTAssertEqual(export.tasks.count, 1)
        XCTAssertEqual(export.blocks.count, 1)
        XCTAssertEqual(export.workSessions.count, 1)
        XCTAssertEqual(export.reminders.count, 1)
        XCTAssertEqual(export.blockedTimes.count, 1)
        XCTAssertEqual(export.templates.count, 1)

        let exportedSettings = try XCTUnwrap(export.settings)
        XCTAssertEqual(exportedSettings.id, settings.id)
        XCTAssertEqual(exportedSettings.wakeHour, 7)
        XCTAssertEqual(exportedSettings.dailyFocusMinutes, 240)
        XCTAssertTrue(exportedSettings.importFromAppleCalendar)
        XCTAssertEqual(exportedSettings.excludedCalendarIds, ["family-calendar"])
        XCTAssertEqual(exportedSettings.googleAccountEmail, "person@example.com")
        XCTAssertFalse(exportedSettings.morningPreviewEnabled)
        XCTAssertNotNil(HearthAccent(rawValue: exportedSettings.hearthAccent))

        let exportedTask = try XCTUnwrap(export.tasks.first)
        XCTAssertEqual(exportedTask.id, task.id)
        XCTAssertEqual(exportedTask.firstStep, "Open the doc")
        XCTAssertEqual(exportedTask.context, "School")
        XCTAssertEqual(export.blocks.first?.taskId, task.id, "relations survive as id references")
        XCTAssertEqual(export.workSessions.first?.scheduledBlockId, block.id)
        XCTAssertEqual(export.blockedTimes.first?.weekdays, [2, 4])

        // Export v1 had the same core envelope but no settings record or
        // session-to-block link. Both additions stay backward-decodable.
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacyObject["version"] = 1
        legacyObject.removeValue(forKey: "settings")
        var legacySessions = try XCTUnwrap(
            legacyObject["workSessions"] as? [[String: Any]]
        )
        legacySessions[0].removeValue(forKey: "scheduledBlockId")
        legacyObject["workSessions"] = legacySessions
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyExport = try decoder.decode(DataExporter.Export.self, from: legacyData)

        XCTAssertEqual(legacyExport.version, 1)
        XCTAssertNil(legacyExport.settings)
        XCTAssertNil(legacyExport.workSessions.first?.scheduledBlockId)
    }
}
