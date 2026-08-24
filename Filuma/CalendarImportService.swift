import Foundation
import EventKit
import SwiftData

/// One-way import of Apple Calendar events as `BusyEvent`s — busy windows the
/// scheduler works around. Events never become tasks. Re-import upserts on the
/// event identifier, so repeated syncs update rather than duplicate.
@MainActor
enum CalendarImportService {

    private struct HeldBusyEventSnapshot {
        let event: BusyEvent
        let source: BusySource
        let sourceId: String
        let title: String
        let startTime: Date
        let endTime: Date
        let calendarName: String?

        init(_ event: BusyEvent) {
            self.event = event
            source = event.source
            sourceId = event.sourceId
            title = event.title
            startTime = event.startTime
            endTime = event.endTime
            calendarName = event.calendarName
        }

        func repair() {
            event.source = source
            event.sourceId = sourceId
            event.title = title
            event.startTime = startTime
            event.endTime = endTime
            event.calendarName = calendarName
        }
    }

    private static let store = EKEventStore()
    static var loadBusyEvents: (ModelContext) throws -> [BusyEvent] = {
        try $0.fetch(FetchDescriptor<BusyEvent>())
    }

    /// How far ahead imported events are mirrored (Google import shares it).
    nonisolated static let horizonDays = 30

    /// Mirror Apple Calendar into BusyEvents, if import is enabled and access
    /// was granted. Safe to call on every foreground.
    static func syncIfEnabled(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard settings.importFromAppleCalendar else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        // A read failure must behave like no refresh, never like an empty
        // mirror. The next foreground activation retries against the durable
        // rows that remain untouched.
        try? syncNow(context: context, settings: settings)
    }

    /// Unconditional sync — caller has verified access.
    static func syncNow(context: ModelContext, settings: UserSettings) throws {
        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: horizonDays, to: now) else { return }

        // Every calendar except Filuma's own export calendar (feedback-loop guard)
        // and any calendar the user excluded.
        let excluded = Set(settings.excludedCalendarIds)
        let calendars = store.calendars(for: .event).filter { calendar in
            calendar.calendarIdentifier != settings.filumaCalendarIdentifier
                && calendar.title != "Filuma"
                && !excluded.contains(calendar.calendarIdentifier)
        }

        let existing = try loadBusyEvents(context)
            .filter { $0.source == .appleCalendar }

        guard !calendars.isEmpty else {
            // Everything excluded: clear whatever was imported before.
            for event in existing { context.delete(event) }
            return
        }

        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: calendars)
        let events = store.events(matching: predicate).filter { !$0.isAllDay }

        var existingById = Dictionary(
            existing.map { ($0.sourceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for event in events {
            guard let identifier = event.eventIdentifier,
                  let start = event.startDate,
                  let end = event.endDate,
                  end > start else { continue }
            // Recurring events share an identifier across occurrences; key on
            // identifier + start so each occurrence is its own busy window.
            let key = "\(identifier)#\(start.timeIntervalSinceReferenceDate)"
            let title = event.title ?? "Busy"

            if let match = existingById.removeValue(forKey: key) {
                match.title = title
                match.startTime = start
                match.endTime = end
                match.calendarName = event.calendar?.title
            } else {
                context.insert(BusyEvent(
                    source: .appleCalendar,
                    sourceId: key,
                    title: title,
                    startTime: start,
                    endTime: end,
                    calendarName: event.calendar?.title
                ))
            }
        }

        // Whatever wasn't matched no longer exists (or fell out of the horizon).
        for (_, orphan) in existingById {
            context.delete(orphan)
        }
    }

    /// Calendars available for import (excluding Filuma's own export calendar),
    /// for the selection UI. Requires calendar access.
    static func availableCalendars(settings: UserSettings) -> [EKCalendar] {
        store.calendars(for: .event)
            .filter {
                $0.calendarIdentifier != settings.filumaCalendarIdentifier
                    && $0.title != "Filuma"
            }
            .sorted {
                ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title)
            }
    }

    /// Commit a per-calendar inclusion choice and its imported busy mirror as
    /// one durable state. If EventKit or SwiftData rejects the refresh, the
    /// visible choice and the existing mirror both remain available for retry.
    static func updateExcludedCalendars(
        _ excludedCalendarIds: [String],
        settings: UserSettings,
        context: ModelContext,
        sync: @MainActor (ModelContext, UserSettings) throws -> Void = { context, settings in
            try syncNow(context: context, settings: settings)
        },
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        // Accept unrelated edits before entering a rollback boundary. This
        // prevents a failed calendar refresh from silently discarding work
        // staged elsewhere in the shared app context.
        try context.save()
        let originalExcludedCalendarIds = settings.excludedCalendarIds
        let normalizedIds = Array(Set(excludedCalendarIds)).sorted()
        let busyEventSnapshots = try loadBusyEvents(context)
            .filter { $0.source == .appleCalendar }
            .map(HeldBusyEventSnapshot.init)

        do {
            try context.transaction {
                settings.excludedCalendarIds = normalizedIds
                try sync(context, settings)
                try save(context)
            }
        } catch {
            context.rollback()
            settings.excludedCalendarIds = originalExcludedCalendarIds
            for snapshot in busyEventSnapshots {
                snapshot.repair()
            }
            context.processPendingChanges()
            throw error
        }
    }

    /// Turn Apple import on only after both the preference and the initial
    /// busy-time mirror are durable. Plan repair happens after this boundary,
    /// so callers may truthfully say the events are safe even if replanning
    /// needs a later foreground retry.
    static func enableImport(
        settings: UserSettings,
        context: ModelContext,
        sync: @MainActor (ModelContext, UserSettings) throws -> Void = { context, settings in
            try syncNow(context: context, settings: settings)
        },
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let originalEnabled = settings.importFromAppleCalendar
        let busyEventSnapshots = try loadBusyEvents(context)
            .filter { $0.source == .appleCalendar }
            .map(HeldBusyEventSnapshot.init)

        do {
            try context.transaction {
                settings.importFromAppleCalendar = true
                try sync(context, settings)
                try save(context)
            }
        } catch {
            context.rollback()
            settings.importFromAppleCalendar = originalEnabled
            for snapshot in busyEventSnapshots {
                snapshot.repair()
            }
            context.processPendingChanges()
            throw error
        }
    }

    /// Turn Apple import off only when both the preference and local mirror
    /// are durable. A failed fetch/save keeps the visible toggle on and leaves
    /// the existing busy rows intact for retry.
    static func disableImport(
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let imported = try loadBusyEvents(context)
            .filter { $0.source == .appleCalendar }
        let originalEnabled = settings.importFromAppleCalendar

        do {
            try context.transaction {
                settings.importFromAppleCalendar = false
                for event in imported {
                    context.delete(event)
                }
                try save(context)
            }
        } catch {
            context.rollback()
            settings.importFromAppleCalendar = originalEnabled
            context.processPendingChanges()
            throw error
        }
    }
}
