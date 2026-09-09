import SwiftUI
import SwiftData

/// How far to push the current/next block when the honest answer to
/// "starting now?" is no.
enum BlockPushChoice {
    case thirtyMinutes
    case oneHour
    case tomorrow
}

private struct TaskListReminderRetry {
    let reminderID: UUID
    let mutation: ReminderMutation
}

private struct TaskListNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let reminderRetry: TaskListReminderRetry?

    init(
        title: String,
        message: String,
        reminderRetry: TaskListReminderRetry? = nil
    ) {
        self.title = title
        self.message = message
        self.reminderRetry = reminderRetry
    }
}

/// A single deterministic snapshot for the complete Focus thread. Keeping the
/// time argument explicit makes block-boundary behavior testable and prevents
/// the hero and queue from reading different wall-clock instants.
enum TaskFocusTimeline {
    static func blocks(from tasks: [FilumaTask], at now: Date) -> [ScheduledBlock] {
        tasks
            .filter { !$0.isComplete }
            .flatMap(\.scheduledBlocks)
            .filter {
                !$0.isComplete
                    && $0.endTime > now
                    && $0.task != nil
            }
            .sorted { $0.startTime < $1.startTime }
    }
}

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var navigationDockClearance: CGFloat = 110
    @Query(sort: \FilumaTask.deadline) private var tasks: [FilumaTask]
    @Query(sort: \Reminder.dueDate) private var reminders: [Reminder]
    @Binding var replanSummary: CatchUpSummary
    @Binding var sessionRequestTaskId: UUID?
    let onRequestCapture: () -> Void
    @State private var expandedContexts: Set<TaskContext> = Set(TaskContext.allCases)
    @State private var workSessionTask: FilumaTask?
    @State private var completionReceipt: TaskCompletionReceipt?
    @State private var pendingCompletionReceipt: TaskCompletionReceipt?
    @State private var editingTask: FilumaTask?
    @State private var triageEditTask: FilumaTask?
    @State private var showCompleted = false
    @State private var pushNote: String?
    @State private var taskNotice: TaskListNotice?
    @State private var pendingTaskNotice: TaskListNotice?

    /// List insertions, removals, and disclosure geometry are spatial. Keep the
    /// state change but make it immediate when Reduce Motion is enabled.
    private var stateAnimation: Animation? {
        reduceMotion ? nil : HearthMotion.selection
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection
                        replanBanner
                        focusSection
                        librarySection
                    }
                    .background(alignment: .top) {
                        TodayLandscape().frame(height: 310)
                    }
                    .padding(.bottom, min(navigationDockClearance, 300))
                    .frame(maxWidth: FilumaLayout.readableContentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .hearthScreen()
            }
            .fullScreenCover(
                item: $workSessionTask,
                onDismiss: presentPendingCompletion
            ) { task in
                WorkSessionView(task: task) { receipt in
                    pendingCompletionReceipt = receipt
                    workSessionTask = nil
                }
            }
            .fullScreenCover(
                item: $completionReceipt,
                onDismiss: presentPendingTaskStatus
            ) { receipt in
                TaskCompletionView(receipt: receipt) {
                    completionReceipt = nil
                } onUndo: {
                    let outcome = restoreTask(withID: receipt.taskID)
                    guard outcome.didRestore else { return outcome.message }
                    if let message = outcome.message {
                        pendingTaskNotice = TaskListNotice(
                            title: "A little more time",
                            message: message
                        )
                    }
                    completionReceipt = nil
                    return nil
                }
            }
            .sheet(item: $editingTask) { task in
                TaskEditView(task: task)
                    // SwiftUI presentations can be hosted outside the root
                    // test environment. Forward the inherited size explicitly
                    // so the sheet always matches the invoking Tasks screen.
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
            }
            .sheet(item: $triageEditTask) { task in
                TaskEditView(task: task, emphasizeDeadline: true)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
            }
            .onAppear {
                consumeSessionRequest()
            }
            .onChange(of: sessionRequestTaskId) { _, _ in
                consumeSessionRequest()
            }
            .alert(item: $taskNotice) { notice in
                if let retry = notice.reminderRetry {
                    Alert(
                        title: Text(notice.title),
                        message: Text(notice.message),
                        primaryButton: .default(Text("Try Again")) {
                            retryReminderMutation(retry)
                        },
                        secondaryButton: .cancel(Text("Not Now"))
                    )
                } else {
                    Alert(
                        title: Text(notice.title),
                        message: Text(notice.message),
                        dismissButton: .cancel(Text("OK"))
                    )
                }
            }
        }
    }

    private func consumeSessionRequest() {
        guard let requestedTaskID = sessionRequestTaskId else { return }
        sessionRequestTaskId = nil

        let taskID: UUID
        if let journalTaskID = WorkSessionControlStore.load()?.taskID,
           journalTaskID != requestedTaskID,
           tasks.contains(where: { $0.id == journalTaskID && !$0.isComplete }) {
            // Filuma has one active timer. Route back to its live task so a new
            // request cannot strand the recovery journal behind another task.
            taskID = journalTaskID
        } else {
            taskID = requestedTaskID
        }
        if let task = tasks.first(where: { $0.id == taskID && !$0.isComplete }) {
            workSessionTask = task
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(AppFont.caption(13))
                    .foregroundStyle(Color.brand300)
                Text("Today")
                    .font(AppFont.display(36))
                    .foregroundStyle(Color.filumaText)
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(AppFont.body(13))
                    .foregroundStyle(Color.filumaSubtle)
            }
            Spacer()
            // The flame pill counts what's alive on the loom right now.
            let activeCount = tasks.filter { !$0.isComplete }.count
            if activeCount > 0 {
                ActiveCountPill(count: activeCount)
            }
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 16)
        .padding(.bottom, 26)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        else if hour < 17 { return "Good afternoon" }
        else { return "Good evening" }
    }

    // MARK: - Screen hierarchy

    /// Populated Tasks has two jobs with intentionally different visual
    /// weight: Focus removes the next decision; Library keeps everything else
    /// findable without competing with the current thread.
    @ViewBuilder
    private var focusSection: some View {
        // Hero, continuation, and queue all read the same clock snapshot. A
        // block boundary therefore advances the whole thread atomically rather
        // than briefly showing the new hero again under Up Next.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let candidates = TaskFocusTimeline.blocks(from: tasks, at: timeline.date)

            if let heroBlock = candidates.first,
               let heroTask = heroBlock.task {
                VStack(spacing: 0) {
                    heroSection(
                        task: heroTask,
                        block: heroBlock,
                        now: timeline.date,
                        hasFollowingBlock: candidates.count > 1
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tasks.section.focus")
                    pushBanner
                    upNextThreadSection(blocks: Array(candidates.dropFirst().prefix(3)))
                }
            }
        }
    }

    @ViewBuilder
    private var librarySection: some View {
        let hasPendingWork = tasks.contains { !$0.isComplete }
            || reminders.contains { !$0.isComplete }

        if hasPendingWork {
            sectionHeading(
                "Library",
                subtitle: "Every active commitment, grouped by context",
                identifier: "tasks.section.library"
            )
        }
        statsBar
        overdueTriageSection
        remindersSection
        taskSections
        completedSection
    }

    private func sectionHeading(
        _ title: String,
        subtitle: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppFont.heading(19))
                .foregroundStyle(Color.filumaText)
            Text(subtitle)
                .font(AppFont.body(12))
                .foregroundStyle(Color.filumaFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Right Now hero

    /// The one-glance answer to "what should I be doing this minute?" — the
    /// running block if there is one, else the next upcoming block, with a
    /// single big Start button. Opening the app should never require a decision.
    private func heroSection(
        task: FilumaTask,
        block: ScheduledBlock,
        now: Date,
        hasFollowingBlock: Bool
    ) -> some View {
        RightNowCard(
            task: task,
            block: block,
            now: now,
            showsThreadContinuation: hasFollowingBlock && pushNote == nil,
            onStart: { workSessionTask = task },
            onPush: { choice in push(task: task, choice: choice) }
        )
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.bottom, 4)
    }

    // MARK: - Up next (the glowing thread)

    /// The thread of light connecting "now" to what comes after: the next few
    /// scheduled blocks beyond the hero, each row's context dot breaking
    /// through the thread.
    @ViewBuilder
    private func upNextThreadSection(blocks: [ScheduledBlock]) -> some View {
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("UP NEXT")
                    .font(AppFont.caption(11))
                    .foregroundStyle(Color.filumaSubtle)
                    .kerning(1.2)
                    .padding(.leading, 34)
                    .padding(.bottom, 10)

                VStack(spacing: 10) {
                    ForEach(blocks) { block in
                        if let task = block.task {
                            UpNextThreadRow(task: task, block: block) {
                                workSessionTask = task
                            } onEdit: {
                                editingTask = task
                            }
                        }
                    }
                }
                .padding(.leading, 20)
            }
            // Size the light from the whole section, not a fixed estimate of
            // the header's height. It therefore stays continuous with larger
            // text, split-view iPad widths, and taller wrapped rows.
            .background(alignment: .topLeading) {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [Color.brand300.opacity(0.75), Color.brand300.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 2, height: geometry.size.height + 18)
                    // The hero contributes 4pt bottom spacing and this
                    // section contributes 14pt top spacing. Reaching through
                    // both makes the two strokes overlap instead of merely
                    // appearing close at one text size.
                    .offset(x: 6, y: -18)
                    .hearthGlow(.brand500, radius: 5, opacity: 0.5)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, FilumaSpacing.screen)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
    }

    /// Transient confirmation after a block push — tap to dismiss.
    @ViewBuilder
    private var pushBanner: some View {
        if let note = pushNote {
            Button {
                withAnimation(stateAnimation) { pushNote = nil }
            } label: {
                InfoBanner(icon: "arrow.uturn.forward", text: note)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .padding(.horizontal, FilumaSpacing.screen)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Dismisses this message")
        }
    }

    /// "Can't right now" — move the task's plan without shame or ceremony.
    /// The whole task replans from the chosen start, so the deadline math
    /// stays honest instead of one orphaned block landing somewhere random.
    private func push(task: FilumaTask, choice: BlockPushChoice) {
        let calendar = Calendar.current

        let start: Date
        switch choice {
        case .thirtyMinutes:
            start = Date().addingTimeInterval(30 * 60)
        case .oneHour:
            start = Date().addingTimeInterval(3600)
        case .tomorrow:
            let existingSettings: UserSettings?
            do {
                existingSettings = try modelContext
                    .fetch(FetchDescriptor<UserSettings>())
                    .first
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                taskNotice = TaskListNotice(
                    title: "Plan not moved",
                    message: "Filuma couldn’t read your planning day yet. Your existing plan is unchanged—try again."
                )
                return
            }
            let defaults = UserSettingsSchedulingDefaults.fresh
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
            start = tomorrow.flatMap {
                calendar.date(
                    bySettingHour: existingSettings?.wakeHour ?? defaults.wakeHour,
                    minute: existingSettings?.wakeMinute ?? defaults.wakeMinute,
                    second: 0, of: $0
                )
            } ?? Date().addingTimeInterval(24 * 3600)
        }

        let result: ScheduleResult
        do {
            result = try PlanCoordinator.rescheduleTask(
                task,
                context: modelContext,
                from: start
            )
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            taskNotice = TaskListNotice(
                title: "Plan not moved",
                message: "Filuma couldn’t move this task yet. Your existing plan is unchanged—try again."
            )
            return
        }

        withAnimation(stateAnimation) {
            switch result {
            case .success(let blocks):
                if let next = blocks.min(by: { $0.startTime < $1.startTime }) {
                    pushNote = "Pushed. Next block \(relativeTime(next.startTime))."
                } else {
                    pushNote = "Pushed — nothing left to schedule."
                }
            case .partialFit:
                pushNote = "Pushed, but not everything fits before the deadline now. Consider extending it."
            case .noSlots:
                pushNote = "Pushed, but no room remains before the deadline — extend it or trim the estimate."
            }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = TimeFormatter.clock.string(from: date)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return "\(formatter.string(from: date)) at \(time)"
    }

    // MARK: - Overdue triage

    /// Tasks whose deadline slipped by. Left alone they'd sit in the list
    /// reading "Past due" forever — a guilt pile. Force one of three kind
    /// exits instead: reschedule, mark done, or deliberately drop it.
    @ViewBuilder
    private var overdueTriageSection: some View {
        let overdue = overdueTasks
        if !overdue.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.filumaRed)
                        .accessibilityHidden(true)
                    Text("Needs a decision")
                        .font(AppFont.heading(15))
                        .foregroundStyle(Color.filumaText)
                    Text("\(overdue.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.filumaFaint)
                    Spacer()
                }
                .accessibilityElement(children: .combine)

                Text("These slipped past their deadline. It happens — pick a path for each and move on.")
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.filumaSubtle)

                ForEach(overdue) { task in
                    OverdueTriageRow(
                        task: task,
                        onNewDeadline: { triageEditTask = task },
                        onComplete: { completeTask(task) },
                        onLetGo: { letGo(task) }
                    )
                }
            }
            .padding(.horizontal, FilumaSpacing.screen)
            .padding(.bottom, 16)
        }
    }

    private var overdueTasks: [FilumaTask] {
        tasks
            .filter { !$0.isComplete && $0.deadline <= Date() }
            .sorted { $0.deadline < $1.deadline }
    }

    /// Deliberately dropping a task is a decision, not a failure.
    private func letGo(_ task: FilumaTask) {
        do {
            try PlanCoordinator.deleteTask(task, context: modelContext)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            taskNotice = TaskListNotice(
                title: "Task not removed",
                message: "Filuma couldn’t remove that task yet. It is still safely in your plan—try again."
            )
        }
    }

    // MARK: - Stats Bar

    @ViewBuilder
    private var statsBar: some View {
        let incomplete = tasks.filter { !$0.isComplete }
        let unscheduled = incomplete.filter { !$0.isFullyScheduled }
        let todayBlocks = todayBlockCount

        if !incomplete.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatPill(
                        value: "\(todayBlocks)",
                        label: todayBlocks == 1 ? "block today" : "blocks today",
                        color: .schoolColor
                    )
                    if !unscheduled.isEmpty {
                        StatPill(
                            value: "\(unscheduled.count)",
                            label: unscheduled.count == 1 ? "needs time" : "need time",
                            color: .filumaRed
                        )
                    }
                    Spacer()
                }
                paceSummary
            }
            .padding(.horizontal, FilumaSpacing.screen)
            .padding(.bottom, 16)
        }
    }

    /// One honest sentence about the most-pressured task — the early warning
    /// that fires days before anything turns red.
    @ViewBuilder
    private var paceSummary: some View {
        if let (taskId, entry) = PaceCache.worst(context: modelContext),
           entry.pressure >= 0.5,
           let task = tasks.first(where: { $0.id == taskId && !$0.isComplete }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.level == .critical ? Color.filumaRed : Color.workColor)
                    .padding(.top, 1)
                Text(paceLine(task: task, entry: entry))
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.filumaSubtle)
            }
        }
    }

    private func paceLine(task: FilumaTask, entry: PaceCache.Entry) -> String {
        guard !entry.pressure.isInfinite, entry.availableMinutes > 0 else {
            return "\(task.title) no longer fits before its deadline — extend it or trim the estimate."
        }
        let need = CountdownFormatter.effortString(minutes: entry.remainingMinutes)
        let free = CountdownFormatter.effortString(minutes: entry.availableMinutes)
        if entry.level == .critical {
            return "\(task.title) needs \(need) of the \(free) you have free — start today."
        }
        return "\(task.title) needs \(need) of the \(free) free before its deadline."
    }

    private var todayBlockCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return 0 }

        return tasks.flatMap { $0.scheduledBlocks }
            .filter { !$0.isComplete && $0.startTime >= today && $0.startTime < tomorrow }
            .count
    }

    // MARK: - Replan banner

    @ViewBuilder
    private var replanBanner: some View {
        if replanSummary.adjustedTasks > 0 {
            Button {
                withAnimation(stateAnimation) { replanSummary = CatchUpSummary() }
            } label: {
                VStack(spacing: 10) {
                    InfoBanner(
                        icon: "arrow.triangle.2.circlepath",
                        text: replanSummary.feedbackMessage
                    )
                    if let warningMessage = replanSummary.warningMessage {
                        InfoBanner(
                            icon: "exclamationmark.triangle.fill",
                            text: warningMessage,
                            tint: .filumaRed
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, FilumaSpacing.screen)
            .padding(.bottom, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(replanSummary.accessibilityAnnouncement)
            .accessibilityHint("Dismisses this message")
        }
    }

    // MARK: - Reminders

    @ViewBuilder
    private var remindersSection: some View {
        let pending = reminders.filter { !$0.isComplete }
        if !pending.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.brand500)
                        .accessibilityHidden(true)
                    Text("Reminders")
                        .font(AppFont.heading(15))
                        .foregroundStyle(Color.filumaText)
                    Text("\(pending.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.filumaFaint)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .padding(.horizontal, FilumaSpacing.screen)
                .padding(.vertical, 12)

                VStack(spacing: 10) {
                    ForEach(pending) { reminder in
                        ReminderRow(reminder: reminder) {
                            completeReminder(reminder)
                        } onDelete: {
                            deleteReminder(reminder)
                        }
                        .padding(.horizontal, FilumaSpacing.screen)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    private func completeReminder(_ reminder: Reminder) {
        applyReminderMutation(.complete, to: reminder)
    }

    private func deleteReminder(_ reminder: Reminder) {
        applyReminderMutation(.delete, to: reminder)
    }

    // MARK: - Task Sections (grouped by context)

    @ViewBuilder
    private var taskSections: some View {
        // Overdue tasks live in the triage section above, not here — the whole
        // point is that the pile can't silently accumulate in the regular list.
        let now = Date()
        let allIncomplete = tasks.filter { !$0.isComplete }
        let incomplete = allIncomplete.filter { $0.deadline > now }
        let sorted = incomplete.sorted { lhs, rhs in
            let lhsNext = lhs.nextBlock?.startTime ?? Date.distantFuture
            let rhsNext = rhs.nextBlock?.startTime ?? Date.distantFuture
            return lhsNext < rhsNext
        }

        if allIncomplete.isEmpty {
            if tasks.isEmpty && reminders.isEmpty {
                FirstTaskEmptyState {
                    onRequestCapture()
                }
            } else {
                let hasPendingReminders = reminders.contains { !$0.isComplete }
                EmptyStateView(
                    icon: hasPendingReminders ? "calendar.badge.clock" : "checkmark",
                    title: hasPendingReminders ? "No tasks waiting" : "All clear",
                    subtitle: hasPendingReminders
                        ? "Your reminders are above. Add a task when it needs time on your schedule."
                        : "Nothing needs your attention right now.",
                    actionLabel: "Add a task",
                    action: onRequestCapture
                )
                .padding(.top, 24)
            }
        } else {
            ForEach(TaskContext.allCases) { context in
                let contextTasks = sorted.filter { $0.context == context }
                if !contextTasks.isEmpty {
                    contextSection(context: context, tasks: contextTasks)
                }
            }
        }
    }

    private func contextSection(context: TaskContext, tasks: [FilumaTask]) -> some View {
        let isExpanded = expandedContexts.contains(context)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(stateAnimation) {
                    if isExpanded {
                        expandedContexts.remove(context)
                    } else {
                        expandedContexts.insert(context)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: context.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(context.color)
                        .accessibilityHidden(true)
                    Text(context.rawValue)
                        .font(AppFont.heading(15))
                        .foregroundStyle(Color.filumaText)
                    Text("\(tasks.count)")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.filumaFaint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.filumaFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel(
                "\(context.rawValue), \(tasks.count) \(tasks.count == 1 ? "task" : "tasks")"
            )
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses this task group" : "Expands this task group")
            .accessibilityIdentifier("tasks.context.\(context.rawValue.lowercased())")

            CollapsibleSectionBody(isExpanded: isExpanded) {
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            Divider()
                                .overlay(Color.filumaBorder)
                                .padding(.leading, 16)
                        }
                        TaskRowView(
                            task: task,
                            onStartSession: { workSessionTask = task },
                            onComplete: { completeTask(task) },
                            onEdit: { editingTask = task }
                        )
                    }
                }
                .background(Color.filumaSurface)
                .clipShape(
                    RoundedRectangle(cornerRadius: FilumaRadius.group, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FilumaRadius.group, style: .continuous)
                        .stroke(Color.filumaBorder, lineWidth: 1)
                }
            }
        }
        .padding(.horizontal, FilumaSpacing.screen)
    }

    // MARK: - Completed section

    @ViewBuilder
    private var completedSection: some View {
        let completed = tasks.filter(\.isComplete)
        let completedReminders = reminders.filter(\.isComplete)
        if !completed.isEmpty || !completedReminders.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(stateAnimation) {
                        showCompleted.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.personalColor)
                            .accessibilityHidden(true)
                        Text("Completed")
                            .font(AppFont.heading(15))
                            .foregroundStyle(Color.filumaText)
                        Text("\(completed.count + completedReminders.count)")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.filumaFaint)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.filumaFaint)
                            .rotationEffect(.degrees(showCompleted ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, FilumaSpacing.screen)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Completed, \(completed.count + completedReminders.count) items")
                .accessibilityValue(showCompleted ? "Expanded" : "Collapsed")

                CollapsibleSectionBody(isExpanded: showCompleted) {
                    VStack(spacing: 10) {
                        ForEach(completed.sorted {
                            ($0.completedAt ?? $0.deadline) > ($1.completedAt ?? $1.deadline)
                        }) { task in
                            CompletedTaskRow(task: task) {
                                withAnimation(stateAnimation) {
                                    if let message = restoreTask(task).message {
                                        taskNotice = TaskListNotice(
                                            title: "A little more time",
                                            message: message
                                        )
                                    }
                                }
                            } onDelete: {
                                do {
                                    try PlanCoordinator.deleteTask(task, context: modelContext)
                                } catch {
                                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                                    taskNotice = TaskListNotice(
                                        title: "Task not removed",
                                        message: "Filuma couldn’t remove that task yet. It is still in Completed—try again."
                                    )
                                }
                            }
                            .padding(.horizontal, FilumaSpacing.screen)
                        }
                        ForEach(completedReminders.sorted { $0.dueDate > $1.dueDate }) { reminder in
                            CompletedReminderRow(reminder: reminder) {
                                restoreReminder(reminder)
                            } onDelete: {
                                deleteReminder(reminder)
                            }
                            .padding(.horizontal, FilumaSpacing.screen)
                        }
                    }
                }
            }
        }
    }

    private func restoreReminder(_ reminder: Reminder) {
        applyReminderMutation(.restore, to: reminder)
    }

    private func applyReminderMutation(
        _ mutation: ReminderMutation,
        to reminder: Reminder
    ) {
        do {
            _ = try withAnimation(stateAnimation) {
                try ReminderMutationCoordinator.apply(
                    mutation,
                    to: reminder,
                    context: modelContext
                )
            }
            taskNotice = nil
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            taskNotice = reminderFailureNotice(
                mutation: mutation,
                reminderID: reminder.id
            )
        }
    }

    private func retryReminderMutation(_ retry: TaskListReminderRetry) {
        if let heldReminder = reminders.first(where: { $0.id == retry.reminderID }) {
            applyReminderMutation(retry.mutation, to: heldReminder)
            return
        }

        let fetched: [Reminder]
        do {
            fetched = try modelContext.fetch(FetchDescriptor<Reminder>())
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            taskNotice = TaskListNotice(
                title: "Reminder not reloaded",
                message: "Filuma couldn’t reload that reminder yet. Nothing else was changed.",
                reminderRetry: retry
            )
            return
        }

        let reminder = fetched.first { $0.id == retry.reminderID }
        guard let reminder else {
            taskNotice = TaskListNotice(
                title: "Reminder unavailable",
                message: "That reminder is no longer available to change."
            )
            return
        }
        applyReminderMutation(retry.mutation, to: reminder)
    }

    private func reminderFailureNotice(
        mutation: ReminderMutation,
        reminderID: UUID
    ) -> TaskListNotice {
        let retry = TaskListReminderRetry(
            reminderID: reminderID,
            mutation: mutation
        )
        switch mutation {
        case .complete:
            return TaskListNotice(
                title: "Reminder not completed",
                message: "Filuma couldn’t save that completion yet, so the reminder is still active.",
                reminderRetry: retry
            )
        case .restore:
            return TaskListNotice(
                title: "Reminder not restored",
                message: "Filuma couldn’t save that restore yet, so the reminder is still completed.",
                reminderRetry: retry
            )
        case .delete:
            return TaskListNotice(
                title: "Reminder not removed",
                message: "Filuma couldn’t remove that reminder yet, so it is still safely in your list.",
                reminderRetry: retry
            )
        }
    }

    // MARK: - Completion

    private func completeTask(_ task: FilumaTask) {
        do {
            completionReceipt = try PlanCoordinator.completeTask(
                task,
                context: modelContext
            )
        } catch {
            taskNotice = TaskListNotice(
                title: "Completion not saved yet",
                message: "Filuma couldn’t save that completion yet, so the task is still active. Please try again."
            )
        }
    }

    private func presentPendingCompletion() {
        guard let receipt = pendingCompletionReceipt else { return }
        pendingCompletionReceipt = nil
        // Move to the next presentation transaction after the work-session
        // cover has fully left the hierarchy.
        Task { @MainActor in
            await Task.yield()
            completionReceipt = receipt
        }
    }

    private struct RestoreOutcome {
        let didRestore: Bool
        let message: String?
    }

    private func restoreTask(withID taskID: UUID) -> RestoreOutcome {
        guard let task = tasks.first(where: { $0.id == taskID }) else {
            return RestoreOutcome(
                didRestore: false,
                message: "That task is no longer available to restore."
            )
        }
        return restoreTask(task)
    }

    private func restoreTask(_ task: FilumaTask) -> RestoreOutcome {
        do {
            let result = try PlanCoordinator.restoreTask(
                task,
                context: modelContext,
                interactive: false
            )
            switch result {
            case .success:
                return RestoreOutcome(didRestore: true, message: nil)
            case .partialFit(_, let unscheduledMinutes):
                let time = CountdownFormatter.effortString(minutes: unscheduledMinutes)
                return RestoreOutcome(
                    didRestore: true,
                    message: "The task is active again. \(time) still couldn’t fit before its deadline, so it will stay visibly unblocked."
                )
            case .noSlots:
                return RestoreOutcome(
                    didRestore: true,
                    message: "The task is active again, but no open time remains before its deadline. It will stay visibly unblocked."
                )
            }
        } catch {
            return RestoreOutcome(
                didRestore: false,
                message: "Filuma couldn’t save that restore, so the task is still completed. Please try again."
            )
        }
    }

    private func presentPendingTaskStatus() {
        guard let notice = pendingTaskNotice else { return }
        pendingTaskNotice = nil
        Task { @MainActor in
            await Task.yield()
            taskNotice = notice
        }
    }

}

// MARK: - First task

/// A first-run promise, not an earned-empty celebration. The three held nodes
/// show Filuma's whole loop without inventing schedule data: capture a task,
/// let the calendar hold it, then begin when the time arrives.
private struct FirstTaskEmptyState: View {
    var onAdd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @SceneStorage("tasks.firstThreadDidReveal") private var didReveal = false
    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                HearthThreadJourney(
                    isRevealed: isRevealed,
                    reduceMotion: reduceMotion
                )
                .frame(maxWidth: 340)
                .padding(.bottom, 22)
            }

            VStack(spacing: 10) {
                Text("Start with one task")
                    .font(AppFont.title(24))
                    .foregroundStyle(Color.filumaText)
                    .accessibilityIdentifier("tasks.empty.firstTitle")

                Text("Add a deadline and a rough effort estimate. Filuma plans the work for you.")
                    .font(AppFont.body(15))
                    .foregroundStyle(Color.filumaSubtle)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 330)
            }

            Button(action: onAdd) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .accessibilityHidden(true)
                    Text(dynamicTypeSize.isAccessibilitySize ? "Add a task" : "Add your first task")
                        .multilineTextAlignment(.center)
                }
                .primaryButtonStyle()
            }
            .hearthPressStyle(scale: 0.98, pressedOpacity: 0.9)
            .accessibilityIdentifier("tasks.empty.addFirst")
            .frame(maxWidth: 360)
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, dynamicTypeSize.isAccessibilitySize ? 12 : 24)
        .padding(.bottom, 52)
        .onAppear(perform: revealIfNeeded)
    }

    private func revealIfNeeded() {
        if reduceMotion || didReveal {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isRevealed = true
            }
        } else {
            isRevealed = true
            didReveal = true
        }
    }
}

// MARK: - Collapsible section body

/// The stable clipping frame that makes a disclosure's rows fold up into the
/// header when collapsed: without it, the removed rows slide up across the
/// whole screen instead of disappearing under the disclosure. Every
/// expandable section on this screen should collapse through this wrapper.
private struct CollapsibleSectionBody<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                content
                    .padding(.bottom, 16)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .clipped()
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(AppFont.heading(14))
                .foregroundStyle(color)
            Text(label)
                .font(AppFont.body(11))
                .foregroundStyle(Color.filumaSubtle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.filumaSurface2, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Active count pill

/// Flame-and-count capsule in the header: how many tasks are on the loom.
private struct ActiveCountPill: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brand300)
            Text("\(count)")
                .font(AppFont.mono(14))
                .foregroundStyle(Color.brand300)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Color.brand500.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.brand500.opacity(0.35), lineWidth: 1))
        .hearthGlow(.brand500, radius: 12, opacity: 0.3)
        .accessibilityLabel("\(count) active tasks")
    }
}

// MARK: - Thread connector

/// The prototype's corner-glow path (`M1 0 V54 Q1 76 23 76 H86`): a vertical
/// drop from the hero card that curves into the "Up next" list.
private struct ThreadConnector: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 0))
        path.addLine(to: CGPoint(x: 1, y: 54))
        path.addQuadCurve(to: CGPoint(x: 23, y: 76), control: CGPoint(x: 1, y: 76))
        path.addLine(to: CGPoint(x: 86, y: 76))

        // Branch from the rounded corner down to the section thread's rail.
        // The section rail's centerline sits at +7pt from the content leading
        // edge (6pt offset + half its 2pt width); this shape is drawn shifted
        // x: -0.5, so x = 7.5 here lands the branch exactly on that line.
        // Without this short overlap the two independently laid-out strokes
        // can show a gap at some sizes and display scales.
        path.move(to: CGPoint(x: 7.5, y: 70))
        path.addLine(to: CGPoint(x: 7.5, y: rect.maxY))
        return path
    }
}

// MARK: - Up next thread row

/// One bead on the thread of light: context dot breaking through the line,
/// task title, meta line, and a mono start-time badge.
private struct UpNextThreadRow: View {
    let task: FilumaTask
    let block: ScheduledBlock
    var onStart: () -> Void
    var onEdit: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onEdit) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 7) {
                        taskCopy
                        startTime
                    }
                } else {
                    HStack(spacing: 10) {
                        taskCopy
                        Spacer(minLength: 8)
                        startTime
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        )
        // The context dot breaks through the thread at the row's heart line.
        .overlay(alignment: .leading) {
            Circle()
                .fill(task.context.color)
                .frame(width: 10, height: 10)
                .hearthGlow(task.context.color, radius: 7, opacity: 0.8)
                .offset(x: -18)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens task details")
        .accessibilityAction(named: "Start session", onStart)
        .contextMenu {
            Button(action: onStart) {
                Label("Start Session", systemImage: "play.fill")
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
        }
    }

    private var taskCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(AppFont.cardTitle(14))
                .foregroundStyle(Color.filumaText)
                .lineLimit(2)
            Text(metaLine)
                .font(AppFont.caption(11))
                .foregroundStyle(isUrgent ? Color.filumaRed : Color.filumaSubtle)
                .lineLimit(2)
        }
    }

    private var startTime: some View {
        Text(Calendar.current.isDateInToday(block.startTime)
             ? TimeFormatter.clock.string(from: block.startTime)
             : block.startTime.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
            .font(AppFont.mono(12))
            .foregroundStyle(task.context.displayColor)
    }

    private var isUrgent: Bool {
        task.deadline.timeIntervalSinceNow < 24 * 3600
    }

    private var metaLine: String {
        var parts = [task.context.rawValue]
        let due = CountdownFormatter.deadlineString(from: Date(), to: task.deadline)
            .replacingOccurrences(of: "Due", with: "due")
        parts.append(due)
        if task.progressPercent > 0 {
            parts.append("\(task.progressPercent)%")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Right Now card

/// The hero card at the top of the Tasks tab: what to do this minute, with
/// one button. Deliberately louder than everything below it — the block nudge
/// gets you to open the app; this removes the last decision.
private struct RightNowCard: View {
    let task: FilumaTask
    let block: ScheduledBlock
    let now: Date
    let showsThreadContinuation: Bool
    var onStart: () -> Void
    var onPush: (BlockPushChoice) -> Void

    @State private var showPushOptions = false
    @State private var showPlan = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isActive: Bool { block.startTime <= now }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timelineLabel)
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.brand300)

                    Text(task.title)
                        .font(AppFont.cardTitle(18))
                        .foregroundStyle(Color.filumaText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    if let step = task.firstStep, !step.isEmpty {
                        Text("First step: \(step)")
                            .font(AppFont.bodySemibold(12))
                            .foregroundStyle(Color.filumaSubtle)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    }
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 0)
            }

            Button(action: onStart) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(isActive ? "Start" : "Start early")
                }
                .primaryButtonStyle()
            }
            .hearthPressStyle(scale: 0.98, pressedOpacity: 0.9)

            ViewThatFits(in: .horizontal) {
                HStack {
                    planButton
                    Spacer(minLength: 12)
                    postponeButton
                }
                VStack(spacing: 0) {
                    planButton
                    postponeButton
                }
            }

        }
        .padding(18)
        // A soft ember pooled in the top-right corner (applied before the
        // gradient fill so it renders in front of it, behind the content)…
        .background(alignment: .topTrailing) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.brand500.opacity(0.3), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 75
                    )
                )
                .frame(width: 150, height: 150)
                .blur(radius: 10)
                .offset(x: 30, y: -40)
        }
        // …over accent light banked into the top-left one.
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color.brand500.opacity(0.22), location: 0),
                    .init(color: Color.filumaSurface, location: 0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FilumaRadius.hero, style: .continuous)
                .stroke(Color.brand300.opacity(0.28), lineWidth: 1)
        )
        // The thread's origin: light rims the card's bottom-left corner —
        // down the left edge, around the corner, along the bottom — and the
        // Up Next thread below picks it up. "Now → next" is one thread.
        .overlay(alignment: .bottomLeading) {
            if showsThreadContinuation {
                ThreadConnector()
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.brand300.opacity(0), location: 0),
                                .init(color: Color.brand300.opacity(0.95), location: 0.45),
                                .init(color: Color.brand300.opacity(0), location: 1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 90, height: 78)
                    .offset(x: -0.5, y: 1.5)
                    .shadow(color: Color.brand500.opacity(0.6), radius: 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .shadow(color: Color.brand500.opacity(0.22), radius: 30, y: 12)
        .sheet(isPresented: $showPlan) { TaskPlanPreview(task: task) }
        .confirmationDialog("Can't right now?", isPresented: $showPushOptions, titleVisibility: .visible) {
            Button("Push 30 minutes") { onPush(.thirtyMinutes) }
            Button("Push 1 hour") { onPush(.oneHour) }
            Button("Push to tomorrow") { onPush(.tomorrow) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Life happens. The plan moves and the deadline math stays honest — no blocks quietly rot.")
        }
    }

    private var planButton: some View {
        Button("Scheduled sessions") { showPlan = true }
            .font(AppFont.caption(12))
            .foregroundStyle(Color.brand300)
            .frame(minHeight: 44)
            .buttonStyle(.plain)
    }

    private var postponeButton: some View {
        Button("Can't right now?") { showPushOptions = true }
            .font(AppFont.caption(12))
            .foregroundStyle(Color.filumaSubtle)
            .frame(minHeight: 44)
            .buttonStyle(.plain)
    }

    private var timelineLabel: String {
        let start = Calendar.current.isDateInToday(block.startTime)
            ? TimeFormatter.clock.string(from: block.startTime)
            : block.startTime.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(start) – \(TimeFormatter.clock.string(from: block.endTime))"
    }

}

// MARK: - Overdue triage row

/// One overdue task, three kind exits. The framing matters: the pile is a
/// decision queue, not a wall of shame.
private struct OverdueTriageRow: View {
    let task: FilumaTask
    var onNewDeadline: () -> Void
    var onComplete: () -> Void
    var onLetGo: () -> Void

    @State private var confirmLetGo = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(AppFont.heading(15))
                    .foregroundStyle(Color.filumaText)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text("Was due \(dueLabel)")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.filumaRed)
                    Text("·")
                        .foregroundStyle(Color.filumaFaint)
                    Text(task.context.rawValue)
                        .font(AppFont.caption(11))
                        .foregroundStyle(task.context.color)
                }
            }
            .accessibilityElement(children: .combine)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        triageActions
                    }
                } else {
                    HStack(spacing: 8) {
                        triageActions
                    }
                }
            }
        }
        .padding(16)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.filumaRed.opacity(0.3), lineWidth: 1)
        )
        .confirmationDialog("Let it go?", isPresented: $confirmLetGo, titleVisibility: .visible) {
            Button("Let it go", role: .destructive, action: onLetGo)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(task.title)\" disappears from your list. Dropping a task on purpose is a decision, not a failure.")
        }
    }

    @ViewBuilder
    private var triageActions: some View {
        TriageButton(
            label: "New deadline",
            icon: "calendar.badge.clock",
            tint: .brand500,
            identifier: "tasks.triage.newDeadline",
            action: onNewDeadline
        )
        TriageButton(
            label: "Done actually",
            icon: "checkmark.circle",
            tint: .personalColor,
            identifier: "tasks.triage.complete",
            action: onComplete
        )
        TriageButton(
            label: "Let it go",
            icon: "wind",
            tint: .filumaSubtle,
            identifier: "tasks.triage.letGo"
        ) {
            confirmLetGo = true
        }
    }

    private var dueLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(task.deadline) {
            return "today at \(TimeFormatter.clock.string(from: task.deadline))"
        } else if calendar.isDateInYesterday(task.deadline) {
            return "yesterday"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: task.deadline)
    }
}

private struct TriageButton: View {
    let label: String
    let icon: String
    let tint: Color
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(AppFont.caption(11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}


// MARK: - Reminder Row

private struct ReminderRow: View {
    let reminder: Reminder
    var onComplete: () -> Void
    var onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 13))
                .foregroundStyle(isOverdue ? Color.filumaRed : Color.brand500)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(AppFont.bodySemibold(15))
                    .foregroundStyle(Color.filumaText)
                    .lineLimit(1)
                Text(dueLabel)
                    .font(AppFont.caption(11))
                    .foregroundStyle(isOverdue ? Color.filumaRed : Color.filumaSubtle)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.filumaFaint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark reminder complete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .contextMenu {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(reminder.title)\" goes away for good. This can't be undone.")
        }
    }

    private var isOverdue: Bool {
        reminder.dueDate < Date()
    }

    private var dueLabel: String {
        let calendar = Calendar.current
        let time = TimeFormatter.clock.string(from: reminder.dueDate)
        if calendar.isDateInToday(reminder.dueDate) {
            return time
        } else if calendar.isDateInTomorrow(reminder.dueDate) {
            return "Tomorrow \(time)"
        } else if calendar.isDateInYesterday(reminder.dueDate) {
            return "Yesterday \(time)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: reminder.dueDate)), \(time)"
    }
}

// MARK: - Completed Task Row

private struct CompletedTaskRow: View {
    let task: FilumaTask
    var onRestore: () -> Void
    var onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.personalColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(AppFont.bodySemibold(15))
                    .strikethrough()
                    .foregroundStyle(Color.filumaSubtle)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(task.context.rawValue)
                        .font(AppFont.caption(11))
                        .foregroundStyle(task.context.color)
                    if task.timeSpentMinutes > 0 {
                        Text("· \(CountdownFormatter.effortString(minutes: task.timeSpentMinutes)) worked")
                            .font(AppFont.caption(11))
                            .foregroundStyle(Color.filumaFaint)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.filumaSubtle)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore task")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.filumaSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .contextMenu {
            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete permanently?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(task.title)\" and its history go away for good. This can't be undone.")
        }
    }
}

// MARK: - Completed Reminder Row

private struct CompletedReminderRow: View {
    let reminder: Reminder
    var onRestore: () -> Void
    var onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.filumaFaint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(AppFont.bodySemibold(15))
                    .strikethrough()
                    .foregroundStyle(Color.filumaSubtle)
                    .lineLimit(1)
                Text("Reminder · \(dueLabel)")
                    .font(AppFont.caption(11))
                    .foregroundStyle(Color.filumaFaint)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.filumaSubtle)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore reminder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.filumaSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .contextMenu {
            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete permanently?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("\"\(reminder.title)\" goes away for good. This can't be undone.")
        }
    }

    private var dueLabel: String {
        let calendar = Calendar.current
        let time = TimeFormatter.clock.string(from: reminder.dueDate)
        if calendar.isDateInToday(reminder.dueDate) {
            return time
        } else if calendar.isDateInYesterday(reminder.dueDate) {
            return "Yesterday \(time)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: reminder.dueDate)), \(time)"
    }
}
