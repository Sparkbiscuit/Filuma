import SwiftUI
import SwiftData
import OSLog
import Accessibility

/// All automatic rewrites of existing schedule blocks share this gate. A work
/// session owns its reservation until it records attendance; imports may still
/// land while the timer runs, but catch-up and conflict repair wait their turn.
enum AutomaticPlanRefreshPolicy {
    static func canRewriteSchedule(
        activeWorkSession: WorkSessionControlState?
    ) -> Bool {
        activeWorkSession == nil
    }
}

/// A journal is recoverable only while it still names a live task and remains
/// recent enough to be an interrupted session rather than abandoned state.
enum WorkSessionRecovery: Equatable {
    case restore(WorkSessionControlState)
    case discard
    case keep

    static func evaluate(
        journal: WorkSessionControlState?,
        taskExists: Bool?,
        now: Date
    ) -> WorkSessionRecovery {
        guard let journal, journal.taskID != nil else {
            return .discard
        }
        guard let taskExists else { return .keep }
        guard taskExists,
              now.timeIntervalSince(journal.startedAt) < 12 * 3600 else {
            return .discard
        }
        return .restore(journal)
    }
}

/// Runs only when Filuma presents its UI for the first time in this process.
/// Keeping the guard outside view identity prevents a later scene rebuild from
/// reconsidering a session that started after the initial foreground bootstrap.
@MainActor
private enum WorkSessionForegroundCleanup {
    private static var didRun = false

    static func runOnce(
        journal: WorkSessionControlState?,
        taskExists: Bool?,
        now: Date = Date()
    ) -> WorkSessionRecovery? {
        guard !didRun else { return nil }
        didRun = true
        let decision = WorkSessionRecovery.evaluate(
            journal: journal,
            taskExists: taskExists,
            now: now
        )
        switch decision {
        case .discard:
            WorkSessionActivityController.endAll()
        case .keep:
            // The lookup was unavailable, not negative — nothing was consumed,
            // so a later scene bootstrap may try again with a healthy store.
            didRun = false
        case .restore:
            break
        }
        return decision
    }
}

@main
struct FilumaApp: App {
    @UIApplicationDelegateAdaptor(FilumaAppDelegate.self) private var appDelegate

    private static let persistenceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Filuma",
        category: "Persistence"
    )
    private static let uiTestingArgument = "-ui-testing"
    private static let uiTestingSkipOnboardingArgument = "-ui-testing-skip-onboarding"
    private static let uiTestingAccessibilityTextArgument = "-ui-testing-accessibility-text"
    private static let uiTestingSeedCompletionArgument = "-ui-testing-seed-completion"
    private static let uiTestingSeedLibraryArgument = "-ui-testing-seed-library"
    private static let uiTestingSeedFreeBoundaryArgument = "-ui-testing-seed-free-boundary"
    private static let uiTestingSeedScheduleArgument = "-ui-testing-seed-schedule"
    private static let uiTestingSeedUpdateArgument = "-ui-testing-seed-update"
    private static let uiTestingSeedOverdueArgument = "-ui-testing-seed-overdue"

    /// Store lives in the App Group so the widget can read it (SharedStore
    /// migrates any pre-1.2 sandbox store on first launch).
    private let container: ModelContainer
    private let usedFallback: Bool
    @State private var showingPersistenceWarning: Bool
    @State private var proStore: FilumaProStore

    init() {
        let setup = Self.makeContainer()
        container = setup.container
        usedFallback = setup.usedFallback
        _showingPersistenceWarning = State(initialValue: setup.usedFallback)
        _proStore = State(initialValue: FilumaProStore())
    }

    private static func makeContainer() -> (container: ModelContainer, usedFallback: Bool) {
        if CommandLine.arguments.contains(uiTestingArgument) {
            return makeUITestingContainer()
        }

        do {
            return (try SharedStore.makeContainer(), false)
        } catch {
            // Last resort: an in-memory store beats a crash loop, and the
            // on-disk data stays untouched for the next launch to retry.
            let persistentError = error
            persistenceLogger.error(
                "Persistent store could not be opened: \(String(describing: persistentError), privacy: .public)"
            )
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                return (
                    try ModelContainer(for: SharedStore.schema, configurations: [fallback]),
                    true
                )
            } catch {
                fatalError(
                    "Filuma could not create a persistent or in-memory model container. "
                    + "Persistent error: \(persistentError). In-memory error: \(error)"
                )
            }
        }
    }

    /// UI tests get a brand-new store for every process so their first-launch
    /// state cannot depend on the developer's data or another test's run.
    private static func makeUITestingContainer() -> (container: ModelContainer, usedFallback: Bool) {
        // The SwiftData fixture is in memory, but the recoverable timer journal
        // intentionally lives in the shared App Group. Clear that one piece of
        // cross-process state too, otherwise a previous UI-test run can reopen
        // an unrelated task's work session and make the fresh fixture lie.
        WorkSessionControlStore.clear()

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(
                for: SharedStore.schema,
                configurations: [configuration]
            )
            let shouldSkipOnboarding = CommandLine.arguments.contains(
                uiTestingSkipOnboardingArgument
            )
            let shouldSeedUpdate = CommandLine.arguments.contains(uiTestingSeedUpdateArgument)
            let shouldSeedCompletion = CommandLine.arguments.contains(
                uiTestingSeedCompletionArgument
            )
            let shouldSeedLibrary = CommandLine.arguments.contains(
                uiTestingSeedLibraryArgument
            )
            let shouldSeedFreeBoundary = CommandLine.arguments.contains(
                uiTestingSeedFreeBoundaryArgument
            )
            let shouldSeedSchedule = CommandLine.arguments.contains(
                uiTestingSeedScheduleArgument
            )
            let shouldSeedOverdue = CommandLine.arguments.contains(
                uiTestingSeedOverdueArgument
            )
            if shouldSkipOnboarding
                || shouldSeedUpdate
                || shouldSeedCompletion
                || shouldSeedLibrary
                || shouldSeedFreeBoundary
                || shouldSeedSchedule
                || shouldSeedOverdue {
                let context = ModelContext(container)
                let settings = UserSettings()
                settings.hasCompletedOnboarding = true
                context.insert(settings)

                if shouldSeedUpdate {
                    insertUpdateFixture(in: context, settings: settings)
                } else if shouldSeedCompletion {
                    let task = FilumaTask(
                        title: "Finish launch notes",
                        context: .personal,
                        deadline: Date().addingTimeInterval(48 * 3600),
                        effortMinutes: 60,
                        firstStep: "Open the release notes"
                    )
                    task.manualProgressPercent = 40
                    context.insert(task)
                    context.insert(WorkSession(
                        task: task,
                        startedAt: Date().addingTimeInterval(-25 * 60),
                        durationSeconds: 25 * 60
                    ))
                } else if shouldSeedFreeBoundary {
                    insertFreeTierBoundaryFixture(in: context)
                } else if shouldSeedLibrary {
                    insertLibraryFixture(in: context)
                } else if shouldSeedSchedule {
                    insertScheduleFixture(in: context, settings: settings)
                } else if shouldSeedOverdue {
                    insertOverdueFixture(in: context)
                }
                try context.save()
            }
            return (container, false)
        } catch {
            fatalError("Filuma could not create its UI-testing model container: \(error)")
        }
    }

    /// Only the isolated UI test store uses this authored visual QA fixture.
    private static func insertUpdateFixture(in context: ModelContext, settings: UserSettings) {
        let now = Date()
        settings.maxBlockMinutes = 60
        let task = FilumaTask(title: "Study for biochemistry exam", context: .school,
                              deadline: now.addingTimeInterval(8 * 86400), effortMinutes: 240,
                              firstStep: "Review last year’s exams")
        context.insert(task)
        for (index, item) in [("Design project", TaskContext.work), ("Read biology paper", .personal)].enumerated() {
            context.insert(FilumaTask(title: item.0, context: item.1,
                                     deadline: now.addingTimeInterval(Double(4 + index) * 86400), effortMinutes: 120))
        }
        for (index, contextType) in TaskContext.allCases.enumerated() {
            let history = FilumaTask(title: ["Lab notes", "Project outline", "Garden plans"][index], context: contextType,
                                     deadline: now, effortMinutes: 600)
            history.isComplete = true
            history.completedAt = now.addingTimeInterval(-Double(index + 1) * 86400)
            context.insert(history)
            for day in 0..<14 where (day + index) % 5 != 0 {
                let date = Calendar.current.date(byAdding: .day, value: -day, to: now)!
                context.insert(WorkSession(task: history, startedAt: date,
                                           durationSeconds: (20 + (day * 13 + index * 17) % 60) * 60))
            }
        }
    }

    /// A deterministic, local-only shelf of work for hierarchy and disclosure
    /// tests. Production stores never see these fixtures.
    private static func insertLibraryFixture(in context: ModelContext) {
        let now = Date()
        let fixtures: [(String, TaskContext, TimeInterval, Int, Int, String)] = [
            ("Review neuroanatomy notes", .school, 36 * 3600, 90, 30, "Open the cranial nerve diagram"),
            ("Send project brief", .work, 60 * 3600, 45, 0, "Outline the three decisions"),
            ("Book dentist appointment", .personal, 72 * 3600, 30, 0, "Find the office number"),
            ("Plan weekend errands", .personal, 96 * 3600, 45, 20, "List the three stops")
        ]
        for fixture in fixtures {
            let task = FilumaTask(
                title: fixture.0,
                context: fixture.1,
                deadline: now.addingTimeInterval(fixture.2),
                effortMinutes: fixture.3,
                firstStep: fixture.5
            )
            task.manualProgressPercent = fixture.4
            context.insert(task)
        }

        context.insert(Reminder(
            title: "Call Mom",
            dueDate: now.addingTimeInterval(24 * 3600)
        ))

        let completed = FilumaTask(
            title: "Submit chemistry worksheet",
            context: .school,
            deadline: now.addingTimeInterval(-2 * 3600),
            effortMinutes: 30
        )
        completed.isComplete = true
        completed.completedAt = now.addingTimeInterval(-3 * 3600)
        context.insert(completed)
    }

    /// Two active tasks leave exactly one free slot, so the bulk-capture UI
    /// test can exercise the three-task boundary without coupling to Library.
    private static func insertFreeTierBoundaryFixture(in context: ModelContext) {
        let now = Date()
        context.insert(FilumaTask(
            title: "Review launch checklist",
            context: .work,
            deadline: now.addingTimeInterval(48 * 3600),
            effortMinutes: 45,
            firstStep: "Open the release checklist"
        ))
        context.insert(FilumaTask(
            title: "Pick up prescription",
            context: .personal,
            deadline: now.addingTimeInterval(72 * 3600),
            effortMinutes: 30,
            firstStep: "Check the pharmacy hours"
        ))
    }

    /// Calendar-only fixtures exercise the week surface without asking the
    /// bootstrap scheduler to rewrite their times. The awake window crosses
    /// midnight so the test also proves the truthful 0...24 calendar-day axis.
    private static func insertScheduleFixture(
        in context: ModelContext,
        settings: UserSettings
    ) {
        settings.wakeHour = 20
        settings.wakeMinute = 0
        settings.sleepHour = 7
        settings.sleepMinute = 0

        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())

        func fixtureDate(
            weekOffset: Int = 0,
            dayOffset: Int,
            hour: Int,
            minute: Int
        ) -> Date {
            let week = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: weekStart)
                ?? weekStart
            let day = calendar.date(byAdding: .day, value: dayOffset, to: week)
                ?? week
            return calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: day
            ) ?? day
        }

        let fixtures: [(String, String, Date, Date)] = [
            (
                "Early schedule fixture",
                "ui-schedule-early",
                fixtureDate(dayOffset: 1, hour: 5, minute: 30),
                fixtureDate(dayOffset: 1, hour: 6, minute: 15)
            ),
            (
                "Late schedule fixture",
                "ui-schedule-late",
                fixtureDate(dayOffset: 3, hour: 23, minute: 15),
                fixtureDate(dayOffset: 3, hour: 23, minute: 55)
            ),
            (
                "Overnight schedule fixture",
                "ui-schedule-overnight",
                fixtureDate(dayOffset: 4, hour: 23, minute: 30),
                fixtureDate(dayOffset: 5, hour: 1, minute: 30)
            ),
            (
                "Far future schedule fixture",
                "ui-schedule-future",
                fixtureDate(weekOffset: 6, dayOffset: 1, hour: 12, minute: 0),
                fixtureDate(weekOffset: 6, dayOffset: 1, hour: 13, minute: 0)
            )
        ]

        for fixture in fixtures {
            context.insert(BusyEvent(
                source: .appleCalendar,
                sourceId: fixture.1,
                title: fixture.0,
                startTime: fixture.2,
                endTime: fixture.3,
                calendarName: "UI Test Calendar"
            ))
        }
    }

    /// One deterministic overdue decision, isolated from the populated Library
    /// fixture so hierarchy tests do not gain an unrelated guilt-queue row.
    private static func insertOverdueFixture(in context: ModelContext) {
        context.insert(FilumaTask(
            title: "Overdue triage fixture",
            context: .school,
            deadline: Date().addingTimeInterval(-24 * 3600),
            effortMinutes: 60,
            firstStep: "Open the unfinished draft"
        ))
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(proStore)
                .alert("Your data needs a breather", isPresented: $showingPersistenceWarning) {
                    Button("Got it", role: .cancel) {}
                } message: {
                    Text("Your data could not be opened — changes made now won’t be saved. Please close and reopen Filuma to try again.")
                }
        }
        .modelContainer(container)
    }

    @ViewBuilder
    private var rootView: some View {
        let root = MainTabView(usedFallback: usedFallback)
        if CommandLine.arguments.contains(Self.uiTestingAccessibilityTextArgument) {
            root.environment(\.dynamicTypeSize, .accessibility5)
        } else if CommandLine.arguments.contains(Self.uiTestingArgument) {
            // UI-test configurations can leave a simulator at a different
            // system content size. Pin ordinary tests to the default while the
            // dedicated accessibility case opts into the largest layout above.
            root.environment(\.dynamicTypeSize, .large)
                .preferredColorScheme(CommandLine.arguments.contains("-ui-testing-light") ? .light :
                    (CommandLine.arguments.contains("-ui-testing-dark") ? .dark : nil))
        } else {
            root
        }
    }
}

struct MainTabView: View {
    private struct CatchUpRefreshTrigger: Hashable {
        let date: Date?
        let generation: Int
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(FilumaProStore.self) private var proStore
    @Query private var settingsArray: [UserSettings]
    // `endTime` is computed, so SwiftData cannot use it in a fetch sort. The
    // lightweight policy below computes the minimum from this unsorted set.
    @Query private var scheduledBlocks: [ScheduledBlock]
    let usedFallback: Bool
    @State private var selectedTab = 0
    @State private var replanSummary = CatchUpSummary()
    @State private var sessionRequestTaskId: UUID?
    @State private var showingCapture = false
    @State private var catchUpRefreshGeneration = 0
    @State private var lastReplanAnnouncement: CatchUpSummary?
    @State private var lastReplanAnnouncementDate: Date?
    @State private var hasBootstrappedSettings = false
    @State private var bootstrapIssue: String?
    @State private var showingPaywallFeature: ProFeature?

    private var catchUpRefreshTrigger: CatchUpRefreshTrigger {
        CatchUpRefreshTrigger(
            date: SchedulerService.nextCatchUpRefreshDate(blocks: scheduledBlocks),
            generation: catchUpRefreshGeneration
        )
    }

    var body: some View {
        rootContent
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(Color.brand300)
        .animation(
            reduceMotion ? nil : HearthMotion.reduced,
            value: settingsArray.first?.hasCompletedOnboarding
        )
        .sheet(isPresented: $showingCapture) {
            CaptureSheetView(
                onTaskCaptured: { _ in selectTab(0) },
                onReminderCaptured: { _ in selectTab(0) },
                onBulkCaptured: { _ in selectTab(0) }
            )
        }
        .sheet(item: $showingPaywallFeature) { feature in
            FilumaPaywallView(feature: feature)
        }
        .onAppear {
            bootstrap()
            consumePendingSessionRequest()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await proStore.refreshEntitlements() }
                refreshSchedule()
            }
        }
        .onChange(of: proStore.entitlementState) { _, newState in
            switch newState {
            case .pro:
                // A fresh install can finish StoreKit verification after the
                // initial bootstrap. Run the Pro-only imports, recurrence,
                // and publishing immediately instead of waiting for the next
                // foreground transition.
                refreshSchedule()
            case .free:
                reconcileSubscriptionState()
            case .checking:
                break
            }
        }
        // A single cancellable wake-up at the next block boundary keeps an
        // open app honest without battery-heavy interval polling. SwiftData
        // changes automatically cancel and re-arm this for the new plan.
        .task(id: catchUpRefreshTrigger) {
            guard let refreshDate = catchUpRefreshTrigger.date else { return }
            let delay = max(0, refreshDate.timeIntervalSinceNow) + 0.5
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard scenePhase == .active,
                  WorkSessionControlStore.load() == nil else { return }
            refreshMissedBlocksAtBoundary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .filumaOpenWorkSession)) { _ in
            consumePendingSessionRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workSessionControlDidChange)) { _ in
            // If a session held the reservation past its block boundary, its
            // clear notification re-arms the one-shot that deliberately stood
            // aside. Pause/resume writes keep a control snapshot and are quiet.
            guard WorkSessionControlStore.load() == nil,
                  let refreshDate = catchUpRefreshTrigger.date,
                  refreshDate <= Date() else { return }
            catchUpRefreshGeneration &+= 1
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if !hasBootstrappedSettings || settingsArray.isEmpty {
            OnboardingBootstrapView(
                issue: bootstrapIssue,
                onRetry: bootstrap
            )
                .transition(.opacity)
        } else if let settings = settingsArray.first,
                  !settings.hasCompletedOnboarding {
            OnboardingView(settings: settings)
                .transition(.opacity)
        } else {
            appShell
                .transition(.opacity)
        }
    }

    private var appShell: some View {
        mainContent
            .safeAreaInset(
                edge: .bottom,
                spacing: dynamicTypeSize.isAccessibilitySize ? 4 : 0
            ) {
                if dynamicTypeSize.isAccessibilitySize {
                    tabBar
                }
            }
            .overlay(alignment: .bottom) {
                if !dynamicTypeSize.isAccessibilitySize {
                    tabBar
                }
            }
    }

    private var mainContent: some View {
        ZStack {
            Color.filumaBackground
                .ignoresSafeArea()

            // This shell is not mounted until onboarding commits, so the
            // Tasks screen's one-shot first-thread reveal belongs to the
            // moment the new user can actually act on it.
            switch selectedTab {
            case 0:
                TaskListView(
                    replanSummary: $replanSummary,
                    sessionRequestTaskId: $sessionRequestTaskId,
                    onRequestCapture: { showingCapture = true }
                )
            case 1:
                ScheduleView()
            case 2:
                if proStore.isPro {
                    WeaveView()
                } else {
                    ProLockedFeatureView(feature: .weave) {
                        showingPaywallFeature = .weave
                    }
                }
            default:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        HearthTabBar(
            selectedTab: selectedTab,
            onSelect: selectTab,
            onCapture: { showingCapture = true }
        )
    }

    /// Widget taps arrive here: filuma://start-session/<taskId> drops straight
    /// into the work session timer; anything else just opens the app.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "filuma" else { return }
        if url.host == "start-session",
           let idString = url.pathComponents.dropFirst().first,
           let taskId = UUID(uuidString: idString) {
            requestWorkSession(for: taskId)
        } else if url.host == "upgrade" {
            showingPaywallFeature = .general
        } else {
            selectTab(0)
        }
    }

    /// A block-start notification was tapped: jump to Tasks and open the timer.
    private func consumePendingSessionRequest() {
        guard let taskId = FilumaAppDelegate.pendingSessionTaskId else { return }
        FilumaAppDelegate.pendingSessionTaskId = nil
        requestWorkSession(for: taskId)
    }

    private func requestWorkSession(for taskId: UUID) {
        selectTab(0)
        sessionRequestTaskId = taskId
    }

    private func selectTab(_ tab: Int) {
        guard tab != selectedTab else { return }
        selectedTab = tab
    }

    private func bootstrap() {
        // A LiveActivityIntent may launch Filuma's process in the background
        // without opening a UI scene. Cleanup must therefore wait until the
        // user actually opens the app; doing it from FilumaApp.init would inspect
        // the App Group journal before the Lock Screen intent finished writing
        // it. The process-wide foreground guard also keeps a later rebuild of
        // the one supported scene from touching a newly started timer.
        let journal = WorkSessionControlStore.load()
        let taskExists: Bool?
        if usedFallback {
            taskExists = nil
        } else if let taskID = journal?.taskID {
            let descriptor = FetchDescriptor<FilumaTask>(
                predicate: #Predicate { $0.id == taskID && !$0.isComplete }
            )
            do {
                taskExists = try modelContext.fetchCount(descriptor) > 0
            } catch {
                taskExists = nil
            }
        } else {
            taskExists = false
        }
        if case .restore(let journal) = WorkSessionForegroundCleanup.runOnce(
            journal: journal,
            taskExists: taskExists
        ), let taskID = journal.taskID {
            requestWorkSession(for: taskID)
        }

        let settings: UserSettings
        do {
            // A fresh row must be durable before onboarding can mutate it. If
            // this first boundary fails, the branded bootstrap screen keeps a
            // retry action alive instead of stranding the user on a blank gate.
            settings = try OnboardingBootstrapCoordinator.ensureSettings(
                in: modelContext
            )
            bootstrapIssue = nil
            hasBootstrappedSettings = true
        } catch {
            modelContext.rollback()
            modelContext.processPendingChanges()
            hasBootstrappedSettings = false
            bootstrapIssue = "Filuma couldn’t prepare your local setup yet. Nothing was lost—try again."
            return
        }

        // Anyone with existing tasks predates the onboarding flow — don't
        // make them sit through it after an update.
        if !settings.hasCompletedOnboarding {
            let hasExistingTasks: Bool
            do {
                hasExistingTasks = try OnboardingBootstrapCoordinator.hasExistingTasks(
                    in: modelContext
                )
            } catch {
                hasBootstrappedSettings = false
                bootstrapIssue = "Filuma couldn’t verify your existing setup yet. Nothing was changed—try again."
                return
            }

            if hasExistingTasks {
                do {
                    // Existing users should skip a newly introduced first-run
                    // chapter, but only after that migration is durable.
                    try OnboardingCompletionCoordinator.commit(
                        settings,
                        in: modelContext
                    )
                } catch {
                    hasBootstrappedSettings = false
                    bootstrapIssue = "Filuma couldn’t finish preparing this update yet. Nothing was lost—try again."
                    return
                }
            }
        }

        refreshSchedule()
        reconcileSubscriptionState()
    }

    /// Foreground refresh: pull fresh calendar busy times, stamp out any due
    /// recurring tasks, replan missed blocks around everything, then mirror
    /// only a durably committed result back out.
    private func refreshSchedule() {
        if proStore.entitlementState == .pro {
            CalendarImportService.syncIfEnabled(context: modelContext)
            // Google runs async off the same hook; when its import lands
            // changes it replans on its own.
            GoogleCalendarService.foregroundSyncIfEnabled(context: modelContext)
        } else if proStore.entitlementState == .free {
            reconcileSubscriptionState()
        }
        do {
            // The coordinator owns orphan repair, recurrence materialization,
            // catch-up, conflict repair, one save, and one post-commit publish.
            // A running timer is passed through so its reservation remains
            // untouched while a conflict request stays queued for resume.
            let result = try PlanCoordinator.refreshForegroundPlan(
                context: modelContext,
                activeWorkSession: WorkSessionControlStore.load()
            )
            if result.catchUpSummary.adjustedTasks > 0 {
                presentReplanFeedback(result.catchUpSummary)
            }
        } catch {
            // Foreground maintenance retries on the next activation. Silence is
            // truthful here: no plan was committed, published, or announced.
        }
    }

    private func reconcileSubscriptionState() {
        guard proStore.entitlementState == .free else { return }
        do {
            try ProFeatureSuspension.reconcileFreeTier(in: modelContext)
        } catch {
            // The app retries at the next foreground activation. Existing
            // authored tasks and remote calendar events remain untouched.
        }
    }

    /// Lightweight in-app catch-up used at a block boundary. Calendar imports
    /// remain foreground events; this path only replans when elapsed work made
    /// the local plan stale, then immediately updates widgets and nudges.
    private func refreshMissedBlocksAtBoundary() {
        // The timer owns its linked reservation until it records attendance.
        // Its stop path reconciles the task and re-arms this one-shot from the
        // resulting SwiftData change, so catch-up must not race that write.
        guard WorkSessionControlStore.load() == nil else { return }

        do {
            let summary = try PlanCoordinator.catchUpAtBlockBoundary(
                context: modelContext
            )
            guard summary.adjustedTasks > 0 else { return }
            withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
                presentReplanFeedback(summary)
            }
        } catch {
            // Keep the old plan and skip success feedback. The next boundary or
            // foreground activation will retry against durable inputs.
        }
    }

    /// Announces only actual automatic plan changes. The short duplicate gate
    /// prevents a scene activation and boundary wake-up arriving together from
    /// speaking the same result twice, while later refreshes remain audible.
    private func presentReplanFeedback(_ summary: CatchUpSummary) {
        replanSummary = summary

        let now = Date()
        if lastReplanAnnouncement == summary,
           let lastReplanAnnouncementDate,
           now.timeIntervalSince(lastReplanAnnouncementDate) < 10 {
            return
        }

        lastReplanAnnouncement = summary
        self.lastReplanAnnouncementDate = now
        AccessibilityNotification.Announcement(
            summary.accessibilityAnnouncement
        ).post()
    }
}

/// A settings row is created synchronously on first appearance, but SwiftData's
/// query can publish it one frame later. Give that frame a branded, static
/// surface instead of presenting an empty full-screen cover.
@MainActor
enum OnboardingBootstrapCoordinator {
    static func ensureSettings(
        in context: ModelContext,
        fetch: (ModelContext) throws -> [UserSettings] = {
            try $0.fetch(FetchDescriptor<UserSettings>())
        },
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> UserSettings {
        if let settings = try fetch(context).first {
            return settings
        }

        let settings = UserSettings()
        context.insert(settings)
        try save(context)
        return settings
    }

    static func hasExistingTasks(
        in context: ModelContext,
        fetchCount: (ModelContext) throws -> Int = {
            try $0.fetchCount(FetchDescriptor<FilumaTask>())
        }
    ) throws -> Bool {
        try fetchCount(context) > 0
    }
}

private struct OnboardingBootstrapView: View {
    let issue: String?
    var onRetry: () -> Void

    var body: some View {
        ZStack {
            HearthScreenBackground(
                topGlow: 0.16,
                bottomGlow: 0.22,
                embers: 0,
                emberIntensity: 0
            )

            VStack(spacing: 16) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.brand300)
                    .hearthGlow(.brand500, radius: 16, opacity: 0.35)
                    .accessibilityHidden(true)
                Text("Filuma")
                    .font(AppFont.title(24))
                    .foregroundStyle(Color.filumaText)

                if let issue {
                    Text(issue)
                        .font(AppFont.body(14))
                        .foregroundStyle(Color.filumaSubtle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    Button(action: onRetry) {
                        Text("Try again")
                            .primaryButtonStyle()
                    }
                    .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("onboarding.bootstrap.retry")
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Hearthlight tab bar

/// The floating hearth bar: a blurred capsule inset from the screen edges,
/// with an accent pill behind the active tab, a glowing dot beneath it, and
/// the capture FAB sitting slightly proud at the trailing end.
private struct HearthTabBar: View {
    let selectedTab: Int
    var onSelect: (Int) -> Void
    var onCapture: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var selectionNamespace
    @State private var selectionFeedback = 0

    private struct TabSpec {
        let index: Int
        let label: String
        let icon: String
    }

    private let tabs: [TabSpec] = [
        .init(index: 0, label: "Tasks", icon: "line.3.horizontal"),
        .init(index: 1, label: "Schedule", icon: "calendar"),
        .init(index: 2, label: "Weave", icon: "squareshape.split.3x3"),
        .init(index: 3, label: "Settings", icon: "gearshape")
    ]

    var body: some View {
        controls
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(
            reduceMotion ? HearthMotion.reduced : HearthMotion.selection,
            value: selectedTab
        )
        .background(
            RoundedRectangle(
                cornerRadius: dynamicTypeSize.isAccessibilitySize ? 26 : 100,
                style: .continuous
            )
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(Color.filumaSurface)
                        : AnyShapeStyle(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: dynamicTypeSize.isAccessibilitySize ? 26 : 100,
                        style: .continuous
                    )
                        .fill(Color.filumaSurface.opacity(reduceTransparency ? 1 : 0.82))
                )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: dynamicTypeSize.isAccessibilitySize ? 26 : 100,
                style: .continuous
            )
            .stroke(Color.filumaBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.12), radius: 20, y: 8)
        .frame(maxWidth: FilumaLayout.tabBarMaxWidth)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    tabButton(tabs[0])
                    tabButton(tabs[1])
                }
                HStack(spacing: 4) {
                    tabButton(tabs[2])
                    tabButton(tabs[3])
                }
                accessibilityFab
            }
        } else {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.index) { tab in
                    tabButton(tab)
                }

                fab
                    .padding(.leading, 4)
            }
        }
    }

    private func tabButton(_ tab: TabSpec) -> some View {
        let isActive = selectedTab == tab.index

        return Button {
            guard !isActive else { return }
            selectionFeedback &+= 1
            onSelect(tab.index)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(tab.label)
                    .font(AppFont.caption(9))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isActive ? Color.brand300 : Color.filumaSubtle)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.vertical, 4)
            .background { selectionPill(isActive: isActive) }
            .overlay(alignment: .bottom) {
                if isActive {
                    // A smudge of banked light under the active tab, not a dot.
                    Capsule()
                        .fill(Color.brand300)
                        .frame(width: 22, height: 4)
                        .blur(radius: 3)
                        .offset(y: 7)
                        .modifier(SelectionMatchModifier(
                            id: "tab-glow",
                            namespace: selectionNamespace,
                            enabled: !reduceMotion
                        ))
                }
            }
            .contentShape(Capsule())
        }
        .hearthPressStyle(scale: 0.96, pressedOpacity: 0.84)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    @ViewBuilder
    private func selectionPill(isActive: Bool) -> some View {
        if isActive {
            Capsule()
                .fill(Color.brand500.opacity(0.16))
                .overlay(Capsule().stroke(Color.brand300.opacity(0.08), lineWidth: 1))
                .modifier(SelectionMatchModifier(
                    id: "tab-pill",
                    namespace: selectionNamespace,
                    enabled: !reduceMotion
                ))
        }
    }

    private var fab: some View {
        Button(action: onCapture) {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.filumaControlInk)
                .frame(width: 44, height: 44)
                .background(LinearGradient.hearth, in: Circle())
                .overlay(Circle().stroke(Color.filumaControlInk.opacity(0.14), lineWidth: 1))
                .shadow(color: Color.brand500.opacity(0.24), radius: 8, y: 3)
        }
        .hearthPressStyle(scale: 0.94, pressedOpacity: 0.86)
        .offset(y: -2)
        .accessibilityLabel("Capture a task")
        .accessibilityIdentifier("tabBar.capture")
    }

    private var accessibilityFab: some View {
        Button(action: onCapture) {
            Label("Add a task", systemImage: "plus")
                .font(AppFont.caption(9))
                .foregroundStyle(Color.filumaControlInk)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 4)
                .background(LinearGradient.hearth, in: Capsule())
                .overlay(Capsule().stroke(Color.filumaControlInk.opacity(0.14), lineWidth: 1))
                .shadow(color: Color.brand500.opacity(0.22), radius: 7, y: 3)
        }
        .hearthPressStyle(scale: 0.98, pressedOpacity: 0.86)
        .accessibilityLabel("Add a task")
        .accessibilityInputLabels(["Add a task", "Capture a task"])
        .accessibilityIdentifier("tabBar.capture")
    }
}

/// `matchedGeometryEffect` has no disabled flag. Keeping the conditional in a
/// modifier avoids duplicating each selected surface for Reduce Motion.
private struct SelectionMatchModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}
