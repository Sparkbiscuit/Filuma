import XCTest
import SwiftData
@testable import Filuma

final class SafeZonePersistenceTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            FilumaTask.self, TaskTemplate.self, ScheduledBlock.self, WorkSession.self,
            BlockedTime.self, BusyEvent.self, Reminder.self, UserSettings.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @MainActor
    func testSafeZoneNilAndNoneRoundTripAndExport() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = UserSettings()
        XCTAssertEqual(settings.deadlineBufferMinutes, 1440)
        settings.deadlineBufferMinutes = 120
        context.insert(settings)
        let inherited = FilumaTask(title: "Inherited", context: .school, deadline: Date().addingTimeInterval(172800), effortMinutes: 60)
        let none = FilumaTask(title: "None", context: .work, deadline: inherited.deadline, effortMinutes: 60, safeZoneMinutes: 0)
        context.insert(inherited)
        context.insert(none)
        try context.save()
        let reader = ModelContext(container)
        let stored = try reader.fetch(FetchDescriptor<FilumaTask>())
        XCTAssertNil(try XCTUnwrap(stored.first { $0.id == inherited.id }).safeZoneMinutes)
        XCTAssertEqual(try XCTUnwrap(stored.first { $0.id == none.id }).safeZoneMinutes, 0)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<UserSettings>()).first?.deadlineBufferMinutes, 120)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(DataExporter.Export.self, from: DataExporter.exportJSON(context: context))
        XCTAssertNil(try XCTUnwrap(export.tasks.first { $0.id == inherited.id }).safeZoneMinutes)
        XCTAssertEqual(try XCTUnwrap(export.tasks.first { $0.id == none.id }).safeZoneMinutes, 0)
    }

    @MainActor
    func testFailedSafeZoneEditRestoresHeldAndDurableOverride() throws {
        enum Failure: Error { case save }
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = FilumaTask(title: "Keep my buffer", context: .school, deadline: Date().addingTimeInterval(172800), effortMinutes: 60, safeZoneMinutes: 360)
        context.insert(task)
        try context.save()
        var didAttemptSave = false
        XCTAssertThrowsError(try PlanCoordinator.saveTaskEdits(
            task,
            update: TaskEditUpdate(title: task.title, firstStep: nil, taskContext: task.context, deadline: task.deadline, effortMinutes: task.effortMinutes, safeZoneMinutes: 0),
            context: context,
            save: { _ in didAttemptSave = true; throw Failure.save },
            publish: { _ in XCTFail("A rejected save must not publish") }
        ))
        XCTAssertTrue(didAttemptSave)
        XCTAssertEqual(task.safeZoneMinutes, 360)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FilumaTask>()).first?.safeZoneMinutes, 360)
    }

    @MainActor
    func testRecurringCaptureRetainsSafeZoneOverride() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(UserSettings())
        try context.save()
        let now = Date()
        let deadline = now.addingTimeInterval(172800)
        let prepared = try CaptureCoordinator.prepareTask(title: "Weekly work", firstStep: "Open notes", taskContext: .school, deadline: deadline, effortMinutes: 60, safeZoneMinutes: 720, now: now, context: context)
        try CaptureCoordinator.commit(prepared, repeatWeeklyUntil: deadline.addingTimeInterval(14 * 86400), context: context, publish: { _, _ in })
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskTemplate>()).first?.safeZoneMinutes, 720)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FilumaTask>()).first?.safeZoneMinutes, 720)
        let templates = try context.fetch(FetchDescriptor<TaskTemplate>())
        let created = SchedulerService.materializeRecurringTasks(
            templates: templates,
            allBlocks: try context.fetch(FetchDescriptor<ScheduledBlock>()),
            settings: try XCTUnwrap(context.fetch(FetchDescriptor<UserSettings>()).first),
            now: now,
            context: context
        )
        XCTAssertGreaterThan(created, 0)
        let occurrences = try context.fetch(FetchDescriptor<FilumaTask>()).filter { $0.source == .recurring }
        XCTAssertEqual(occurrences.count, created)
        XCTAssertTrue(occurrences.allSatisfy { $0.safeZoneMinutes == 720 })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(DataExporter.Export.self, from: DataExporter.exportJSON(context: context))
        XCTAssertEqual(export.templates.first?.safeZoneMinutes, 720)
    }
}


extension SafeZonePersistenceTests {
    /// Fixture made by the unmodified pre-update schema at commit 52a1c893.
    @MainActor func testActualLegacyStoreMigratesWithoutLosingPreferencesOrRelationships() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-filuma", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.store")
        try FileManager.default.copyItem(at: fixture, to: url)
        let container = try ModelContainer(for: SharedStore.schema, configurations: [ModelConfiguration(url: url)])
        let context = ModelContext(container)
        let tasks = try context.fetch(FetchDescriptor<FilumaTask>())
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.title, "Legacy migration task")
        XCTAssertEqual(task.firstStep, "Preserve my first step")
        XCTAssertEqual(task.manualProgressPercent, 25)
        XCTAssertNil(task.safeZoneMinutes)
        XCTAssertEqual(task.scheduledBlocks.count, 1)
        XCTAssertTrue(task.scheduledBlocks.first?.isLocked == true)
        XCTAssertEqual(task.scheduledBlocks.first?.task?.id, task.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserSettings>()).first?.deadlineBufferMinutes, 120)
        let template = try XCTUnwrap(context.fetch(FetchDescriptor<TaskTemplate>()).first)
        XCTAssertEqual(template.title, "Legacy recurrence")
        XCTAssertNil(template.safeZoneMinutes)
        task.safeZoneMinutes = 0
        try context.save()
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FilumaTask>()).first?.safeZoneMinutes, 0)
    }

    @MainActor func testExplicitRebuildAndReschedulePreservePausedSessionReservations() throws {
        let previous = WorkSessionControlStore.load()
        defer {
            if let previous { WorkSessionControlStore.save(previous) }
            else { WorkSessionControlStore.clear() }
        }
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date()
        let settings = UserSettings()
        context.insert(settings)
        let task = FilumaTask(title: "Running work", context: .school, deadline: now.addingTimeInterval(86400 * 3), effortMinutes: 60)
        context.insert(task)
        let block = ScheduledBlock(task: task, startTime: now.addingTimeInterval(-300), durationMinutes: 60)
        context.insert(block)
        try context.save()
        let original = block.startTime
        WorkSessionControlStore.save(WorkSessionControlState(sessionID: UUID(), startedAt: original, pauseBeganAt: now, taskID: task.id, scheduledBlockID: block.id))
        try PlanCoordinator.rebuildPlan(context: context, publish: { _, _ in })
        XCTAssertTrue(settings.planningRebuildPending)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [block.id])
        XCTAssertEqual(block.startTime, original)
        _ = SchedulerService.reschedule(task: task, allBlocks: [block], settings: settings, now: now, context: context)
        XCTAssertEqual(task.scheduledBlocks.map(\.id), [block.id])
        XCTAssertEqual(block.startTime, original)
    }
}


extension SafeZonePersistenceTests {
    @MainActor func testDelayedStartSurvivesWholePlanRebuild() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let settings = UserSettings()
        context.insert(settings)
        let now = Date()
        let notBefore = now.addingTimeInterval(3 * 86400)
        let task = FilumaTask(title: "Start after travel", context: .work, deadline: now.addingTimeInterval(8 * 86400), effortMinutes: 180)
        task.earliestStart = notBefore
        context.insert(task)
        SchedulerService.rebalance(tasks: [task], allBlocks: [], blockedTimes: [], settings: settings, now: now, context: context)
        XCTAssertFalse(task.scheduledBlocks.isEmpty)
        XCTAssertTrue(task.scheduledBlocks.allSatisfy { $0.startTime >= notBefore })
        XCTAssertEqual(task.scheduledBlocks.reduce(0) { $0 + $1.durationMinutes }, 180)
    }
}


extension SafeZonePersistenceTests {
    @MainActor func testDurableAttendanceReconcilesBeforeItsTimerJournalIsCleared() throws {
        let previous = WorkSessionControlStore.load()
        defer { if let previous { WorkSessionControlStore.save(previous) } else { WorkSessionControlStore.clear() } }
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(UserSettings())
        let now = Date()
        let task = FilumaTask(title: "Keep remaining work scheduled", context: .school, deadline: now.addingTimeInterval(4 * 86400), effortMinutes: 60)
        context.insert(task)
        let block = ScheduledBlock(task: task, startTime: now.addingTimeInterval(-3600), durationMinutes: 60)
        block.isComplete = true
        context.insert(block)
        let session = WorkSessionControlState(sessionID: UUID(), startedAt: block.startTime, taskID: task.id, scheduledBlockID: block.id)
        WorkSessionControlStore.save(session)
        try context.save()
        _ = try PlanCoordinator.reconcileTaskAfterAttendance(task, context: context, now: now, endingSessionID: session.sessionID, publish: { _ in })
        XCTAssertEqual(task.scheduledBlocks.filter { !$0.isComplete }.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertEqual(WorkSessionControlStore.load()?.sessionID, session.sessionID)
        XCTAssertTrue(task.scheduledBlocks.contains { $0.id == block.id && $0.isComplete })
    }
}


extension SafeZonePersistenceTests {
    @MainActor func testDeferredReplanCannotCreditReservationsAfterChangedDeadline() throws {
        let previous = WorkSessionControlStore.load()
        defer { if let previous { WorkSessionControlStore.save(previous) } else { WorkSessionControlStore.clear() } }
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date()
        let settings = UserSettings()
        context.insert(settings)
        let task = FilumaTask(title: "Shortened deadline", context: .work, deadline: now.addingTimeInterval(1800), effortMinutes: 60)
        context.insert(task)
        let block = ScheduledBlock(task: task, startTime: now.addingTimeInterval(3600), durationMinutes: 60)
        context.insert(block)
        WorkSessionControlStore.save(WorkSessionControlState(sessionID: UUID(), startedAt: now, taskID: task.id))
        let result = SchedulerService.reschedule(task: task, allBlocks: [block], settings: settings, now: now, context: context)
        guard case .partialFit(_, let unscheduled) = result else { return XCTFail("Deferred blocks after the deadline cannot count as complete coverage") }
        XCTAssertEqual(unscheduled, 60)
        XCTAssertTrue(settings.planningRebuildPending)
        XCTAssertEqual(block.startTime, now.addingTimeInterval(3600))
    }
}
