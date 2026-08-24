import XCTest
import SwiftData
@testable import Filuma

private final class GoogleCalendarMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class GoogleCalendarTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: SharedStore.schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - PKCE

    func testCodeChallengeMatchesRFC7636Vector() {
        // Appendix B of RFC 7636: the canonical verifier/challenge pair.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            GoogleOAuth.codeChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testRandomVerifierIsURLSafeAndUnique() {
        let a = GoogleOAuth.randomURLSafeString(byteCount: 48)
        let b = GoogleOAuth.randomURLSafeString(byteCount: 48)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isEmpty)
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        XCTAssertTrue(a.unicodeScalars.allSatisfy(allowed.contains))
    }

    // MARK: - id_token parsing

    func testParseEmailFromIdToken() {
        // header.payload.signature with a base64url payload carrying an email.
        let payload = Data(#"{"email":"nick@christoforakis.com","sub":"123"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"
        XCTAssertEqual(GoogleOAuth.parseEmail(fromIdToken: token), "nick@christoforakis.com")
    }

    func testParseEmailRejectsGarbage() {
        XCTAssertNil(GoogleOAuth.parseEmail(fromIdToken: "not-a-jwt"))
        XCTAssertNil(GoogleOAuth.parseEmail(fromIdToken: "a.!!!!.c"))
    }

    // MARK: - Token freshness

    func testTokenFreshness() {
        var tokens = GoogleTokens(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), email: nil
        )
        XCTAssertTrue(tokens.isFresh())
        // Inside the one-minute slack: treated as stale so a request can't
        // ride a token that dies mid-flight.
        tokens.expiresAt = Date().addingTimeInterval(30)
        XCTAssertFalse(tokens.isFresh())
        tokens.expiresAt = Date().addingTimeInterval(-10)
        XCTAssertFalse(tokens.isFresh())
    }

    // MARK: - Import reconciliation

    private func gEvent(
        id: String,
        title: String? = "Busy",
        start: Date?,
        end: Date?,
        status: String? = nil,
        allDayDate: String? = nil,
        filumaTagged: Bool = false
    ) -> GoogleCalendarService.GEvent {
        GoogleCalendarService.GEvent(
            id: id,
            status: status,
            summary: title,
            start: .init(dateTime: start, date: allDayDate),
            end: .init(dateTime: end, date: allDayDate),
            extendedProperties: filumaTagged
                ? .init(private: [GoogleCalendarService.filumaMarkerKey: GoogleCalendarService.filumaMarkerValue])
                : nil
        )
    }

    private func googleBusyEvents() throws -> [BusyEvent] {
        try context.fetch(FetchDescriptor<BusyEvent>())
            .filter { $0.source == .googleCalendar }
    }

    @MainActor
    private func installMockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        GoogleCalendarMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleCalendarMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GoogleCalendarService.urlSession = session
        return session
    }

    @MainActor
    private func installFakeGoogleToken() throws {
        GoogleCalendarService.loadImportAccessToken = { "test-access-token" }
    }

    @MainActor
    private func resetImportTestSeams(session: URLSession) {
        session.invalidateAndCancel()
        GoogleCalendarMockURLProtocol.handler = nil
        GoogleCalendarService.urlSession = .shared
        GoogleCalendarService.saveContext = { try $0.save() }
        GoogleCalendarService.loadBusyEvents = {
            try $0.fetch(FetchDescriptor<BusyEvent>())
        }
        GoogleCalendarService.loadImportAccessToken = {
            try await GoogleOAuth.validAccessToken(
                urlSession: GoogleCalendarService.urlSession
            )
        }
        GoogleCalendarService.loadExportAccessToken = {
            try await GoogleOAuth.validAccessToken(
                urlSession: GoogleCalendarService.urlSession
            )
        }
        GoogleTokenStore.clear()
    }

    @MainActor
    func testImportInsertsNewEvents() throws {
        let start = Date().addingTimeInterval(3600)
        let changes = try GoogleCalendarService.reconcileImport(
            events: [gEvent(id: "e1", title: "Dentist", start: start, end: start.addingTimeInterval(1800))],
            fullSync: true,
            context: context
        )
        XCTAssertEqual(changes, 1)
        let imported = try googleBusyEvents()
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.title, "Dentist")
        XCTAssertEqual(imported.first?.sourceId, "e1")
    }

    @MainActor
    func testImportUpsertsOnEventId() throws {
        let start = Date().addingTimeInterval(3600)
        context.insert(BusyEvent(
            source: .googleCalendar, sourceId: "e1", title: "Old title",
            startTime: start, endTime: start.addingTimeInterval(1800)
        ))

        let newStart = start.addingTimeInterval(7200)
        try GoogleCalendarService.reconcileImport(
            events: [gEvent(id: "e1", title: "Moved", start: newStart, end: newStart.addingTimeInterval(1800))],
            fullSync: false,
            context: context
        )
        let imported = try googleBusyEvents()
        XCTAssertEqual(imported.count, 1, "Upsert must never duplicate")
        XCTAssertEqual(imported.first?.title, "Moved")
        XCTAssertEqual(imported.first?.startTime, newStart)
    }

    @MainActor
    func testImportHonorsCancellations() throws {
        let start = Date().addingTimeInterval(3600)
        context.insert(BusyEvent(
            source: .googleCalendar, sourceId: "e1", title: "Dentist",
            startTime: start, endTime: start.addingTimeInterval(1800)
        ))

        try GoogleCalendarService.reconcileImport(
            events: [gEvent(id: "e1", start: nil, end: nil, status: "cancelled")],
            fullSync: false,
            context: context
        )
        XCTAssertTrue(try googleBusyEvents().isEmpty)
    }

    @MainActor
    func testImportSkipsAllDayAndFilumaTaggedEvents() throws {
        let start = Date().addingTimeInterval(3600)
        try GoogleCalendarService.reconcileImport(
            events: [
                gEvent(id: "allday", start: nil, end: nil, allDayDate: "2026-07-11"),
                gEvent(id: "ours", title: "Filuma block", start: start,
                       end: start.addingTimeInterval(1800), filumaTagged: true)
            ],
            fullSync: true,
            context: context
        )
        XCTAssertTrue(try googleBusyEvents().isEmpty, "All-day and Filuma-exported events must not become busy time")
    }

    @MainActor
    func testFullSyncDropsOrphansButIncrementalKeepsThem() throws {
        let start = Date().addingTimeInterval(3600)
        context.insert(BusyEvent(
            source: .googleCalendar, sourceId: "gone", title: "Deleted upstream",
            startTime: start, endTime: start.addingTimeInterval(1800)
        ))

        // Incremental responses only carry deltas: an absent event is not a
        // deletion, so the mirror must survive.
        try GoogleCalendarService.reconcileImport(
            events: [],
            fullSync: false,
            context: context
        )
        XCTAssertEqual(try googleBusyEvents().count, 1)

        // A full window fetch is the whole truth: unmatched means gone.
        try GoogleCalendarService.reconcileImport(
            events: [],
            fullSync: true,
            context: context
        )
        XCTAssertTrue(try googleBusyEvents().isEmpty)
    }

    @MainActor
    func testImportLeavesAppleEventsAlone() throws {
        let start = Date().addingTimeInterval(3600)
        context.insert(BusyEvent(
            source: .appleCalendar, sourceId: "apple-1", title: "Apple event",
            startTime: start, endTime: start.addingTimeInterval(1800)
        ))

        try GoogleCalendarService.reconcileImport(
            events: [],
            fullSync: true,
            context: context
        )
        let apple = try context.fetch(FetchDescriptor<BusyEvent>())
            .filter { $0.source == .appleCalendar }
        XCTAssertEqual(apple.count, 1, "A Google full sync must never touch Apple-sourced busy events")
    }

    @MainActor
    func testImportSaveFailureRollsBackBusyEventsAndSyncToken() async throws {
        try installFakeGoogleToken()
        let responseData = Data(#"""
        {
          "items": [{
            "id": "existing",
            "status": "confirmed",
            "summary": "Changed upstream",
            "start": { "dateTime": "2099-01-01T10:00:00Z" },
            "end": { "dateTime": "2099-01-01T11:00:00Z" }
          }],
          "nextSyncToken": "replacement-token"
        }
        """#.utf8)
        let session = installMockSession { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseData)
        }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        settings.googleSyncToken = "original-token"
        context.insert(BusyEvent(
            source: .googleCalendar,
            sourceId: "existing",
            title: "Original",
            startTime: ISO8601DateFormatter().date(from: "2099-01-01T10:00:00Z")!,
            endTime: ISO8601DateFormatter().date(from: "2099-01-01T11:00:00Z")!
        ))
        try context.save()

        enum ForcedFailure: Error { case save }
        var saveCount = 0
        GoogleCalendarService.saveContext = { context in
            saveCount += 1
            if saveCount == 2 { throw ForcedFailure.save }
            try context.save()
        }

        let result = await GoogleCalendarService.importNow(
            context: context,
            settings: settings
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(saveCount, 2, "Import should checkpoint, then attempt its transaction save")
        XCTAssertEqual(settings.googleSyncToken, "original-token")
        // The strongest autosave guarantee: persist whatever is still pending
        // and prove the durable state matches the pre-import checkpoint.
        try context.save()
        let imported = try googleBusyEvents()
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.sourceId, "existing")
        XCTAssertEqual(imported.first?.title, "Original")
        XCTAssertEqual(settings.googleSyncToken, "original-token")
    }

    @MainActor
    func testReconnectStatusIsDurableAndSaveFailureDoesNotLeakHeldState() async throws {
        enum ExpectedFailure: Error { case save }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        settings.googleNeedsReconnect = false
        try context.save()
        GoogleCalendarService.loadImportAccessToken = {
            throw GoogleAuthError.needsReconnect
        }
        GoogleCalendarService.saveContext = { _ in
            throw ExpectedFailure.save
        }
        defer {
            GoogleCalendarService.saveContext = { try $0.save() }
            GoogleCalendarService.loadImportAccessToken = {
                try await GoogleOAuth.validAccessToken(
                    urlSession: GoogleCalendarService.urlSession
                )
            }
        }

        let rejected = await GoogleCalendarService.importNow(
            context: context,
            settings: settings
        )
        XCTAssertEqual(rejected, .failed)
        XCTAssertFalse(settings.googleNeedsReconnect)
        var fresh = ModelContext(container)
        XCTAssertFalse(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).googleNeedsReconnect)

        GoogleCalendarService.saveContext = { try $0.save() }
        let committed = await GoogleCalendarService.importNow(
            context: context,
            settings: settings
        )
        XCTAssertEqual(committed, .needsReconnect)
        XCTAssertTrue(settings.googleNeedsReconnect)
        fresh = ModelContext(container)
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).googleNeedsReconnect)
    }

    @MainActor
    func testImportMirrorFetchFailureDoesNotAdvanceCursorOrInsert() async throws {
        try installFakeGoogleToken()
        let responseData = Data(#"""
        {
          "items": [{
            "id": "new-event",
            "status": "confirmed",
            "summary": "Should not be inserted",
            "start": { "dateTime": "2099-01-01T10:00:00Z" },
            "end": { "dateTime": "2099-01-01T11:00:00Z" }
          }],
          "nextSyncToken": "replacement-token"
        }
        """#.utf8)
        let session = installMockSession { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseData)
        }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        settings.googleSyncToken = "original-token"
        try context.save()

        enum ForcedFailure: Error { case fetch }
        GoogleCalendarService.loadBusyEvents = { _ in
            throw ForcedFailure.fetch
        }

        let result = await GoogleCalendarService.importNow(
            context: context,
            settings: settings
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(settings.googleSyncToken, "original-token")
        try context.save()
        XCTAssertTrue(try googleBusyEvents().isEmpty)
        XCTAssertEqual(settings.googleSyncToken, "original-token")
    }

    @MainActor
    func testImportPruneFetchFailureRollsBackReconciliationAndCursor() async throws {
        try installFakeGoogleToken()
        let responseData = Data(#"""
        {
          "items": [{
            "id": "existing",
            "status": "confirmed",
            "summary": "Changed upstream",
            "start": { "dateTime": "2099-01-01T10:00:00Z" },
            "end": { "dateTime": "2099-01-01T11:00:00Z" }
          }],
          "nextSyncToken": "replacement-token"
        }
        """#.utf8)
        let session = installMockSession { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseData)
        }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        settings.googleSyncToken = "original-token"
        context.insert(BusyEvent(
            source: .googleCalendar,
            sourceId: "existing",
            title: "Original",
            startTime: ISO8601DateFormatter().date(from: "2099-01-01T10:00:00Z")!,
            endTime: ISO8601DateFormatter().date(from: "2099-01-01T11:00:00Z")!
        ))
        try context.save()

        enum ForcedFailure: Error { case fetch }
        var loadCount = 0
        GoogleCalendarService.loadBusyEvents = { context in
            loadCount += 1
            if loadCount == 2 {
                throw ForcedFailure.fetch
            }
            return try context.fetch(FetchDescriptor<BusyEvent>())
        }

        let result = await GoogleCalendarService.importNow(
            context: context,
            settings: settings
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(settings.googleSyncToken, "original-token")
        try context.save()
        let imported = try googleBusyEvents()
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.title, "Original")
        XCTAssertEqual(settings.googleSyncToken, "original-token")
    }

    @MainActor
    func testDisableImportFailureKeepsPreferenceCursorAndMirrorForRetry() throws {
        enum ExpectedFailure: Error { case save }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        settings.googleSyncToken = "original-token"
        let existing = BusyEvent(
            source: .googleCalendar,
            sourceId: "google-disable-existing",
            title: "Existing meeting",
            startTime: Date().addingTimeInterval(3600),
            endTime: Date().addingTimeInterval(7200)
        )
        context.insert(existing)
        try context.save()

        XCTAssertThrowsError(
            try GoogleCalendarService.disableImport(
                settings: settings,
                context: context,
                save: { _ in throw ExpectedFailure.save }
            )
        )

        XCTAssertTrue(settings.importFromGoogleCalendar)
        XCTAssertEqual(settings.googleSyncToken, "original-token")
        XCTAssertEqual(try googleBusyEvents().map(\.id), [existing.id])
        var fresh = ModelContext(container)
        var durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertTrue(durableSettings.importFromGoogleCalendar)
        XCTAssertEqual(durableSettings.googleSyncToken, "original-token")
        XCTAssertEqual(
            try fresh.fetch(FetchDescriptor<BusyEvent>()).map(\.id),
            [existing.id]
        )

        try GoogleCalendarService.disableImport(
            settings: settings,
            context: context
        )
        fresh = ModelContext(container)
        durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertFalse(durableSettings.importFromGoogleCalendar)
        XCTAssertNil(durableSettings.googleSyncToken)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<BusyEvent>()).isEmpty)
    }

    @MainActor
    func testDisconnectFailureKeepsAccountMirrorAndExportIdsForRetry() throws {
        enum ExpectedFailure: Error { case save }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.exportToGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        settings.googleSyncToken = "original-token"
        let existing = BusyEvent(
            source: .googleCalendar,
            sourceId: "google-disconnect-existing",
            title: "Existing meeting",
            startTime: Date().addingTimeInterval(3600),
            endTime: Date().addingTimeInterval(7200)
        )
        let task = FilumaTask(
            title: "Exported task",
            context: .work,
            deadline: Date().addingTimeInterval(86400),
            effortMinutes: 30
        )
        let block = ScheduledBlock(
            task: task,
            startTime: Date().addingTimeInterval(10800),
            durationMinutes: 30
        )
        block.googleCalendarEventId = "google-export-id"
        context.insert(existing)
        context.insert(task)
        context.insert(block)
        try context.save()

        XCTAssertThrowsError(
            try GoogleCalendarService.disconnect(
                settings: settings,
                context: context,
                save: { _ in throw ExpectedFailure.save }
            )
        )

        XCTAssertTrue(settings.importFromGoogleCalendar)
        XCTAssertTrue(settings.exportToGoogleCalendar)
        XCTAssertEqual(settings.googleAccountEmail, "test@example.com")
        XCTAssertEqual(settings.googleSyncToken, "original-token")
        XCTAssertEqual(block.googleCalendarEventId, "google-export-id")
        XCTAssertEqual(try googleBusyEvents().map(\.id), [existing.id])
        var fresh = ModelContext(container)
        var durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertEqual(durableSettings.googleAccountEmail, "test@example.com")
        XCTAssertEqual(
            try XCTUnwrap(fresh.fetch(FetchDescriptor<ScheduledBlock>()).first)
                .googleCalendarEventId,
            "google-export-id"
        )

        try GoogleCalendarService.disconnect(
            settings: settings,
            context: context
        )
        fresh = ModelContext(container)
        durableSettings = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertNil(durableSettings.googleAccountEmail)
        XCTAssertFalse(durableSettings.importFromGoogleCalendar)
        XCTAssertFalse(durableSettings.exportToGoogleCalendar)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<BusyEvent>()).isEmpty)
        XCTAssertNil(
            try XCTUnwrap(fresh.fetch(FetchDescriptor<ScheduledBlock>()).first)
                .googleCalendarEventId
        )
    }

    @MainActor
    func testConnectionPreferenceSaveFailureDoesNotOrphanVisibleAccountState() throws {
        enum ExpectedFailure: Error { case save }

        let settings = UserSettings.fetchOrCreate(in: context)
        try context.save()

        XCTAssertThrowsError(
            try GoogleCalendarService.commitConnection(
                email: "person@example.com",
                settings: settings,
                context: context,
                save: { _ in throw ExpectedFailure.save }
            )
        )

        XCTAssertNil(settings.googleAccountEmail)
        XCTAssertFalse(settings.importFromGoogleCalendar)
        var fresh = ModelContext(container)
        var durable = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertNil(durable.googleAccountEmail)
        XCTAssertFalse(durable.importFromGoogleCalendar)

        try GoogleCalendarService.commitConnection(
            email: "person@example.com",
            settings: settings,
            context: context
        )
        fresh = ModelContext(container)
        durable = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertEqual(durable.googleAccountEmail, "person@example.com")
        XCTAssertTrue(durable.importFromGoogleCalendar)
        XCTAssertNil(durable.googleSyncToken)
    }

    @MainActor
    func testImportEnablePreferenceSaveFailureKeepsDisabledCursorForRetry() throws {
        enum ExpectedFailure: Error { case save }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.googleAccountEmail = "person@example.com"
        settings.importFromGoogleCalendar = false
        settings.googleSyncToken = "last-durable-cursor"
        try context.save()

        XCTAssertThrowsError(
            try GoogleCalendarService.enableImport(
                settings: settings,
                context: context,
                save: { _ in throw ExpectedFailure.save }
            )
        )

        XCTAssertFalse(settings.importFromGoogleCalendar)
        XCTAssertEqual(settings.googleSyncToken, "last-durable-cursor")
        var fresh = ModelContext(container)
        var durable = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertFalse(durable.importFromGoogleCalendar)
        XCTAssertEqual(durable.googleSyncToken, "last-durable-cursor")

        try GoogleCalendarService.enableImport(
            settings: settings,
            context: context
        )
        fresh = ModelContext(container)
        durable = try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        )
        XCTAssertTrue(durable.importFromGoogleCalendar)
        XCTAssertNil(durable.googleSyncToken)
    }

    @MainActor
    func testExportPreferenceSaveFailureKeepsPriorDurableChoice() throws {
        enum ExpectedFailure: Error { case save }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.googleAccountEmail = "person@example.com"
        try context.save()

        XCTAssertThrowsError(
            try GoogleCalendarService.setExportEnabled(
                true,
                settings: settings,
                context: context,
                save: { _ in throw ExpectedFailure.save }
            )
        )
        XCTAssertFalse(settings.exportToGoogleCalendar)
        var fresh = ModelContext(container)
        XCTAssertFalse(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).exportToGoogleCalendar)

        try GoogleCalendarService.setExportEnabled(
            true,
            settings: settings,
            context: context
        )
        XCTAssertTrue(settings.exportToGoogleCalendar)

        XCTAssertThrowsError(
            try GoogleCalendarService.setExportEnabled(
                false,
                settings: settings,
                context: context,
                save: { _ in throw ExpectedFailure.save }
            )
        )
        XCTAssertTrue(settings.exportToGoogleCalendar)
        fresh = ModelContext(container)
        XCTAssertTrue(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).exportToGoogleCalendar)
    }

    @MainActor
    func testExportFailureCannotRollbackAnUnrelatedSharedContextEdit() async throws {
        let requestStarted = expectation(description: "export request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let session = installMockSession { request in
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 5)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        GoogleCalendarService.loadExportAccessToken = { "test-access-token" }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.googleAccountEmail = "person@example.com"
        settings.exportToGoogleCalendar = true
        let task = FilumaTask(
            title: "Export boundary",
            context: .work,
            deadline: Date().addingTimeInterval(86_400),
            effortMinutes: 30
        )
        let block = ScheduledBlock(
            task: task,
            startTime: Date().addingTimeInterval(3_600),
            durationMinutes: 30
        )
        context.insert(task)
        context.insert(block)
        try context.save()

        let export = Task {
            await GoogleCalendarService.exportNow(
                context: context,
                settings: settings
            )
        }
        await fulfillment(of: [requestStarted], timeout: 5)

        // This edit deliberately remains pending while the network request is
        // suspended. Export owns a separate ModelContext, so its failure may
        // not save or roll this value back.
        settings.dailyFocusMinutes = 321
        releaseRequest.signal()
        let exportResult = await export.value
        XCTAssertEqual(exportResult, .failed)
        XCTAssertEqual(settings.dailyFocusMinutes, 321)

        try context.save()
        let fresh = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).dailyFocusMinutes, 321)
    }

    @MainActor
    func testDisconnectDuringExportCannotRestoreClearedCalendarIds() async throws {
        let requestStarted = expectation(description: "export request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let session = installMockSession { request in
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 5)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"items":[]}"#.utf8))
        }
        GoogleCalendarService.loadExportAccessToken = { "test-access-token" }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.googleAccountEmail = "person@example.com"
        settings.exportToGoogleCalendar = true
        let task = FilumaTask(
            title: "Disconnect export boundary",
            context: .work,
            deadline: Date().addingTimeInterval(86_400),
            effortMinutes: 30
        )
        let block = ScheduledBlock(
            task: task,
            startTime: Date().addingTimeInterval(3_600),
            durationMinutes: 30
        )
        block.googleCalendarEventId = "old-google-event"
        context.insert(task)
        context.insert(block)
        try context.save()

        let export = Task {
            await GoogleCalendarService.exportNow(
                context: context,
                settings: settings
            )
        }
        await fulfillment(of: [requestStarted], timeout: 5)
        try GoogleCalendarService.disconnect(
            settings: settings,
            context: context
        )
        releaseRequest.signal()

        let exportResult = await export.value
        XCTAssertEqual(exportResult, .cancelled)
        XCTAssertNil(block.googleCalendarEventId)
        let fresh = ModelContext(container)
        XCTAssertNil(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<ScheduledBlock>()).first
        ).googleCalendarEventId)
        XCTAssertNil(try XCTUnwrap(
            fresh.fetch(FetchDescriptor<UserSettings>()).first
        ).googleAccountEmail)
    }

    @MainActor
    func testExportSuccessDurablyCommitsCreatedEventIdFromPrivateContext() async throws {
        let session = installMockSession { request in
            let method = request.httpMethod ?? "GET"
            let data = method == "POST"
                ? Data(#"{"id":"google-created-event"}"#.utf8)
                : Data(#"{"items":[]}"#.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        GoogleCalendarService.loadExportAccessToken = { "test-access-token" }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.googleAccountEmail = "person@example.com"
        settings.exportToGoogleCalendar = true
        let task = FilumaTask(
            title: "Durable exported event",
            context: .work,
            deadline: Date().addingTimeInterval(86_400),
            effortMinutes: 30
        )
        let block = ScheduledBlock(
            task: task,
            startTime: Date().addingTimeInterval(3_600),
            durationMinutes: 30
        )
        context.insert(task)
        context.insert(block)
        try context.save()

        let result = await GoogleCalendarService.exportNow(
            context: context,
            settings: settings
        )

        XCTAssertEqual(result, .success)
        let fresh = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(fresh.fetch(FetchDescriptor<ScheduledBlock>()).first)
                .googleCalendarEventId,
            "google-created-event"
        )
    }

    @MainActor
    func testExportPrivateContextSaveFailureLeavesDurableEventIdUnchanged() async throws {
        enum ForcedFailure: Error { case save }

        let requestLock = NSLock()
        var postedEvent = false
        let session = installMockSession { request in
            let method = request.httpMethod ?? "GET"
            if method == "POST" {
                requestLock.withLock { postedEvent = true }
            }
            let data = method == "POST"
                ? Data(#"{"id":"remote-event-without-local-commit"}"#.utf8)
                : Data(#"{"items":[]}"#.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        GoogleCalendarService.loadExportAccessToken = { "test-access-token" }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.googleAccountEmail = "person@example.com"
        settings.exportToGoogleCalendar = true
        let task = FilumaTask(
            title: "Rejected export bookkeeping",
            context: .work,
            deadline: Date().addingTimeInterval(86_400),
            effortMinutes: 30
        )
        let block = ScheduledBlock(
            task: task,
            startTime: Date().addingTimeInterval(3_600),
            durationMinutes: 30
        )
        context.insert(task)
        context.insert(block)
        try context.save()

        let sharedContext = context!
        GoogleCalendarService.saveContext = { saveContext in
            XCTAssertFalse(
                saveContext === sharedContext,
                "Export must never save the shared UI context after a network suspension"
            )
            throw ForcedFailure.save
        }

        let result = await GoogleCalendarService.exportNow(
            context: context,
            settings: settings
        )

        XCTAssertEqual(result, .failed)
        XCTAssertTrue(requestLock.withLock { postedEvent })
        XCTAssertNil(block.googleCalendarEventId)
        let fresh = ModelContext(container)
        XCTAssertNil(
            try XCTUnwrap(fresh.fetch(FetchDescriptor<ScheduledBlock>()).first)
                .googleCalendarEventId
        )
    }

    @MainActor
    func testQueuedExportAwaitsFollowUpFailureInsteadOfQueuedPlaceholder() async throws {
        let firstRequestStarted = expectation(description: "first export request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let requestLock = NSLock()
        var requestCount = 0
        let session = installMockSession { request in
            let currentRequest = requestLock.withLock {
                requestCount += 1
                return requestCount
            }
            if currentRequest == 1 {
                firstRequestStarted.fulfill()
                releaseFirstRequest.wait()
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: currentRequest == 1 ? 200 : 400,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = currentRequest == 1
                ? Data(#"{"items":[]}"#.utf8)
                : Data()
            return (response, data)
        }
        GoogleCalendarService.loadExportAccessToken = { "test-access-token" }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.googleAccountEmail = "person@example.com"
        settings.exportToGoogleCalendar = true
        try context.save()

        let firstExport = Task { @MainActor in
            await GoogleCalendarService.exportNow(
                context: context,
                settings: settings
            )
        }
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        let queuedExport = Task { @MainActor in
            await GoogleCalendarService.exportNow(
                context: context,
                settings: settings
            )
        }
        await Task.yield()
        releaseFirstRequest.signal()

        let firstResult = await firstExport.value
        let queuedResult = await queuedExport.value
        XCTAssertEqual(firstResult, .success)
        XCTAssertEqual(queuedResult, .failed)
        XCTAssertEqual(requestLock.withLock { requestCount }, 2)
    }

    @MainActor
    func testCancelledOldExportStillDrainsNewGenerationQueuedRequest() async throws {
        let firstRequestStarted = expectation(description: "old export request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let requestLock = NSLock()
        var requestCount = 0
        let session = installMockSession { request in
            let currentRequest = requestLock.withLock {
                requestCount += 1
                return requestCount
            }
            if currentRequest == 1 {
                firstRequestStarted.fulfill()
                releaseFirstRequest.wait()
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"items":[]}"#.utf8))
        }
        GoogleCalendarService.loadExportAccessToken = { "test-access-token" }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.googleAccountEmail = "person@example.com"
        settings.exportToGoogleCalendar = true
        try context.save()

        let oldExport = Task { @MainActor in
            await GoogleCalendarService.exportNow(
                context: context,
                settings: settings
            )
        }
        await fulfillment(of: [firstRequestStarted], timeout: 2)

        // Turning export off invalidates the suspended generation. Turning it
        // back on creates a valid new request which must survive even if the
        // old caller task itself is cancelled while draining the queue.
        try GoogleCalendarService.setExportEnabled(
            false,
            settings: settings,
            context: context
        )
        try GoogleCalendarService.setExportEnabled(
            true,
            settings: settings,
            context: context
        )
        let liveExport = Task { @MainActor in
            await GoogleCalendarService.exportNow(
                context: context,
                settings: settings
            )
        }
        await Task.yield()
        oldExport.cancel()
        releaseFirstRequest.signal()

        let oldResult = await oldExport.value
        let liveResult = await liveExport.value
        XCTAssertEqual(oldResult, .cancelled)
        XCTAssertEqual(liveResult, .success)
        XCTAssertEqual(requestLock.withLock { requestCount }, 2)
    }

    @MainActor
    func testConcurrentImportsCoalesceAndAwaitOneFollowUpTerminalResult() async throws {
        try installFakeGoogleToken()
        let firstRequestStarted = expectation(description: "first import request started")
        let secondRequestStarted = expectation(description: "queued import request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let requestLock = NSLock()
        var requestCount = 0
        let session = installMockSession { request in
            let currentRequest = requestLock.withLock {
                requestCount += 1
                return requestCount
            }

            if currentRequest == 1 {
                firstRequestStarted.fulfill()
                releaseFirstRequest.wait()
            } else if currentRequest == 2 {
                secondRequestStarted.fulfill()
            }

            let data = Data(
                "{\"items\":[],\"nextSyncToken\":\"sync-\(currentRequest)\"}".utf8
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        try context.save()

        let firstImport = Task { @MainActor in
            await GoogleCalendarService.importNow(context: context, settings: settings)
        }
        await fulfillment(of: [firstRequestStarted], timeout: 2)

        let queuedImportA = Task { @MainActor in
            await GoogleCalendarService.importNow(context: context, settings: settings)
        }
        let queuedImportB = Task { @MainActor in
            await GoogleCalendarService.importNow(context: context, settings: settings)
        }
        // Both tasks run to their continuation before the first transport is
        // released, deterministically exercising the coalescing path.
        await Task.yield()
        await Task.yield()
        releaseFirstRequest.signal()

        let firstResult = await firstImport.value
        XCTAssertEqual(firstResult, .success)
        await fulfillment(of: [secondRequestStarted], timeout: 2)
        let queuedResultA = await queuedImportA.value
        let queuedResultB = await queuedImportB.value

        let finalRequestCount = requestLock.withLock { requestCount }
        XCTAssertEqual(finalRequestCount, 2, "Concurrent requests should coalesce to one follow-up")
        XCTAssertEqual(queuedResultA, .success)
        XCTAssertEqual(queuedResultB, .success)
        XCTAssertEqual(settings.googleSyncToken, "sync-2", "The queued import should finish")
    }

    @MainActor
    func testQueuedImportReturnsFollowUpFailureInsteadOfQueuedPlaceholder() async throws {
        try installFakeGoogleToken()
        let firstRequestStarted = expectation(description: "first import request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let requestLock = NSLock()
        var requestCount = 0
        let session = installMockSession { request in
            let currentRequest = requestLock.withLock {
                requestCount += 1
                return requestCount
            }
            if currentRequest == 1 {
                firstRequestStarted.fulfill()
                releaseFirstRequest.wait()
            }

            let status = currentRequest == 1 ? 200 : 400
            let data = currentRequest == 1
                ? Data(#"{"items":[],"nextSyncToken":"sync-1"}"#.utf8)
                : Data()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        try context.save()

        let firstImport = Task { @MainActor in
            await GoogleCalendarService.importNow(context: context, settings: settings)
        }
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        let queuedImport = Task { @MainActor in
            await GoogleCalendarService.importNow(context: context, settings: settings)
        }
        await Task.yield()
        releaseFirstRequest.signal()

        let firstResult = await firstImport.value
        let queuedResult = await queuedImport.value
        XCTAssertEqual(firstResult, .success)
        XCTAssertEqual(queuedResult, .failed)
        XCTAssertEqual(requestLock.withLock { requestCount }, 2)
        XCTAssertEqual(settings.googleSyncToken, "sync-1")
    }

    @MainActor
    func testQueuedImportUsesRequestingContextAndSettings() async throws {
        try installFakeGoogleToken()
        let firstRequestStarted = expectation(description: "first context import started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let requestLock = NSLock()
        var requestCount = 0
        let session = installMockSession { request in
            let currentRequest = requestLock.withLock {
                requestCount += 1
                return requestCount
            }
            if currentRequest == 1 {
                firstRequestStarted.fulfill()
                releaseFirstRequest.wait()
            }
            let data = Data(
                "{\"items\":[],\"nextSyncToken\":\"context-\(currentRequest)\"}".utf8
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { resetImportTestSeams(session: session) }

        let firstSettings = UserSettings.fetchOrCreate(in: context)
        firstSettings.importFromGoogleCalendar = true
        firstSettings.googleAccountEmail = "first@example.com"
        try context.save()

        let secondContainer = try ModelContainer(
            for: SharedStore.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let secondContext = ModelContext(secondContainer)
        let secondSettings = UserSettings.fetchOrCreate(in: secondContext)
        secondSettings.importFromGoogleCalendar = true
        secondSettings.googleAccountEmail = "second@example.com"
        try secondContext.save()

        let firstImport = Task { @MainActor in
            await GoogleCalendarService.importNow(
                context: context,
                settings: firstSettings
            )
        }
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        let secondImport = Task { @MainActor in
            await GoogleCalendarService.importNow(
                context: secondContext,
                settings: secondSettings
            )
        }
        await Task.yield()
        releaseFirstRequest.signal()

        let firstResult = await firstImport.value
        let secondResult = await secondImport.value
        XCTAssertEqual(firstResult, .success)
        XCTAssertEqual(secondResult, .success)
        XCTAssertEqual(requestLock.withLock { requestCount }, 2)
        XCTAssertEqual(firstSettings.googleSyncToken, "context-1")
        XCTAssertEqual(secondSettings.googleSyncToken, "context-2")
    }

    @MainActor
    func testInFlightImportInvalidatedByDisableReturnsCancelledNotFailure() async throws {
        try installFakeGoogleToken()
        let requestStarted = expectation(description: "import request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let session = installMockSession { request in
            requestStarted.fulfill()
            releaseRequest.wait()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        try context.save()

        let importTask = Task { @MainActor in
            await GoogleCalendarService.importNow(context: context, settings: settings)
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        try GoogleCalendarService.disableImport(settings: settings, context: context)
        releaseRequest.signal()

        let result = await importTask.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(settings.importFromGoogleCalendar)
    }

    @MainActor
    func testInFlightImportInvalidatedByDisconnectReturnsCancelledNotFailure() async throws {
        try installFakeGoogleToken()
        let requestStarted = expectation(description: "import request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let session = installMockSession { request in
            requestStarted.fulfill()
            releaseRequest.wait()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { resetImportTestSeams(session: session) }

        let settings = UserSettings.fetchOrCreate(in: context)
        settings.importFromGoogleCalendar = true
        settings.googleAccountEmail = "test@example.com"
        try context.save()

        let importTask = Task { @MainActor in
            await GoogleCalendarService.importNow(context: context, settings: settings)
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        try GoogleCalendarService.disconnect(settings: settings, context: context)
        releaseRequest.signal()

        let result = await importTask.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(settings.googleAccountEmail)
    }

    // MARK: - Wire decoding

    @MainActor
    func testEventPageDecodingHandlesGoogleDateFormats() throws {
        let json = """
        {
          "items": [
            {
              "id": "abc",
              "status": "confirmed",
              "summary": "Standup",
              "start": { "dateTime": "2026-07-11T15:00:00-04:00" },
              "end": { "dateTime": "2026-07-11T15:30:00.000-04:00" }
            },
            {
              "id": "allday",
              "start": { "date": "2026-07-12" },
              "end": { "date": "2026-07-13" }
            }
          ],
          "nextSyncToken": "sync-123"
        }
        """
        let page = try GoogleCalendarService.decoder.decode(
            GoogleCalendarService.GEventsPage.self, from: Data(json.utf8)
        )
        XCTAssertEqual(page.items?.count, 2)
        XCTAssertEqual(page.nextSyncToken, "sync-123")
        let timed = page.items?.first
        XCTAssertNotNil(timed?.start?.dateTime)
        XCTAssertNotNil(timed?.end?.dateTime, "Fractional-second RFC 3339 must decode too")
        XCTAssertEqual(
            timed!.end!.dateTime!.timeIntervalSince(timed!.start!.dateTime!),
            1800, accuracy: 1
        )
        let allDay = page.items?.last
        XCTAssertNil(allDay?.start?.dateTime)
        XCTAssertEqual(allDay?.start?.date, "2026-07-12")
    }
}
