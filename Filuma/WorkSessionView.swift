import SwiftUI
import SwiftData
import UIKit

/// Chooses the reservation a newly started timer should fulfill. Corrupt stores
/// can contain overlapping blocks, so selection must not depend on SwiftData's
/// relationship ordering: prefer the earliest start, then earliest end, then a
/// stable identifier tie-breaker.
enum WorkSessionBlockSelector {
    static func currentIncompleteBlock(
        in blocks: [ScheduledBlock],
        at date: Date
    ) -> ScheduledBlock? {
        blocks
            .filter {
                !$0.isComplete
                    && $0.startTime <= date
                    && date < $0.endTime
            }
            .min { lhs, rhs in
                if lhs.startTime != rhs.startTime {
                    return lhs.startTime < rhs.startTime
                }
                if lhs.endTime != rhs.endTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}

/// A presented work-session screen does not own Filuma's global timer merely
/// because it is visible. Only a locally started or recovered session may
/// record attendance when the sheet goes away. This keeps an idle sheet for a
/// second task from tearing down the first task's recovery journal.
enum WorkSessionDismissalPolicy {
    static func shouldRecord(localSessionID: UUID?) -> Bool {
        localSessionID != nil
    }
}

/// Plain, testable copy policy for the post-session receipt. A timer that was
/// stopped before one whole second has no durable attendance row, so it must
/// never borrow the language used for banked work.
struct WorkSessionReceiptCopy: Equatable {
    let eyebrow: String
    let title: String
    let message: String
    let durationLabel: String
    let detailLabel: String

    static func make(loggedSeconds: Int, scheduledBlock: Bool) -> Self {
        guard loggedSeconds > 0 else {
            return Self(
                eyebrow: "THREAD OPEN",
                title: "Session ended",
                message: "No time was added. You can still update task progress if you need to.",
                durationLabel: "No time added",
                detailLabel: "Your task and schedule are unchanged"
            )
        }

        return Self(
            eyebrow: "THREAD HELD",
            title: "Session logged",
            message: "Your time is safely banked. Updating task progress is optional.",
            durationLabel: CountdownFormatter.timerString(seconds: loggedSeconds),
            detailLabel: scheduledBlock
                ? "Time logged to scheduled block"
                : "Focus time banked"
        )
    }
}

/// The held flame: a full-height focus timer for a single task. Start/pause/
/// stop a session around the glowing ring, then self-report overall progress.
/// Saving at 100% completes the task.
struct WorkSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let task: FilumaTask
    /// A non-nil receipt means completion is already durable. The presenting
    /// view may delay only its ritual while this full-screen cover dismisses.
    var onFinish: (TaskCompletionReceipt?) -> Void

    @State private var isRunning = false
    @State private var isPaused = false
    @State private var elapsedSeconds = 0
    @State private var showProgressPrompt = false
    @State private var progressValue: Double = 0
    @State private var sessionStart: Date?
    /// Matches the App Group control snapshot and Live Activity attributes.
    /// A delayed intent for an older activity cannot affect a newer timer.
    @State private var activeSessionID: UUID?
    /// Retained only when SwiftData rejects the attendance durability boundary.
    /// A later Stop retries this same row instead of inserting a duplicate.
    @State private var pendingAttendanceRecord: WorkSession?
    @State private var pendingAttendanceCompletedLinkedBlock = false
    /// Captured when the timer starts so stopping after the block boundary still
    /// links the work log to the reservation it fulfilled.
    @State private var scheduledBlockId: UUID?

    // Pause bookkeeping: worked time is derived from the wall clock
    // (sessionStart → now, minus time spent paused), never from counting
    // timer ticks — ticks stop when the app leaves the foreground, which is
    // exactly when the ring used to snap back to zero.
    @State private var pausedAccumSeconds = 0
    @State private var pauseBegan: Date?

    // Immersion: the end of the currently running scheduled block, if the
    // session started inside one. Bounds the hyperfocus spurt from both sides.
    @State private var blockEndTarget: Date?
    /// The ring's anchor and denominator, shared verbatim with the Live
    /// Activity ring. Inside a block the window is the block's own span, so
    /// joining late starts the ring partway around and a restarted session
    /// picks up where the block's clock is now. Outside a block it's the full
    /// effort budget, backdated by time already spent — earlier sessions stay
    /// on the ring.
    @State private var ringStartTime: Date?
    @State private var ringWindowSeconds: Int?
    @State private var didWarnNearEnd = false
    @State private var didMarkBlockEnd = false
    @State private var immersionMessage: String?
    @State private var sessionIssue: SessionIssue?
    @State private var loggedSessionSeconds = 0
    @State private var loggedScheduledBlock = false
    @AccessibilityFocusState private var progressHeadingFocused: Bool

    // Micro-start: a deliberately tiny commitment. "Work on the essay" is
    // unstartable; "ten minutes" is a dare you can take.
    @State private var microGoalSeconds: Int?
    @State private var didHitMicroGoal = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The wall clock the ring reads. A plain `Date()` in `body` would freeze
    /// during a pause (nothing else invalidates the view then), making the
    /// ring jump on resume; ticking it here keeps ring and Live Activity on
    /// the same schedule clock through pauses.
    @State private var now = Date()

    private struct SessionIssue: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        ZStack {
            // The ring owns the light. A quieter ember field preserves the
            // living Hearthlight atmosphere without competing for attention.
            HearthScreenBackground(
                topGlow: 0.04,
                bottomGlow: 0.34,
                embers: isRunning ? 10 : 14,
                emberIntensity: 0.7
            )

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)

                ScrollView {
                    Group {
                        if showProgressPrompt {
                            progressPrompt
                        } else {
                            timerBody
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actionBar
                }
            }
        }
        .onAppear {
            rehydrateIfNeeded()
        }
        .onReceive(timer) { tick in
            guard isRunning else { return }
            // The ring carries the schedule, not the session: it keeps
            // ticking through a pause (only the count-up freezes).
            now = tick
            syncSharedControl(at: tick)
            if !isPaused {
                checkBlockBoundary()
                checkMicroGoal()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workSessionControlDidChange)) {
            notification in
            guard isRunning,
                  let changedID = notification.object as? UUID,
                  changedID == activeSessionID else { return }
            let date = Date()
            now = date
            syncSharedControl(at: date)
        }
        // Coming back from the background: the timer publisher slept, so the
        // ring and label catch up to the wall clock immediately instead of
        // resuming from wherever the last tick left them.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                UIApplication.shared.isIdleTimerDisabled = false
            } else if isRunning {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            if newPhase == .active && isRunning {
                now = Date()
                syncSharedControl(at: now)
            }
        }
        .onDisappear {
            // A locally owned running sheet can still disappear without Stop.
            // An idle sheet owns nothing: recording it would otherwise reach
            // shared teardown and could erase another task's active session.
            if WorkSessionDismissalPolicy.shouldRecord(
                localSessionID: activeSessionID
            ) {
                recordSession()
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: showProgressPrompt) { _, showing in
            guard showing else { return }
            Task { @MainActor in
                await Task.yield()
                progressHeadingFocused = true
            }
        }
        .alert(item: $sessionIssue) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 16) {
                    headerTitle
                    Spacer(minLength: 8)
                    headerAction
                }
            } else {
                ZStack {
                    headerTitle
                    HStack {
                        headerAction
                        Spacer()
                    }
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    private var headerTitle: some View {
        Text("Work Session")
            .font(AppFont.cardTitle(15))
            .foregroundStyle(Color.filumaText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityIdentifier("workSession.title")
    }

    private var headerAction: some View {
        Button(isRunning ? "End" : "Close") {
            if isRunning {
                stopTapped()
            } else {
                onFinish(nil)
            }
        }
        .font(AppFont.caption(14))
        .foregroundStyle(Color.filumaSubtle)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .hearthPressStyle(scale: 0.96, pressedOpacity: 0.75)
        .accessibilityIdentifier("workSession.close")
        .accessibilityHint(
            isRunning
                ? "Logs this session and opens the progress update"
                : "Closes the work session"
        )
    }

    // MARK: - Timer

    private var timerBody: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text(task.context.rawValue)
                    .contextTag(task.context)
                Text(task.title)
                    .font(AppFont.cardTitle(22))
                    .foregroundStyle(Color.filumaText)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("workSession.taskTitle")
                Text(budgetLabel)
                    .font(AppFont.monoMedium(13))
                    .foregroundStyle(isOverBudgetNow ? Color.workDisplay : Color.filumaSubtle)

                // The captured opening move, shown only while idle — once the
                // timer runs the start problem is solved.
                if !isRunning, let step = task.firstStep, !step.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.brand300)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Just start here")
                                .font(AppFont.caption(11))
                                .foregroundStyle(Color.filumaSubtle)
                            Text(step)
                                .font(AppFont.bodySemibold(14))
                                .foregroundStyle(Color.filumaText)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.filumaSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.filumaBorder, lineWidth: 1)
                    )
                    .padding(.top, 6)
                }
            }
            .padding(.top, 6)

            VStack(spacing: 26) {
                heldFlameRing

                if let subtext = statusPillText {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.brand300)
                            .accessibilityHidden(true)
                        Text(subtext)
                            .font(AppFont.bodySemibold(13))
                            .foregroundStyle(Color.brand100)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.brand500.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(Color.brand500.opacity(0.22), lineWidth: 1))
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.92))
                    )
                }

                if isRunning, let end = blockEndTarget {
                    Text(blockBoundaryLabel(end: end))
                        .font(AppFont.monoMedium(12))
                        .foregroundStyle(Color.filumaFaint)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 28)
        }
        .padding(.bottom, 24)
    }

    /// The 200pt held-flame ring: pulsing halo, conic accent arc, inner dark
    /// disc carrying the big mono timer and a breathing status label.
    private var heldFlameRing: some View {
        ZStack {
            HearthProgressRing(
                progress: ringProgress,
                size: 200,
                lineWidth: 13,
                showsHalo: isRunning && !isPaused && !hasBlockEnded
            )

            Circle()
                .fill(
                    // Light pools near the top of the disc (`circle at 50% 28%`).
                    RadialGradient(
                        colors: [Color.filumaSurface2, Color.filumaSurface],
                        center: UnitPoint(x: 0.5, y: 0.28),
                        startRadius: 10,
                        endRadius: 130
                    )
                )
                .overlay(Circle().stroke(Color.filumaBorder, lineWidth: 1))
                .frame(width: 168, height: 168)

            VStack(spacing: 8) {
                Text(primaryTimerLabel)
                    .font(AppFont.mono(38))
                    .foregroundStyle(isRunning && !isPaused ? Color.filumaText : Color.filumaSubtle)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(spacing: 6) {
                    if isRunning && !isPaused {
                        BreathingDot(color: .brand300, size: 6)
                    }
                    Text(statusLabel)
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.brand300)
                        .kerning(2)
                }

                if isRunning {
                    Text("\(CountdownFormatter.timerString(seconds: elapsedSeconds)) focused")
                        .font(AppFont.monoMedium(11))
                        .foregroundStyle(Color.filumaFaint)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusLabel.capitalized)
            .accessibilityValue(timerAccessibilityValue)
            .accessibilityIdentifier("workSession.timer")
        }
        .frame(width: 244, height: 244)
    }

    // MARK: - Fixed actions

    private var actionBar: some View {
        Group {
            if showProgressPrompt {
                progressActions
            } else {
                sessionControls
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color.filumaBackground.opacity(0.97).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.filumaBorder)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var sessionControls: some View {
        if isRunning {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    pauseButton
                    stopButton
                }
            } else {
                HStack(spacing: 12) {
                    pauseButton
                        .frame(maxWidth: 138)
                    stopButton
                }
            }
        } else {
            VStack(spacing: 12) {
                Button {
                    startTapped()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("Start working")
                    }
                    .primaryButtonStyle()
                }
                .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
                .accessibilityIdentifier("workSession.start")

                Button {
                    startTapped(microMinutes: 10)
                } label: {
                    Text("Just 10 minutes")
                        .font(AppFont.caption(13))
                        .foregroundStyle(Color.brand300)
                        // Keep the 44pt boundary inside the native label. A
                        // frame applied after Button does not enlarge the
                        // synthesized accessibility or hit-test geometry.
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(Capsule().stroke(Color.brand500.opacity(0.32), lineWidth: 1))
                }
                .hearthPressStyle(scale: 0.97, pressedOpacity: 0.82)
                .accessibilityIdentifier("workSession.microStart")
            }
        }
    }

    private var pauseButton: some View {
        Button {
            withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
                togglePause()
            }
        } label: {
            Label(
                isPaused ? "Resume" : "Pause",
                systemImage: isPaused ? "play.fill" : "pause.fill"
            )
            .font(AppFont.heading(16))
            .foregroundStyle(Color.filumaText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous)
                    .fill(Color.filumaSurface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous)
                    .stroke(Color.filumaBorder, lineWidth: 1)
            )
        }
        .hearthPressStyle(scale: 0.97, pressedOpacity: 0.82)
        .accessibilityIdentifier("workSession.pause")
    }

    private var stopButton: some View {
        Button {
            stopTapped()
        } label: {
            Text("End & log session")
                .primaryButtonStyle()
        }
        .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
        .accessibilityIdentifier("workSession.stop")
    }

    private var progressActions: some View {
        VStack(spacing: 12) {
            Button {
                saveProgress()
            } label: {
                Text("Save progress")
                    .primaryButtonStyle(fill: task.context.color)
            }
            .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
            .accessibilityIdentifier("workSession.saveProgress")

            Button("Not now") {
                onFinish(nil)
            }
            .font(AppFont.heading(15))
            .foregroundStyle(Color.filumaSubtle)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .hearthPressStyle(scale: 0.98, pressedOpacity: 0.76)
            .accessibilityHint("Closes this session without changing overall task progress")
            .accessibilityIdentifier("workSession.notNow")
        }
    }

    // MARK: - Progress prompt

    private var progressPrompt: some View {
        let copy = receiptCopy

        return VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(copy.eyebrow)
                    .font(AppFont.caption(11))
                    .foregroundStyle(Color.brand300)
                    .kerning(1.8)

                Text(copy.title)
                    .font(AppFont.title(24))
                    .foregroundStyle(Color.filumaText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($progressHeadingFocused)
                    .accessibilityIdentifier("workSession.loggedTitle")

                Text(copy.message)
                    .font(AppFont.body(14))
                    .foregroundStyle(Color.filumaSubtle)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                Label(
                    copy.durationLabel,
                    systemImage: loggedSessionSeconds > 0 ? "timer" : "clock"
                )
                Label(
                    copy.detailLabel,
                    systemImage: loggedSessionSeconds == 0
                        ? "arrow.counterclockwise"
                        : (loggedScheduledBlock ? "calendar.badge.checkmark" : "flame.fill")
                )
            }
            .font(AppFont.bodySemibold(14))
            .foregroundStyle(Color.filumaText)
            .symbolRenderingMode(.hierarchical)
            .tint(task.context.displayColor)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.filumaSurface)
            .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                    .stroke(Color.filumaBorder, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 12) {
                Text("Update overall task progress?")
                    .font(AppFont.bodySemibold(15))
                    .foregroundStyle(Color.filumaText)
                    .multilineTextAlignment(.center)

                Text("\(Int(progressValue))%")
                    .font(AppFont.mono(34))
                    .foregroundStyle(task.context.displayColor)
                    .contentTransition(.numericText())

                Slider(value: $progressValue, in: sliderRange, step: 1)
                    .tint(task.context.color)
                    .accessibilityLabel("Overall task progress")
                    .accessibilityValue("\(Int(progressValue)) percent")
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 24)
    }

    private var sliderRange: ClosedRange<Double> {
        // The UI and persistence boundary share the same monotonic rule. A
        // 99% task may move to 100%, but can never appear to save a regression.
        let minimum = Double(min(max(task.progressPercent, 0), 99))
        return minimum...100
    }

    // MARK: - Labels

    private var spentTotalMinutes: Int {
        task.timeSpentMinutes + elapsedSeconds / 60
    }

    private var isOverBudgetNow: Bool {
        spentTotalMinutes > task.effortMinutes
    }

    private var budgetLabel: String {
        let spent = CountdownFormatter.effortString(minutes: spentTotalMinutes)
        let budget = CountdownFormatter.effortString(minutes: task.effortMinutes)
        return isOverBudgetNow
            ? "\(spent) of \(budget) budget — over"
            : "\(spent) of \(budget) budget used"
    }

    private var receiptCopy: WorkSessionReceiptCopy {
        WorkSessionReceiptCopy.make(
            loggedSeconds: loggedSessionSeconds,
            scheduledBlock: loggedScheduledBlock
        )
    }

    private var hasBlockEnded: Bool {
        guard isRunning, let end = blockEndTarget else { return false }
        return now >= end
    }

    /// The dominant number has one stable meaning for the lifetime of a
    /// scheduled session: block time remaining. Floating sessions use focused
    /// time instead. At the boundary the block clock banks at zero rather than
    /// abruptly changing into the other clock.
    private var primaryTimerLabel: String {
        if isRunning, let end = blockEndTarget {
            let remaining = max(0, Int(end.timeIntervalSince(now)))
            return CountdownFormatter.timerString(seconds: remaining)
        }
        return CountdownFormatter.timerString(seconds: elapsedSeconds)
    }

    private var statusLabel: String {
        if !isRunning { return "READY" }
        if isPaused { return "PAUSED" }
        if hasBlockEnded { return "BLOCK ENDED" }
        if blockEndTarget != nil { return "BLOCK LEFT" }
        return "FOCUSED"
    }

    private var timerAccessibilityValue: String {
        let focused = CountdownFormatter.timerString(seconds: elapsedSeconds)
        if blockEndTarget != nil {
            if hasBlockEnded {
                return "Block ended, \(focused) focused"
            }
            return "\(primaryTimerLabel) left in block, \(focused) focused"
        }
        return "\(focused) focused"
    }

    private func blockBoundaryLabel(end: Date) -> String {
        if now >= end {
            return "block ended \(TimeFormatter.clock.string(from: end)) · your time stays safe"
        }
        return "block ends \(TimeFormatter.clock.string(from: end)) · schedule holds until then"
    }

    /// How much of the flame is held: the wall-clock fraction of the ring
    /// window (the block's own span, or the backdated budget outside a block)
    /// — the same interval the Live Activity ring renders, so the two never
    /// disagree. Starting mid-block picks the ring up partway around, and
    /// restarting a session on the same block resumes it instead of resetting
    /// to zero. May exceed 1: it loops a second lap over itself rather than
    /// clamping. Idle (pre-start) it shows budget burned. Like the Live
    /// Activity ring, it keeps advancing through a pause (the count-up label
    /// carries the pause; the ring carries the schedule).
    private var ringProgress: Double {
        if isRunning, let start = ringStartTime,
           let window = ringWindowSeconds, window > 0 {
            return max(0, now.timeIntervalSince(start)) / Double(window)
        }
        guard task.effortMinutes > 0 else { return 0 }
        return min(1, Double(spentTotalMinutes) / Double(task.effortMinutes))
    }

    /// While a micro-goal is pending it owns the pill (a countdown reads
    /// louder than any coaching); afterwards the immersion messages take over.
    private var statusPillText: String? {
        guard isRunning else { return nil }
        if let goal = microGoalSeconds, !didHitMicroGoal {
            let left = CountdownFormatter.timerString(seconds: max(0, goal - elapsedSeconds))
            return "\(left) to your ten — that's the whole ask."
        }
        if didHitMicroGoal && immersionMessage == nil {
            return "10-minute dare met · keep going?"
        }
        return immersionMessage
    }

    // MARK: - Actions

    private func startTapped(microMinutes: Int? = nil) {
        if let journalTaskID = WorkSessionControlStore.load()?.taskID,
           journalTaskID != task.id {
            // Filuma has one active timer. Never overwrite another task's
            // recovery journal just because this screen was presented.
            presentIssue(
                title: "Another session is running",
                message: "End the active work session before starting this one. Its timer and recovery record are still safe."
            )
            return
        }
        sessionIssue = nil
        loggedSessionSeconds = 0
        loggedScheduledBlock = false
        let now = Date()
        let sessionID = UUID()
        self.now = now // the ring's clock starts at the same instant
        sessionStart = now
        activeSessionID = sessionID
        elapsedSeconds = 0
        pausedAccumSeconds = 0
        pauseBegan = nil
        isPaused = false
        withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.reveal) {
            isRunning = true
        }

        // Immersion: the screen stays awake for the whole session, and the
        // running block's end becomes the gentle boundary chime.
        UIApplication.shared.isIdleTimerDisabled = true
        let runningBlock = WorkSessionBlockSelector.currentIncompleteBlock(
            in: task.scheduledBlocks,
            at: now
        )
        scheduledBlockId = runningBlock?.id
        blockEndTarget = runningBlock?.endTime
        let ringStart: Date
        let window: Int
        if let block = runningBlock {
            // The ring is the block's own clock: empty at the block's start,
            // full at its end, regardless of when this session joined it.
            ringStart = block.startTime
            window = max(block.durationMinutes, 1) * 60
        } else {
            // Floating session: the full budget, backdated by work already
            // logged, so the ring resumes rather than resetting each session.
            // An over-budget task starts past 1 and loops — the banked lap
            // stays honest instead of stretching the denominator to hide it.
            let spentSeconds = task.timeSpentMinutes * 60
            ringStart = now.addingTimeInterval(TimeInterval(-spentSeconds))
            window = max(task.effortMinutes, 1) * 60
        }
        ringStartTime = ringStart
        ringWindowSeconds = window
        didWarnNearEnd = false
        didMarkBlockEnd = false
        immersionMessage = nil
        microGoalSeconds = microMinutes.map { $0 * 60 }
        didHitMicroGoal = false

        WorkSessionControlStore.save(
            WorkSessionControlState(
                sessionID: sessionID,
                startedAt: now,
                taskID: task.id,
                scheduledBlockID: runningBlock?.id,
                blockEndsAt: blockEndTarget,
                ringStartsAt: ringStart,
                ringEndsAt: ringStart.addingTimeInterval(TimeInterval(window))
            )
        )
        WorkSessionActivityController.start(
            sessionID: sessionID,
            taskID: task.id,
            taskTitle: task.title,
            contextName: task.context.rawValue,
            effortMinutes: task.effortMinutes,
            startedAt: now,
            blockEndsAt: blockEndTarget,
            ringStartsAt: ringStart,
            ringEndsAt: ringStart.addingTimeInterval(TimeInterval(window))
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Rebuilds the foreground timer from the App Group journal after iOS has
    /// terminated Filuma in the background. The journal's wall clock remains the
    /// source of truth; presenting this view must not restart the session.
    private func rehydrateIfNeeded() {
        guard !isRunning,
              let journal = WorkSessionControlStore.load(),
              journal.taskID == task.id else { return }

        let date = Date()
        let fallbackRingStart = journal.startedAt.addingTimeInterval(
            TimeInterval(-task.timeSpentMinutes * 60)
        )
        let ringStart: Date
        let ringWindow: Int
        if let journalStart = journal.ringStartsAt,
           let journalEnd = journal.ringEndsAt,
           journalEnd > journalStart {
            ringStart = journalStart
            ringWindow = max(1, Int(journalEnd.timeIntervalSince(journalStart)))
        } else {
            ringStart = fallbackRingStart
            ringWindow = max(task.effortMinutes, 1) * 60
        }

        now = date
        activeSessionID = journal.sessionID
        sessionStart = journal.startedAt
        scheduledBlockId = journal.scheduledBlockID
        blockEndTarget = journal.blockEndsAt
        ringStartTime = ringStart
        ringWindowSeconds = ringWindow
        if let blockEnd = journal.blockEndsAt {
            didWarnNearEnd = date >= blockEnd.addingTimeInterval(-10 * 60)
            didMarkBlockEnd = date >= blockEnd
        }
        syncSharedControl(at: date)
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        // Recovery deserves a word: the app just came back from a process
        // death with the timer intact, and saying so out loud is what turns
        // an invisible save into trust.
        immersionMessage = "Picked the thread right back up — nothing lost."

        if WorkSessionActivityController.isActive(sessionID: journal.sessionID) {
            WorkSessionActivityController.updateSoon(journal, at: date)
        } else {
            WorkSessionActivityController.start(
                sessionID: journal.sessionID,
                taskID: task.id,
                taskTitle: task.title,
                contextName: task.context.rawValue,
                effortMinutes: task.effortMinutes,
                startedAt: journal.startedAt,
                blockEndsAt: journal.blockEndsAt,
                ringStartsAt: ringStart,
                ringEndsAt: ringStart.addingTimeInterval(TimeInterval(ringWindow))
            )
        }
    }

    /// Worked time from the wall clock: start → now, minus paused stretches.
    private func syncElapsed(now: Date = Date()) {
        guard let start = sessionStart else { return }
        let paused = pausedAccumSeconds
            + (pauseBegan.map { Int(now.timeIntervalSince($0)) } ?? 0)
        elapsedSeconds = max(0, Int(now.timeIntervalSince(start)) - paused)
    }

    /// Pulls pause bookkeeping written by either the in-app control or the
    /// system-run Live Activity intent. The wall clock remains authoritative,
    /// so resuming the app never depends on timer publisher ticks that were
    /// skipped while it was suspended.
    private func syncSharedControl(at date: Date) {
        guard let activeSessionID,
              let control = WorkSessionControlStore.load(sessionID: activeSessionID) else {
            if !isPaused { syncElapsed(now: date) }
            return
        }

        pausedAccumSeconds = control.accumulatedPausedSeconds
        pauseBegan = control.pauseBeganAt
        elapsedSeconds = control.elapsedWorkedSeconds(at: date)
        if isPaused != control.isPaused {
            withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.selection) {
                isPaused = control.isPaused
            }
        }
    }

    private func togglePause() {
        UISelectionFeedbackGenerator().selectionChanged()
        let now = Date()
        if let activeSessionID,
           var control = WorkSessionControlStore.load(sessionID: activeSessionID) {
            control.togglePause(at: now)
            WorkSessionControlStore.save(control)
            syncSharedControl(at: now)
            WorkSessionActivityController.updateSoon(control, at: now)
            return
        }

        // Defensive fallback for a damaged/missing shared snapshot. The local
        // control remains usable even when App Group persistence is unavailable.
        if isPaused {
            if let began = pauseBegan {
                pausedAccumSeconds += max(0, Int(now.timeIntervalSince(began)))
            }
            pauseBegan = nil
            isPaused = false
            syncElapsed(now: now)
        } else {
            syncElapsed(now: now)
            pauseBegan = now
            isPaused = true
        }
        if let activeSessionID, let sessionStart {
            let recovered = WorkSessionControlState(
                sessionID: activeSessionID,
                startedAt: sessionStart,
                accumulatedPausedSeconds: pausedAccumSeconds,
                pauseBeganAt: pauseBegan,
                taskID: task.id,
                scheduledBlockID: scheduledBlockId,
                blockEndsAt: blockEndTarget,
                ringStartsAt: ringStartTime,
                ringEndsAt: ringStartTime.flatMap { start in
                    ringWindowSeconds.map {
                        start.addingTimeInterval(TimeInterval($0))
                    }
                }
            )
            WorkSessionControlStore.save(recovered)
            WorkSessionActivityController.updateSoon(recovered, at: now)
        }
    }

    private func checkMicroGoal() {
        guard let goal = microGoalSeconds, !didHitMicroGoal, elapsedSeconds >= goal else { return }
        didHitMicroGoal = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.reveal) {
            immersionMessage = "10-minute dare met · keep going?"
        }
    }

    /// Haptic + one-line nudge near and at the end of the running block. The
    /// near-end warning offers an off-ramp; the end marker bounds the
    /// Herculean spurt the app exists to prevent.
    private func checkBlockBoundary() {
        guard let end = blockEndTarget else { return }
        let remaining = end.timeIntervalSinceNow

        if remaining <= 600 && remaining > 0 && !didWarnNearEnd {
            didWarnNearEnd = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.reveal) {
                immersionMessage = "About 10 minutes left in this block — a good stopping point is coming."
            }
        } else if remaining <= 0 && !didMarkBlockEnd {
            didMarkBlockEnd = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.reveal) {
                immersionMessage = "Block done. Stopping now is a win — no heroics required."
            }
        }
    }

    private func stopTapped() {
        // Commit the work log and attendance before the progress prompt. The
        // app may be backgrounded or terminated while that prompt is visible.
        guard recordSession() else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(reduceMotion ? HearthMotion.reduced : HearthMotion.reveal) {
            isRunning = false
            isPaused = false
            progressValue = Double(task.progressPercent)
            showProgressPrompt = true
        }
    }

    @discardableResult
    private func recordSession() -> Bool {
        if isRunning {
            syncSharedControl(at: Date())
        }
        guard elapsedSeconds > 0 else {
            loggedSessionSeconds = 0
            loggedScheduledBlock = false
            finishRecordedSession()
            // A sub-second start/stop has no attendance to persist, so it is
            // already safe to finish any calendar repair that waited for the
            // timer's ownership to clear.
            do {
                _ = try PlanCoordinator.resumeDeferredBusyTimeConflictReplan(
                    context: modelContext
                )
            } catch {
                // The coordinator restores the deferred request on failure, so
                // a later foreground pass can retry without misreporting this
                // already-complete zero-duration stop as a logging failure.
            }
            return true
        }
        let session: WorkSession
        let didCompleteLinkedBlock: Bool
        if let pendingAttendanceRecord {
            session = pendingAttendanceRecord
            session.durationSeconds = elapsedSeconds
            didCompleteLinkedBlock = pendingAttendanceCompletedLinkedBlock
        } else {
            guard let attendanceID = activeSessionID else {
                presentSessionLogFailure()
                return false
            }
            let descriptor = FetchDescriptor<WorkSession>(
                predicate: #Predicate { $0.id == attendanceID }
            )
            do {
                if let existing = try modelContext.fetch(descriptor).first {
                    session = existing
                    session.task = task
                    session.startedAt = sessionStart
                        ?? Date().addingTimeInterval(-Double(elapsedSeconds))
                    session.durationSeconds = elapsedSeconds
                    session.scheduledBlockId = scheduledBlockId
                    didCompleteLinkedBlock = session.scheduledBlockId != nil
                } else {
                    session = WorkSession(
                        id: attendanceID,
                        task: task,
                        startedAt: sessionStart
                            ?? Date().addingTimeInterval(-Double(elapsedSeconds)),
                        durationSeconds: elapsedSeconds,
                        scheduledBlockId: scheduledBlockId
                    )
                    modelContext.insert(session)
                    if let scheduledBlockId,
                       let block = task.scheduledBlocks.first(where: { $0.id == scheduledBlockId }) {
                        didCompleteLinkedBlock = !block.isComplete
                        block.isComplete = true
                    } else {
                        didCompleteLinkedBlock = false
                    }
                }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                presentSessionLogFailure()
                return false
            }
            // The first step's whole job is getting the first session started;
            // once that's happened it would just be stale noise.
            task.firstStep = nil
            pendingAttendanceRecord = session
            pendingAttendanceCompletedLinkedBlock = didCompleteLinkedBlock
        }
        // Stop is a durability boundary: the session and attendance must exist
        // on disk before the optional progress step begins.
        do {
            try modelContext.save()
        } catch {
            do {
                try modelContext.save()
            } catch {
                // Keep the recovery journal, Live Activity, and foreground
                // timer intact. A later Stop can retry the pending context.
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                presentSessionLogFailure()
                return false
            }
        }
        if didCompleteLinkedBlock {
            // Attendance consumed one reservation without changing self-
            // reported progress. Restore coverage for the unchanged remainder;
            // saving progress later may legitimately reconcile once more. Do
            // not clear the recovery journal or end the Live Activity until
            // the replacement plan is durable too.
            do {
                try PlanCoordinator.reconcileTaskAfterAttendance(
                    task,
                    context: modelContext
                )
            } catch {
                // Attendance itself is already durable. Keep this same session
                // identity, timer UI, journal, and Live Activity alive so a
                // later End tap updates and retries one row instead of adding
                // a duplicate.
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                presentPlanRefreshFailure()
                return false
            }
        } else {
            PlanCoordinator.publishChange(context: modelContext)
        }
        sessionIssue = nil
        loggedSessionSeconds = elapsedSeconds
        loggedScheduledBlock = didCompleteLinkedBlock
        pendingAttendanceRecord = nil
        pendingAttendanceCompletedLinkedBlock = false
        finishRecordedSession()
        // Google import can finish while this timer still owns its scheduled
        // block. Repair those conflicts only after the session and attendance
        // above are durable, then persist the resulting plan before returning.
        do {
            _ = try PlanCoordinator.resumeDeferredBusyTimeConflictReplan(
                context: modelContext
            )
        } catch {
            // Attendance is already durable and the deferred request was put
            // back. Do not claim the conflict repair succeeded or undo the
            // user's logged work; foreground activation will retry it.
        }
        return true
    }

    /// Shared teardown is deliberately separate from attendance mutation so a
    /// failed SwiftData save cannot erase the only recoverable session state.
    private func finishRecordedSession() {
        // Scope shared teardown to the identity this view started or recovered.
        // If a stale view finishes after another task has claimed the journal,
        // the controller leaves that newer journal and Live Activity untouched.
        if let activeSessionID {
            WorkSessionActivityController.end(sessionID: activeSessionID)
        }
        UIApplication.shared.isIdleTimerDisabled = false
        isRunning = false
        isPaused = false
        elapsedSeconds = 0
        sessionStart = nil
        pausedAccumSeconds = 0
        pauseBegan = nil
        activeSessionID = nil
        scheduledBlockId = nil
        blockEndTarget = nil
        ringStartTime = nil
        ringWindowSeconds = nil
        microGoalSeconds = nil
    }

    private func saveProgress() {
        let reported = Int(progressValue)
        if reported >= 100 {
            do {
                let receipt = try PlanCoordinator.completeTask(
                    task,
                    context: modelContext,
                    reportedProgress: reported
                )
                onFinish(receipt)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                presentIssue(
                    title: "Progress not saved yet",
                    message: "Filuma couldn’t save this completion yet. Your logged session is safe—try Save progress again."
                )
            }
        } else {
            do {
                try PlanCoordinator.savePartialProgress(
                    task,
                    reportedProgress: reported,
                    context: modelContext,
                    interactive: false
                )
                onFinish(nil)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                presentIssue(
                    title: "Progress not saved yet",
                    message: "Filuma couldn’t save this progress yet. Your logged session is safe—try Save progress again."
                )
            }
        }
    }

    private func presentSessionLogFailure() {
        presentIssue(
            title: "Session not logged yet",
            message: "Your timer is still safe and still running. Try End & log session again."
        )
    }

    private func presentPlanRefreshFailure() {
        presentIssue(
            title: "Session logged; plan not refreshed yet",
            message: "Your work is safely logged, but Filuma couldn’t refresh the remaining schedule. Your session is still open—try End & log session again."
        )
    }

    private func presentIssue(title: String, message: String) {
        sessionIssue = SessionIssue(title: title, message: message)
    }
}
