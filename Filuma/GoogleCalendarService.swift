import Foundation
import SwiftData

/// Google Calendar treated exactly like the Apple pair: import mirrors the
/// primary calendar's events into `BusyEvent(source: .googleCalendar)` — busy
/// windows the scheduler works around, never tasks — and the opt-in export
/// mirrors ScheduledBlocks into the primary calendar. Incremental imports ride
/// `syncToken` (full window fetch on 410); exported events carry a private
/// `filuma=1` extended property so import can never re-ingest Filuma's own blocks.
@MainActor
enum GoogleCalendarService {

    private static let eventsURL = URL(
        string: "https://www.googleapis.com/calendar/v3/calendars/primary/events"
    )!
    /// Same horizons as the Apple import/export — shared so the two mirrors
    /// can never drift apart.
    nonisolated private static let importHorizonDays = CalendarImportService.horizonDays
    nonisolated private static let exportHorizonDays = CalendarExportService.horizonDays

    /// Loop guard marker on exported events. Nonisolated: read from the
    /// nonisolated GEvent wire type and the test target.
    nonisolated static let filumaMarkerKey = "filuma"
    nonisolated static let filumaMarkerValue = "1"

    /// Injection point for the URLProtocol-mocked test session.
    static var urlSession: URLSession = .shared
    /// Deterministic save-failure seam for transaction tests. Production uses
    /// `ModelContext.save()` directly through this closure.
    static var saveContext: (ModelContext) throws -> Void = { try $0.save() }
    /// Import reconciliation must fail closed when the local mirror cannot be
    /// read. Keeping the loader injectable proves a fetch failure never looks
    /// like an empty calendar or advances the incremental cursor.
    static var loadBusyEvents: (ModelContext) throws -> [BusyEvent] = {
        try $0.fetch(FetchDescriptor<BusyEvent>())
    }
    /// Test seam for import coordination. Keeping token acquisition outside
    /// the queue tests makes those tests deterministic and independent of the
    /// simulator Keychain while production still uses the shared OAuth flow.
    static var loadImportAccessToken: () async throws -> String = {
        try await GoogleOAuth.validAccessToken(urlSession: urlSession)
    }
    /// Export coordination tests use the same deterministic token boundary;
    /// production still resolves the credential from the Keychain.
    static var loadExportAccessToken: () async throws -> String = {
        try await GoogleOAuth.validAccessToken(urlSession: urlSession)
    }

    private static var isImporting = false
    private static var isExporting = false
    private static var importGeneration: UInt = 0
    private static var exportGeneration: UInt = 0
    private static var cleanupGeneration: UInt = 0
    private static var foregroundSyncTask: Task<Void, Never>?
    private static var foregroundSyncTaskId: UUID?
    private static var exportCleanupTask: Task<Void, Never>?
    /// The pending debounced export, so a burst of scheduling changes (bulk
    /// entry, a replan) coalesces into one network reconcile instead of one
    /// per change — unlike the Apple export, this one leaves the device.
    private static var pendingExport: Task<Void, Never>?

    /// Concurrent import requests are serialized because they share the sync
    /// cursor and mirror. Requests for the same context/settings pair coalesce
    /// into one follow-up, but every caller awaits that follow-up's terminal
    /// result. Different pairs remain distinct so queued work can never run
    /// against the active request's context by accident.
    private struct QueuedImport {
        let generation: UInt
        let context: ModelContext
        let settings: UserSettings
        var waiters: [CheckedContinuation<SyncResult, Never>]
    }
    private static var queuedImports: [QueuedImport] = []

    /// Export reconciliation also touches a durable cursor on ScheduledBlock.
    /// Busy callers therefore await one coalesced follow-up owned by their own
    /// context/settings pair instead of receiving a placeholder while a
    /// fire-and-forget retry runs against somebody else's context.
    private struct QueuedExport {
        let generation: UInt
        let context: ModelContext
        let settings: UserSettings
        var waiters: [CheckedContinuation<SyncResult, Never>]
    }
    private static var queuedExports: [QueuedExport] = []

    enum GoogleCalendarError: Error {
        case syncTokenExpired // HTTP 410: fall back to a full window fetch
        case http(Int)
        case missingSettings
    }

    /// Foreground/background callers share the same transport, but only a
    /// user-triggered Settings action needs to surface the outcome. Background
    /// callers may intentionally ignore this result and retry next foreground.
    enum SyncResult: Equatable {
        case success
        /// Retained for compatibility with older callers. Current import and
        /// export requests await their coalesced follow-up's terminal result.
        case queued
        case disabled
        case needsReconnect
        case cancelled
        case failed
    }

    // MARK: - Wire model

    struct GEventTime: Codable, Equatable {
        var dateTime: Date?
        /// All-day events carry a bare `date` instead — skipped, like the
        /// Apple import skips `isAllDay`.
        var date: String?
    }

    struct GExtendedProperties: Codable, Equatable {
        var `private`: [String: String]?
    }

    struct GEvent: Codable, Equatable {
        var id: String
        var status: String?
        var summary: String?
        var start: GEventTime?
        var end: GEventTime?
        var extendedProperties: GExtendedProperties?

        var isFilumaExport: Bool {
            extendedProperties?.`private`?[filumaMarkerKey] == filumaMarkerValue
        }
    }

    struct GEventsPage: Codable {
        var items: [GEvent]?
        var nextPageToken: String?
        var nextSyncToken: String?
    }

    // MARK: - Entry points

    /// Foreground poll — the same hook as the Apple import. Fire-and-forget;
    /// network errors fail silently and the next poll retries.
    static func foregroundSyncIfEnabled(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard settings.googleAccountEmail != nil,
              settings.importFromGoogleCalendar || settings.exportToGoogleCalendar else { return }
        guard foregroundSyncTask == nil else { return }
        let taskId = UUID()
        foregroundSyncTaskId = taskId
        foregroundSyncTask = Task {
            defer {
                if foregroundSyncTaskId == taskId {
                    foregroundSyncTask = nil
                    foregroundSyncTaskId = nil
                }
            }
            if settings.importFromGoogleCalendar {
                await importNow(context: context, settings: settings)
            }
            if !Task.isCancelled, settings.exportToGoogleCalendar {
                // Debounced, so this coalesces with the export the import's
                // replan may have already queued.
                scheduleExport(context: context, settings: settings)
            }
        }
    }

    /// Mirror of `CalendarExportService.syncIfEnabled` — called from the same
    /// scheduling-change call sites, does nothing unless export is on.
    static func exportIfEnabled(context: ModelContext) {
        let settings = UserSettings.fetchOrCreate(in: context)
        guard settings.exportToGoogleCalendar, settings.googleAccountEmail != nil else { return }
        scheduleExport(context: context, settings: settings)
    }

    /// Trailing debounce: each call cancels the previous pending export and
    /// arms a fresh one two seconds out, so the last change in a burst wins.
    private static func scheduleExport(context: ModelContext, settings: UserSettings) {
        cancelExportCleanup()
        pendingExport?.cancel()
        pendingExport = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  settings.exportToGoogleCalendar,
                  settings.googleAccountEmail != nil else { return }
            await exportNow(context: context, settings: settings)
        }
    }

    // MARK: - Import (Google → Filuma)

    @discardableResult
    static func importNow(
        context: ModelContext,
        settings: UserSettings
    ) async -> SyncResult {
        let generation = importGeneration
        guard settings.importFromGoogleCalendar, settings.googleAccountEmail != nil else {
            return .disabled
        }
        guard !isImporting else {
            return await enqueueImport(
                generation: generation,
                context: context,
                settings: settings
            )
        }
        isImporting = true
        let result = await performImport(
            generation: generation,
            context: context,
            settings: settings
        )
        finishImportAndStartNext()
        return result
    }

    private static func performImport(
        generation: UInt,
        context: ModelContext,
        settings: UserSettings
    ) async -> SyncResult {

        do {
            let accessToken = try await loadImportAccessToken()
            try ensureImportIsCurrent(generation, settings: settings)

            var fullSync = settings.googleSyncToken == nil
            var page: (events: [GEvent], nextSyncToken: String?)
            do {
                page = try await fetchEvents(
                    accessToken: accessToken,
                    syncToken: settings.googleSyncToken
                )
                try ensureImportIsCurrent(generation, settings: settings)
            } catch GoogleCalendarError.syncTokenExpired {
                fullSync = true
                page = try await fetchEvents(accessToken: accessToken, syncToken: nil)
                try ensureImportIsCurrent(generation, settings: settings)
            }

            // Establish a clean rollback boundary before touching the mirror.
            // This also preserves unrelated pending edits on the shared context.
            try saveContext(context)
            let previousSyncToken = settings.googleSyncToken
            let previousNeedsReconnect = settings.googleNeedsReconnect
            do {
                _ = try reconcileImport(
                    events: page.events,
                    fullSync: fullSync,
                    context: context
                )
                try pruneStaleBusyEvents(context: context)
                if let nextSyncToken = page.nextSyncToken {
                    settings.googleSyncToken = nextSyncToken
                }
                settings.googleNeedsReconnect = false
                try saveContext(context)
            } catch {
                context.rollback()
                // rollback() restores the store to the checkpoint, but a held
                // model instance can keep serving the stale in-memory value
                // (verified for UserSettings here). Reinstate the cursor
                // explicitly, or the next incremental sync would trust a token
                // for changes this failed import never applied.
                if settings.googleSyncToken != previousSyncToken {
                    settings.googleSyncToken = previousSyncToken
                }
                settings.googleNeedsReconnect = previousNeedsReconnect
                throw error
            }

            // Imported rows and the sync cursor are already durable here.
            // Attempt this even when this page produced no new rows: a prior
            // import may have committed while its conflict repair failed, and
            // the next incremental page must still be able to finish that
            // repair deterministically.
            try PlanCoordinator.replanBusyTimeConflicts(
                context: context,
                interactive: false
            )
            return .success
        } catch GoogleAuthError.needsReconnect {
            guard !Task.isCancelled,
                  importIsCurrent(generation, settings: settings) else {
                return .cancelled
            }
            return persistNeedsReconnect(settings: settings, context: context)
                ? .needsReconnect
                : .failed
        } catch is CancellationError {
            return .cancelled
        } catch {
            // URLSession commonly reports cancellation as URLError.cancelled,
            // not CancellationError. More importantly, a request invalidated
            // by disabling import or disconnecting must never turn into a
            // stale, user-facing Retry failure when its transport completes.
            guard !Task.isCancelled,
                  importIsCurrent(generation, settings: settings) else {
                return .cancelled
            }
            // Background callers stay quiet and retry later; Settings uses the
            // returned result to offer an honest, local Retry row.
            return .failed
        }
    }

    private static func enqueueImport(
        generation: UInt,
        context: ModelContext,
        settings: UserSettings
    ) async -> SyncResult {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled,
                  importIsCurrent(generation, settings: settings) else {
                continuation.resume(returning: .cancelled)
                return
            }

            if let index = queuedImports.firstIndex(where: {
                $0.generation == generation
                    && $0.context === context
                    && $0.settings === settings
            }) {
                queuedImports[index].waiters.append(continuation)
            } else {
                queuedImports.append(QueuedImport(
                    generation: generation,
                    context: context,
                    settings: settings,
                    waiters: [continuation]
                ))
            }
        }
    }

    private static func finishImportAndStartNext() {
        isImporting = false

        while !queuedImports.isEmpty {
            let next = queuedImports.removeFirst()
            guard importIsCurrent(next.generation, settings: next.settings) else {
                resume(next.waiters, returning: .cancelled)
                continue
            }

            isImporting = true
            Task { @MainActor in
                let result = await performImport(
                    generation: next.generation,
                    context: next.context,
                    settings: next.settings
                )
                resume(next.waiters, returning: result)
                finishImportAndStartNext()
            }
            return
        }
    }

    private static func cancelQueuedImports() {
        let pending = queuedImports
        queuedImports.removeAll()
        for request in pending {
            resume(request.waiters, returning: .cancelled)
        }
    }

    private static func resume(
        _ waiters: [CheckedContinuation<SyncResult, Never>],
        returning result: SyncResult
    ) {
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    /// Applies a batch of Google events to the local BusyEvent mirror.
    /// Upserts on the event id; honors cancellations (incremental responses
    /// include them via `showDeleted`); skips all-day events and Filuma's own
    /// exports. On a full sync, anything unmatched no longer exists — or fell
    /// out of the horizon — and is dropped. Returns how many records changed,
    /// so the caller knows whether to replan.
    @discardableResult
    static func reconcileImport(
        events: [GEvent],
        fullSync: Bool,
        context: ModelContext
    ) throws -> Int {
        let existing = try loadBusyEvents(context)
            .filter { $0.source == .googleCalendar }
        var existingById = Dictionary(
            existing.map { ($0.sourceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changes = 0

        for event in events {
            guard !event.isFilumaExport else { continue }

            let cancelled = event.status == "cancelled"
            guard !cancelled,
                  let start = event.start?.dateTime,
                  let end = event.end?.dateTime,
                  end > start else {
                // Cancelled, all-day, or degenerate: drop any local mirror.
                if let match = existingById.removeValue(forKey: event.id) {
                    context.delete(match)
                    changes += 1
                }
                continue
            }

            let title = event.summary ?? "Busy"
            if let match = existingById.removeValue(forKey: event.id) {
                if match.title != title || match.startTime != start || match.endTime != end {
                    changes += 1
                }
                match.title = title
                match.startTime = start
                match.endTime = end
                match.calendarName = "Google"
            } else {
                context.insert(BusyEvent(
                    source: .googleCalendar,
                    sourceId: event.id,
                    title: title,
                    startTime: start,
                    endTime: end,
                    calendarName: "Google"
                ))
                changes += 1
            }
        }

        if fullSync {
            for (_, orphan) in existingById {
                context.delete(orphan)
                changes += 1
            }
        }
        return changes
    }

    /// Incremental syncs never re-deliver events that simply slid into the
    /// past, so sweep those locally — the scheduler only cares about the
    /// future anyway.
    private static func pruneStaleBusyEvents(
        context: ModelContext,
        now: Date = Date()
    ) throws {
        let stale = try loadBusyEvents(context)
            .filter { $0.source == .googleCalendar && $0.endTime < now }
        for event in stale {
            context.delete(event)
        }
    }

    /// Persist the account display state and default import choice after OAuth
    /// succeeds, before any network refresh can fail. If this save is rejected,
    /// Settings clears the newly issued Keychain credentials and remains
    /// visibly disconnected.
    static func commitConnection(
        email: String,
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let originalEmail = settings.googleAccountEmail
        let originalNeedsReconnect = settings.googleNeedsReconnect
        let originalSyncToken = settings.googleSyncToken
        let originalImportEnabled = settings.importFromGoogleCalendar

        do {
            try context.transaction {
                settings.googleAccountEmail = email
                settings.googleNeedsReconnect = false
                settings.googleSyncToken = nil
                settings.importFromGoogleCalendar = true
                try save(context)
            }
        } catch {
            context.rollback()
            settings.googleAccountEmail = originalEmail
            settings.googleNeedsReconnect = originalNeedsReconnect
            settings.googleSyncToken = originalSyncToken
            settings.importFromGoogleCalendar = originalImportEnabled
            context.processPendingChanges()
            throw error
        }

        importGeneration &+= 1
        exportGeneration &+= 1
        cancelQueuedImports()
        cancelQueuedExports()
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncTaskId = nil
    }

    /// Re-enable import and clear its incremental cursor durably before the
    /// asynchronous full-window request begins.
    static func enableImport(
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let originalEnabled = settings.importFromGoogleCalendar
        let originalSyncToken = settings.googleSyncToken

        do {
            try context.transaction {
                settings.importFromGoogleCalendar = true
                settings.googleSyncToken = nil
                try save(context)
            }
        } catch {
            context.rollback()
            settings.importFromGoogleCalendar = originalEnabled
            settings.googleSyncToken = originalSyncToken
            context.processPendingChanges()
            throw error
        }
    }

    /// Save the export preference before starting or stopping remote cleanup.
    /// A rejected save leaves the visible choice and durable behavior at their
    /// previous value.
    static func setExportEnabled(
        _ enabled: Bool,
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let originalEnabled = settings.exportToGoogleCalendar

        do {
            try context.transaction {
                settings.exportToGoogleCalendar = enabled
                try save(context)
            }
        } catch {
            context.rollback()
            settings.exportToGoogleCalendar = originalEnabled
            context.processPendingChanges()
            throw error
        }

        if enabled {
            cancelExportCleanup()
        } else {
            removeExportedEvents(context: context)
        }
    }

    /// Turn Google import off only when the preference and local mirror can be
    /// committed together. A failed read/save leaves import visibly on and
    /// preserves every busy row for a truthful retry.
    static func disableImport(
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let imported = try loadBusyEvents(context)
            .filter { $0.source == .googleCalendar }
        let originalEnabled = settings.importFromGoogleCalendar
        let originalSyncToken = settings.googleSyncToken

        do {
            try context.transaction {
                settings.importFromGoogleCalendar = false
                settings.googleSyncToken = nil
                for event in imported {
                    context.delete(event)
                }
                try save(context)
            }
        } catch {
            context.rollback()
            settings.importFromGoogleCalendar = originalEnabled
            settings.googleSyncToken = originalSyncToken
            context.processPendingChanges()
            throw error
        }

        importGeneration &+= 1
        cancelQueuedImports()
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncTaskId = nil
    }

    private static func ensureImportIsCurrent(
        _ generation: UInt,
        settings: UserSettings
    ) throws {
        try Task.checkCancellation()
        guard importIsCurrent(generation, settings: settings) else {
            throw CancellationError()
        }
    }

    private static func importIsCurrent(
        _ generation: UInt,
        settings: UserSettings
    ) -> Bool {
        generation == importGeneration
            && settings.importFromGoogleCalendar
            && settings.googleAccountEmail != nil
    }

    /// Authentication can fail before the normal import/export checkpoint.
    /// Persist the reconnect state in its own small transaction so a relaunch
    /// still offers the right recovery action and a rejected save cannot leak
    /// a held-only warning.
    private static func persistNeedsReconnect(
        settings: UserSettings,
        context: ModelContext
    ) -> Bool {
        let previousNeedsReconnect = settings.googleNeedsReconnect
        do {
            try saveContext(context)
            do {
                try context.transaction {
                    settings.googleNeedsReconnect = true
                    try saveContext(context)
                }
            } catch {
                context.rollback()
                settings.googleNeedsReconnect = previousNeedsReconnect
                context.processPendingChanges()
                throw error
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Export (Filuma → Google)

    /// Reconcile the primary calendar's Filuma-tagged events with the current
    /// schedule — the same shape as `CalendarExportService.syncNow`: update
    /// on time changes, insert what's missing, delete what no longer matches
    /// a block.
    @discardableResult
    static func exportNow(
        context: ModelContext,
        settings: UserSettings
    ) async -> SyncResult {
        let generation = exportGeneration
        guard settings.exportToGoogleCalendar, settings.googleAccountEmail != nil else {
            return .disabled
        }
        cancelExportCleanup()
        guard !isExporting else {
            return await enqueueExport(
                generation: generation,
                context: context,
                settings: settings
            )
        }
        isExporting = true
        let result = await performExport(
            generation: generation,
            context: context,
            settings: settings
        )
        finishExportAndStartNext()
        return result
    }

    private static func performExport(
        generation: UInt,
        context: ModelContext,
        settings: UserSettings
    ) async -> SyncResult {

        // Remote export suspends repeatedly. Keep its local bookkeeping in a
        // private context so those awaits can never span a rollback/save on
        // the shared UI context and accidentally absorb another user edit.
        let exportContext = ModelContext(context.container)
        exportContext.autosaveEnabled = false
        let settingsID = settings.id

        do {
            let accessToken = try await loadExportAccessToken()
            try ensureExportIsCurrent(generation, settings: settings)

            let now = Date()
            let horizon = Calendar.current.date(byAdding: .day, value: exportHorizonDays, to: now) ?? now

            let allBlocks = try exportContext.fetch(FetchDescriptor<ScheduledBlock>())
            let exportSettings = try exportContext.fetch(
                FetchDescriptor<UserSettings>(
                    predicate: #Predicate { $0.id == settingsID }
                )
            ).first
            guard let exportSettings else {
                throw GoogleCalendarError.missingSettings
            }
            let exportable = allBlocks.filter {
                !$0.isComplete
                    && $0.task?.isComplete == false
                    && $0.endTime > now
                    && $0.startTime < horizon
            }

            // Filuma-tagged events currently on the calendar.
            let existing = try await fetchEvents(
                accessToken: accessToken,
                syncToken: nil,
                timeMin: now.addingTimeInterval(-86400),
                timeMax: horizon,
                filumaTaggedOnly: true
            ).events
            try ensureExportIsCurrent(generation, settings: settings)
            var eventsById = Dictionary(
                existing.filter { $0.status != "cancelled" }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for block in exportable {
                let title = block.task?.title ?? "Filuma block"
                if let eventId = block.googleCalendarEventId,
                   let event = eventsById.removeValue(forKey: eventId) {
                    if event.summary != title
                        || !sameInstant(event.start?.dateTime, block.startTime)
                        || !sameInstant(event.end?.dateTime, block.endTime) {
                        try await writeEvent(
                            path: eventId, method: "PATCH",
                            title: title, start: block.startTime, end: block.endTime,
                            accessToken: accessToken
                        )
                        try ensureExportIsCurrent(generation, settings: settings)
                    }
                } else {
                    let eventId = try await writeEvent(
                        path: nil, method: "POST",
                        title: title, start: block.startTime, end: block.endTime,
                        accessToken: accessToken
                    )
                    try ensureExportIsCurrent(generation, settings: settings)
                    block.googleCalendarEventId = eventId
                }
            }

            // Whatever is left no longer matches a block — remove it.
            for (eventId, _) in eventsById {
                try? await deleteEvent(id: eventId, accessToken: accessToken)
                try ensureExportIsCurrent(generation, settings: settings)
            }
            try ensureExportIsCurrent(generation, settings: settings)
            exportSettings.googleNeedsReconnect = false
            try saveContext(exportContext)
            // The isolated save is authoritative; mirror this one scalar into
            // the held Settings row so the reconnect banner settles at once.
            settings.googleNeedsReconnect = false
            context.processPendingChanges()
            return .success
        } catch GoogleAuthError.needsReconnect {
            guard !Task.isCancelled,
                  exportIsCurrent(generation, settings: settings) else {
                return .cancelled
            }
            return persistNeedsReconnect(settings: settings, context: context)
                ? .needsReconnect
                : .failed
        } catch is CancellationError {
            exportContext.rollback()
            return .cancelled
        } catch {
            exportContext.rollback()
            guard !Task.isCancelled,
                  exportIsCurrent(generation, settings: settings) else {
                return .cancelled
            }
            // Background callers stay quiet and retry later; Settings uses the
            // returned result to offer an honest, local Retry row.
            return .failed
        }
    }

    private static func enqueueExport(
        generation: UInt,
        context: ModelContext,
        settings: UserSettings
    ) async -> SyncResult {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled,
                  exportIsCurrent(generation, settings: settings) else {
                continuation.resume(returning: .cancelled)
                return
            }

            if let index = queuedExports.firstIndex(where: {
                $0.generation == generation
                    && $0.context === context
                    && $0.settings === settings
            }) {
                queuedExports[index].waiters.append(continuation)
            } else {
                queuedExports.append(QueuedExport(
                    generation: generation,
                    context: context,
                    settings: settings,
                    waiters: [continuation]
                ))
            }
        }
    }

    private static func finishExportAndStartNext() {
        isExporting = false

        while !queuedExports.isEmpty {
            let next = queuedExports.removeFirst()
            guard exportIsCurrent(next.generation, settings: next.settings) else {
                resume(next.waiters, returning: .cancelled)
                continue
            }

            isExporting = true
            Task { @MainActor in
                let result = await performExport(
                    generation: next.generation,
                    context: next.context,
                    settings: next.settings
                )
                resume(next.waiters, returning: result)
                finishExportAndStartNext()
            }
            return
        }
    }

    private static func cancelQueuedExports() {
        let pending = queuedExports
        queuedExports.removeAll()
        for request in pending {
            resume(request.waiters, returning: .cancelled)
        }
    }

    /// Delete every exported Filuma event from the calendar and forget the ids
    /// (export switched off). Best effort — matching Apple's behavior of not
    /// blocking the toggle on network success.
    static func removeExportedEvents(context: ModelContext) {
        exportGeneration &+= 1
        cancelQueuedExports()
        pendingExport?.cancel()
        pendingExport = nil
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncTaskId = nil
        exportCleanupTask?.cancel()
        cleanupGeneration &+= 1
        let generation = cleanupGeneration
        exportCleanupTask = Task {
            if let accessToken = try? await GoogleOAuth.validAccessToken(urlSession: urlSession) {
                guard cleanupIsCurrent(generation, context: context) else { return }
                let now = Date()
                let horizon = Calendar.current.date(byAdding: .day, value: exportHorizonDays, to: now) ?? now
                if let existing = try? await fetchEvents(
                    accessToken: accessToken,
                    syncToken: nil,
                    timeMin: now.addingTimeInterval(-86400),
                    timeMax: horizon,
                    filumaTaggedOnly: true
                ).events {
                    guard cleanupIsCurrent(generation, context: context) else { return }
                    for event in existing where event.status != "cancelled" {
                        try? await deleteEvent(id: event.id, accessToken: accessToken)
                        guard cleanupIsCurrent(generation, context: context) else { return }
                    }
                }
            }
            guard cleanupIsCurrent(generation, context: context) else { return }
            clearExportIds(context: context)
            if cleanupGeneration == generation { exportCleanupTask = nil }
        }
    }

    private static func ensureExportIsCurrent(
        _ generation: UInt,
        settings: UserSettings
    ) throws {
        try Task.checkCancellation()
        guard exportIsCurrent(generation, settings: settings) else {
            throw CancellationError()
        }
    }

    private static func exportIsCurrent(
        _ generation: UInt,
        settings: UserSettings
    ) -> Bool {
        generation == exportGeneration
            && settings.exportToGoogleCalendar
            && settings.googleAccountEmail != nil
    }

    private static func cleanupIsCurrent(_ generation: UInt, context: ModelContext) -> Bool {
        let settings = UserSettings.fetchOrCreate(in: context)
        return !Task.isCancelled
            && generation == cleanupGeneration
            && !settings.exportToGoogleCalendar
            && settings.googleAccountEmail != nil
    }

    private static func cancelExportCleanup() {
        cleanupGeneration &+= 1
        exportCleanupTask?.cancel()
        exportCleanupTask = nil
    }

    private static func clearExportIds(context: ModelContext) {
        for block in (try? context.fetch(FetchDescriptor<ScheduledBlock>())) ?? [] {
            block.googleCalendarEventId = nil
        }
        try? context.save()
    }

    // MARK: - Disconnect

    /// Wipes the Keychain tokens, the Google-sourced busy events, and all
    /// sync state. Exported events are left on the calendar (the user can
    /// switch export off first to clean those up).
    static func disconnect(
        settings: UserSettings,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try context.save()
        let imported = try loadBusyEvents(context)
            .filter { $0.source == .googleCalendar }
        let blocks = try context.fetch(FetchDescriptor<ScheduledBlock>())
        let originalImportEnabled = settings.importFromGoogleCalendar
        let originalExportEnabled = settings.exportToGoogleCalendar
        let originalSyncToken = settings.googleSyncToken
        let originalEmail = settings.googleAccountEmail
        let originalNeedsReconnect = settings.googleNeedsReconnect
        let originalExportIds = Dictionary(
            uniqueKeysWithValues: blocks.map { ($0.id, $0.googleCalendarEventId) }
        )

        do {
            try context.transaction {
                settings.importFromGoogleCalendar = false
                settings.exportToGoogleCalendar = false
                settings.googleSyncToken = nil
                settings.googleAccountEmail = nil
                settings.googleNeedsReconnect = false
                for event in imported {
                    context.delete(event)
                }
                for block in blocks {
                    block.googleCalendarEventId = nil
                }
                try save(context)
            }
        } catch {
            context.rollback()
            settings.importFromGoogleCalendar = originalImportEnabled
            settings.exportToGoogleCalendar = originalExportEnabled
            settings.googleSyncToken = originalSyncToken
            settings.googleAccountEmail = originalEmail
            settings.googleNeedsReconnect = originalNeedsReconnect
            for block in blocks {
                block.googleCalendarEventId = originalExportIds[block.id] ?? nil
            }
            context.processPendingChanges()
            throw error
        }

        importGeneration &+= 1
        exportGeneration &+= 1
        cancelQueuedImports()
        cancelQueuedExports()
        cancelExportCleanup()
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundSyncTaskId = nil
        pendingExport?.cancel()
        pendingExport = nil
        GoogleOAuth.disconnect()
    }

    // MARK: - HTTP

    /// Pages through events.list. Incremental when `syncToken` is set (410 →
    /// `.syncTokenExpired`), otherwise a full window fetch — the import
    /// horizon by default, or the given bounds.
    static func fetchEvents(
        accessToken: String,
        syncToken: String?,
        timeMin: Date? = nil,
        timeMax: Date? = nil,
        filumaTaggedOnly: Bool = false
    ) async throws -> (events: [GEvent], nextSyncToken: String?) {
        var events: [GEvent] = []
        var pageToken: String?
        var nextSyncToken: String?

        repeat {
            var queryItems = [
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "singleEvents", value: "true")
            ]
            if let syncToken {
                queryItems.append(URLQueryItem(name: "syncToken", value: syncToken))
                queryItems.append(URLQueryItem(name: "showDeleted", value: "true"))
            } else {
                let now = Date()
                let min = timeMin ?? now
                let max = timeMax
                    ?? Calendar.current.date(byAdding: .day, value: importHorizonDays, to: now)
                    ?? now
                queryItems.append(URLQueryItem(name: "timeMin", value: rfc3339.string(from: min)))
                queryItems.append(URLQueryItem(name: "timeMax", value: rfc3339.string(from: max)))
            }
            if filumaTaggedOnly {
                queryItems.append(URLQueryItem(
                    name: "privateExtendedProperty",
                    value: "\(filumaMarkerKey)=\(filumaMarkerValue)"
                ))
            }
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            var components = URLComponents(url: eventsURL, resolvingAgainstBaseURL: false)!
            components.queryItems = queryItems
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await performRequest(request)
            let status = response.statusCode
            if status == 410 {
                throw GoogleCalendarError.syncTokenExpired
            }
            guard status == 200 else {
                throw GoogleCalendarError.http(status)
            }

            let page = try decoder.decode(GEventsPage.self, from: data)
            events.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
            nextSyncToken = page.nextSyncToken ?? nextSyncToken
        } while pageToken != nil

        return (events, nextSyncToken)
    }

    /// POST (insert) or PATCH (update) one event; returns the event's id.
    /// The response is decoded id-only with a plain decoder, so a date-format
    /// surprise elsewhere in the payload can't lose the id of an event that
    /// was in fact created (which would duplicate it on the next reconcile).
    private struct GEventIdOnly: Decodable {
        let id: String
    }

    @discardableResult
    private static func writeEvent(
        path: String?,
        method: String,
        title: String,
        start: Date,
        end: Date,
        accessToken: String
    ) async throws -> String? {
        var url = eventsURL
        if let path {
            url = eventsURL.appendingPathComponent(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "summary": title,
            "description": "Scheduled by Filuma",
            "start": ["dateTime": rfc3339.string(from: start)],
            "end": ["dateTime": rfc3339.string(from: end)],
            "extendedProperties": ["private": [filumaMarkerKey: filumaMarkerValue]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(request)
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw GoogleCalendarError.http(status)
        }
        return (try? JSONDecoder().decode(GEventIdOnly.self, from: data))?.id
    }

    private static func deleteEvent(id: String, accessToken: String) async throws {
        var request = URLRequest(url: eventsURL.appendingPathComponent(id))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await performRequest(request)
        let status = response.statusCode
        // 404/410: already gone — the goal state, not a failure.
        guard (200..<300).contains(status) || status == 404 || status == 410 else {
            throw GoogleCalendarError.http(status)
        }
    }

    /// Shared Calendar API transport: one forced refresh for a rejected token,
    /// and bounded retries for the statuses Google documents as transient.
    private static func performRequest(
        _ originalRequest: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        var request = originalRequest
        var retriedUnauthorized = false
        var transientAttempts = 0

        // A prior request in this reconciliation may already have refreshed
        // the token. Start with that value instead of provoking another 401.
        if let sentToken = bearerToken(in: request),
           let stored = GoogleTokenStore.load(),
           stored.accessToken != sentToken,
           stored.isFresh() {
            request.setValue("Bearer \(stored.accessToken)", forHTTPHeaderField: "Authorization")
        }

        while true {
            try Task.checkCancellation()
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GoogleCalendarError.http(0)
            }

            if http.statusCode == 401,
               !retriedUnauthorized,
               let rejectedToken = bearerToken(in: request) {
                let refreshedToken = try await GoogleOAuth.refreshAccessToken(
                    rejectedAccessToken: rejectedToken,
                    urlSession: urlSession
                )
                request.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                retriedUnauthorized = true
                continue
            }

            // 429 means the request was rejected before processing — safe to
            // retry any method. A 5xx may have landed AFTER the server
            // committed the work, so only idempotent methods retry: replaying
            // an insert POST could duplicate the calendar event.
            let method = request.httpMethod?.uppercased() ?? "GET"
            let isIdempotent = method != "POST" && method != "PATCH"
            if http.statusCode == 429
                || ((500...599).contains(http.statusCode) && isIdempotent) {
                transientAttempts += 1
                if transientAttempts < 3 {
                    let delay = retryDelay(response: http, attempt: transientAttempts)
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
            }

            return (data, http)
        }
    }

    private static func bearerToken(in request: URLRequest) -> String? {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    private static func retryDelay(response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(retryAfter) {
                return min(max(0, seconds), 30)
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            if let date = formatter.date(from: retryAfter) {
                return min(max(0, date.timeIntervalSinceNow), 30)
            }
        }

        let backoff = 0.5 * pow(2, Double(attempt - 1))
        return min(backoff + Double.random(in: 0...0.25), 8)
    }

    // MARK: - Dates

    /// Google re-normalizes time zones on the way back, so compare instants
    /// with a second of tolerance instead of Date equality.
    private static func sameInstant(_ a: Date?, _ b: Date) -> Bool {
        guard let a else { return false }
        return abs(a.timeIntervalSince(b)) < 1
    }

    nonisolated(unsafe) private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let rfc3339Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = rfc3339.date(from: raw) ?? rfc3339Fractional.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized RFC 3339 date: \(raw)"
            ))
        }
        return decoder
    }()
}
