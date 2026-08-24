import Foundation
import EventKit
import OSLog
import SwiftData

/// One-way export of scheduled work blocks into a dedicated "Filuma" calendar in
/// Apple Calendar. Filuma owns that calendar outright: events are created, moved,
/// and removed to mirror the current schedule. Nothing is ever read back.
@MainActor
enum CalendarExportService {

    private static let store = EKEventStore()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Filuma",
        category: "CalendarExport"
    )

    enum ExportError: Error {
        case calendarAccessUnavailable
        case noCalendarSource
    }

    private struct CalendarResolution {
        let calendar: EKCalendar
        let wasCreated: Bool
    }

    /// If persisting a newly-created calendar identifier fails and EventKit
    /// also rejects compensating removal, retain its exact identity for an
    /// in-process retry instead of creating another Filuma calendar.
    private static var recoveryCalendarIdentifier: String?

    private static let eventNotePrefix = "Scheduled by Filuma\nBlock ID: "

    /// How far ahead exported events are maintained (Google export shares it).
    nonisolated static let horizonDays = 60

    /// Pure ownership check for async Settings retries. A captured request may
    /// reconcile EventKit only while it is still the newest request and the
    /// durable preference still matches the operation it captured.
    nonisolated static func isReconciliationCurrent(
        expectedEnabled: Bool,
        durableEnabled: Bool,
        requestID: UUID,
        currentRequestID: UUID?
    ) -> Bool {
        currentRequestID == requestID && durableEnabled == expectedEnabled
    }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Reconcile the Filuma calendar with the store, if export is enabled.
    /// Safe to call after any scheduling change; does nothing when disabled
    /// or when access is missing.
    static func syncIfEnabled(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard settings.exportToAppleCalendar else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        do {
            try syncNow(context: context, settings: settings)
        } catch {
            logger.error("Calendar export failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Unconditional one-time push, regardless of the ongoing-export toggle —
    /// caller has verified access.
    static func syncNow(
        context: ModelContext,
        settings: UserSettings,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw ExportError.calendarAccessUnavailable
        }

        // Accept unrelated pending work before making any irreversible EventKit
        // change. The calendar preference itself is committed separately by
        // Settings before this reconciliation begins.
        try context.save()

        let resolution = try filumaCalendar(settings: settings)
        let calendar = resolution.calendar

        // A created EventKit calendar becomes recoverable before events are
        // written into it. If the local identifier cannot be committed, remove
        // the empty calendar as compensation and report failure.
        if settings.filumaCalendarIdentifier != calendar.calendarIdentifier {
            do {
                try persistExportIdentifiers(
                    calendarIdentifier: calendar.calendarIdentifier,
                    blockIdentifiers: [],
                    settings: settings,
                    context: context,
                    save: save
                )
                recoveryCalendarIdentifier = nil
            } catch let persistenceError {
                if resolution.wasCreated {
                    do {
                        try store.removeCalendar(calendar, commit: true)
                        recoveryCalendarIdentifier = nil
                    } catch let compensationError {
                        recoveryCalendarIdentifier = calendar.calendarIdentifier
                        logger.error(
                            "Calendar compensation failed: \(String(describing: compensationError), privacy: .public)"
                        )
                    }
                }
                throw persistenceError
            }
        }

        let blockDescriptor = FetchDescriptor<ScheduledBlock>()
        let allBlocks = try context.fetch(blockDescriptor)

        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: horizonDays, to: now) ?? now

        // Blocks that should exist as events: active-task work that is
        // incomplete, upcoming, and inside the horizon.
        let exportable = allBlocks.filter {
            !$0.isComplete
                && $0.task?.isComplete == false
                && $0.endTime > now
                && $0.startTime < horizon
        }

        // Existing Filuma-owned events within the horizon.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-86400), end: horizon, calendars: [calendar]
        )
        let existingEvents = store.events(matching: predicate)
        var eventsById = Dictionary(
            existingEvents.compactMap { event in event.eventIdentifier.map { ($0, event) } },
            uniquingKeysWith: { first, _ in first }
        )
        let eventsByBlockId = Dictionary(
            existingEvents.compactMap { event in
                markedBlockID(in: event).map { ($0, event) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var createdEvents: [(block: ScheduledBlock, event: EKEvent)] = []
        var desiredEventIdentifiers: [UUID: String] = [:]

        do {
            for block in exportable {
                let title = block.task?.title ?? "Filuma block"
                let eventId = block.appleCalendarEventId
                let storedEvent = eventId
                    .flatMap { eventsById[$0] ?? store.event(withIdentifier: $0) }
                    .flatMap { event in
                        event.calendar.calendarIdentifier == calendar.calendarIdentifier ? event : nil
                    }
                let matchingEvent = storedEvent ?? eventsByBlockId[block.id].flatMap { event in
                    event.calendar.calendarIdentifier == calendar.calendarIdentifier ? event : nil
                }

                if let event = matchingEvent {
                    let notes = eventNotes(for: block)
                    if event.title != title
                        || event.startDate != block.startTime
                        || event.endDate != block.endTime
                        || event.notes != notes {
                        event.title = title
                        event.startDate = block.startTime
                        event.endDate = block.endTime
                        event.notes = notes
                        try store.save(event, span: .thisEvent, commit: false)
                    }
                    if let identifier = event.eventIdentifier {
                        desiredEventIdentifiers[block.id] = identifier
                        eventsById.removeValue(forKey: identifier)
                    }
                } else {
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    event.title = title
                    event.startDate = block.startTime
                    event.endDate = block.endTime
                    event.notes = eventNotes(for: block)
                    try store.save(event, span: .thisEvent, commit: false)
                    createdEvents.append((block, event))
                }
            }

            // Whatever is left in the calendar no longer matches a block — remove it.
            for (_, orphan) in eventsById {
                try store.remove(orphan, span: .thisEvent, commit: false)
            }

            try store.commit()
        } catch {
            // Drop any uncommitted EventKit changes before the next reconciliation.
            store.reset()
            throw error
        }

        // Event identifiers are only trustworthy after the batch commit
        // succeeds. Persist the complete local mirror separately; if this save
        // fails, the EventKit result remains and the stable block note lets a
        // retry adopt those events without duplicating them.
        for (block, event) in createdEvents {
            if let identifier = event.eventIdentifier {
                desiredEventIdentifiers[block.id] = identifier
            }
        }

        try persistExportIdentifiers(
            calendarIdentifier: calendar.calendarIdentifier,
            blockIdentifiers: allBlocks.map { block in
                (block: block, identifier: desiredEventIdentifiers[block.id])
            },
            settings: settings,
            context: context,
            save: save
        )
    }

    /// Commit only the local export preference. EventKit reconciliation must
    /// start after this returns so a rejected save cannot create or remove
    /// external calendar state behind a lying toggle.
    static func setExportEnabled(
        _ enabled: Bool,
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let originalEnabled = settings.exportToAppleCalendar

        do {
            try context.transaction {
                settings.exportToAppleCalendar = enabled
                try save(context)
            }
        } catch {
            context.rollback()
            settings.exportToAppleCalendar = originalEnabled
            context.processPendingChanges()
            throw error
        }
    }

    /// Remove the Filuma calendar after the disabled preference is durable.
    /// Remote removal happens first; local identifiers are cleared only after
    /// EventKit confirms the result. Either phase can be retried independently.
    static func removeExportedEvents(
        context: ModelContext,
        settings providedSettings: UserSettings? = nil,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let settings = providedSettings ?? UserSettings.fetchOrCreate(in: context)
        try context.save()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw ExportError.calendarAccessUnavailable
        }
        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>())

        let identifier = settings.filumaCalendarIdentifier ?? recoveryCalendarIdentifier
        if let identifier,
           let calendar = store.calendar(withIdentifier: identifier) {
            do {
                try store.removeCalendar(calendar, commit: true)
            } catch {
                store.reset()
                logger.error("Calendar removal failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }

        recoveryCalendarIdentifier = nil
        try persistExportIdentifiers(
            calendarIdentifier: nil,
            blockIdentifiers: blocks.map { (block: $0, identifier: nil) },
            settings: settings,
            context: context,
            save: save
        )
    }

    // MARK: - Internals

    /// Persist EventKit identifiers as one local transaction. This stays
    /// synchronous and intentionally does not wrap any authorization or remote
    /// EventKit work in a SwiftData rollback boundary.
    static func persistExportIdentifiers(
        calendarIdentifier: String?,
        blockIdentifiers: [(block: ScheduledBlock, identifier: String?)],
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let originalCalendarIdentifier = settings.filumaCalendarIdentifier
        let originalBlockIdentifiers = blockIdentifiers.map { update in
            (block: update.block, identifier: update.block.appleCalendarEventId)
        }

        do {
            try context.transaction {
                settings.filumaCalendarIdentifier = calendarIdentifier
                for update in blockIdentifiers {
                    update.block.appleCalendarEventId = update.identifier
                }
                try save(context)
            }
        } catch {
            context.rollback()
            settings.filumaCalendarIdentifier = originalCalendarIdentifier
            for held in originalBlockIdentifiers {
                held.block.appleCalendarEventId = held.identifier
            }
            context.processPendingChanges()
            throw error
        }
    }

    private static func filumaCalendar(settings: UserSettings) throws -> CalendarResolution {
        if let identifier = settings.filumaCalendarIdentifier,
           let existing = store.calendar(withIdentifier: identifier) {
            return CalendarResolution(calendar: existing, wasCreated: false)
        }
        if let identifier = recoveryCalendarIdentifier,
           let recovery = store.calendar(withIdentifier: identifier) {
            return CalendarResolution(calendar: recovery, wasCreated: false)
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Filuma"
        calendar.cgColor = CGColor(red: 0xC1 / 255.0, green: 0x57 / 255.0, blue: 0x1F / 255.0, alpha: 1)
        calendar.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local }
        guard calendar.source != nil else { throw ExportError.noCalendarSource }

        try store.saveCalendar(calendar, commit: true)
        recoveryCalendarIdentifier = calendar.calendarIdentifier
        return CalendarResolution(calendar: calendar, wasCreated: true)
    }

    private static func eventNotes(for block: ScheduledBlock) -> String {
        "\(eventNotePrefix)\(block.id.uuidString)"
    }

    private static func markedBlockID(in event: EKEvent) -> UUID? {
        guard let notes = event.notes,
              let markerRange = notes.range(of: eventNotePrefix) else { return nil }
        let value = notes[markerRange.upperBound...]
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)
        return value.flatMap(UUID.init(uuidString:))
    }
}
