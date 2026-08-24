import SwiftUI
import SwiftData
import Speech
import AVFoundation
import UIKit

struct CaptureSheetView: View {
    var onTaskCaptured: ((TaskCaptureReceipt) -> Void)? = nil
    var onReminderCaptured: ((ReminderCaptureReceipt) -> Void)? = nil
    var onBulkCaptured: ((BulkCaptureReceipt) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var title = ""
    @State private var firstStep = ""
    @State private var deadline = defaultDeadline()
    @State private var effortMinutes = 60
    @State private var context: TaskContext = .school
    @State private var customEffort = 180
    @State private var showCustomEffort = false
    @State private var showBulk = false
    @State private var showSchedulingOptions = false
    @State private var useCustomStart = false
    @State private var customStart = Date().addingTimeInterval(15 * 60)
    @State private var repeatWeekly = false
    @State private var repeatUntil = Calendar.current.date(
        byAdding: .day,
        value: 35,
        to: Date()
    ) ?? Date()

    // Capture mode: a scheduled task, or a one-off reminder
    private enum CaptureMode: String, CaseIterable {
        case task = "Task"
        case reminder = "Reminder"

        var icon: String {
            switch self {
            case .task: "calendar.badge.clock"
            case .reminder: "bell"
            }
        }

        var subtitle: String {
            switch self {
            case .task: "Get it out of your head. Filuma will find the time."
            case .reminder: "Keep one small thing from slipping away."
            }
        }
    }
    @State private var captureMode: CaptureMode = .task
    @State private var reminderDate = Date().addingTimeInterval(3600)
    @State private var showNotificationsDeniedNote = false
    @Namespace private var modeSelectionNamespace

    // Estimate reality-check: what the planned-vs-actual record says about
    // the current guess, and whether the suggestion was taken.
    @State private var estimateAdvice: EstimateAdvisor.Advice?
    @State private var estimateAccepted = false

    // Scheduling result — nothing is committed until the user confirms.
    @State private var scheduleWarning: String?
    @State private var showWarning = false
    @State private var pendingCapture: PreparedTaskCapture?
    @State private var captureIssue: String?
    @State private var captureSuccess: String?
    @State private var isSubmitting = false
    @State private var showDiscardConfirmation = false

    // Voice
    @State private var isListening = false
    @State private var speechRecognizer = SFSpeechRecognizer()
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    @State private var activeRecognitionID: UUID?
    @State private var activeVoiceAuthorizationID: UUID?
    @State private var hasInstalledAudioTap = false
    @State private var isViewActive = false
    @State private var voiceInputIssue: VoiceInputIssue?

    private enum FocusedField: Hashable {
        case title
        case firstStep
    }
    @FocusState private var focusedField: FocusedField?

    private let effortOptions = [30, 60, 120]

    private var controlAnimation: Animation? {
        reduceMotion ? HearthMotion.reduced : HearthMotion.selection
    }

    /// Layout-changing choices settle immediately with Reduce Motion. Compact
    /// color and opacity feedback can still use `controlAnimation` above.
    private var spatialAnimation: Animation? {
        reduceMotion ? nil : HearthMotion.selection
    }

    private var modeTransition: AnyTransition {
        .opacity
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMeaningfulDraft: Bool {
        !trimmedTitle.isEmpty
            || !firstStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        !trimmedTitle.isEmpty && !isSubmitting && captureSuccess == nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HearthScreenBackground(
                    topGlow: 0.18,
                    bottomGlow: 0.24,
                    embers: reduceMotion ? 0 : 10,
                    emberIntensity: 0.7
                )

                VStack(spacing: 0) {
                    sheetHeader

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            modePicker

                            if let captureIssue {
                                captureIssueBanner(captureIssue)
                            }

                            captureCard

                            Group {
                                if captureMode == .task {
                                    planShapeCard
                                    estimateAdviceRow
                                    schedulingOptionsDisclosure
                                } else {
                                    reminderCard
                                }
                            }
                            .id(captureMode)
                            .transition(modeTransition)
                        }
                        .frame(maxWidth: FilumaLayout.onboardingContentMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, FilumaSpacing.screen)
                        .padding(.top, 6)
                        .padding(.bottom, 36)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                captureActionBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showBulk) {
                BulkEntryView { receipt in
                    onBulkCaptured?(receipt)
                    dismiss()
                }
            }
            .alert("Scheduling Warning", isPresented: $showWarning) {
                Button("Make Room") { makeRoom() }
                Button("Save Anyway") { commitPending() }
                Button("Cancel", role: .cancel) { discardPending() }
            } message: {
                Text(scheduleWarning ?? "")
            }
            .alert(item: $voiceInputIssue) { issue in
                if issue.offersSettings {
                    return Alert(
                        title: Text(issue.title),
                        message: Text(issue.message),
                        primaryButton: .default(Text("Open Settings"), action: openAppSettings),
                        secondaryButton: .cancel(Text("Not now"))
                    )
                }
                return Alert(
                    title: Text(issue.title),
                    message: Text(issue.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onAppear {
                isViewActive = true
                if !voiceOverEnabled {
                    Task { @MainActor in
                        await Task.yield()
                        focusedField = .title
                    }
                }
                refreshEstimateAdvice()
            }
            .onChange(of: context) { _, _ in
                estimateAccepted = false
                refreshEstimateAdvice()
            }
            .onChange(of: effortMinutes) { _, newValue in
                // Accepting the suggestion changes the effort too — don't
                // treat that as a fresh guess and immediately re-advise on it.
                if estimateAccepted && newValue == estimateAdvice?.suggestedMinutes { return }
                estimateAccepted = false
                refreshEstimateAdvice()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    activeVoiceAuthorizationID = nil
                    if isListening || hasInstalledAudioTap { stopListening() }
                } else if newPhase == .inactive,
                          isListening || hasInstalledAudioTap {
                    // A speech or microphone permission sheet also makes the
                    // scene inactive. Keep its authorization token alive, but
                    // stop an already-running recorder if another interruption
                    // takes focus away from the app.
                    stopListening()
                }
            }
            .onDisappear {
                isViewActive = false
                activeVoiceAuthorizationID = nil
                if isListening || hasInstalledAudioTap { stopListening() }
            }
            .confirmationDialog(
                "Discard this capture?",
                isPresented: $showDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    discardPending()
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("Your title and choices have not been saved yet.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(FilumaRadius.sheet)
        .interactiveDismissDisabled(hasMeaningfulDraft || isSubmitting)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick capture")
                    .font(AppFont.caption(10))
                    .foregroundStyle(Color.brand300)

                Text("Capture")
                    .font(AppFont.title(25))
                    .foregroundStyle(Color.filumaText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("capture.title")

                Text(captureMode.subtitle)
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.filumaSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(controlAnimation, value: captureMode)
            }

            Spacer(minLength: 8)

            if captureMode == .task {
                Button {
                    focusedField = nil
                    showBulk = true
                } label: {
                    Label("Bulk", systemImage: "rectangle.stack.badge.plus")
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.brand300)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.brand500.opacity(0.1), in: Capsule())
                        .contentShape(Rectangle())
                }
                .hearthPressStyle(scale: 0.97, pressedOpacity: 0.82)
                .disabled(isSubmitting || captureSuccess != nil)
                .opacity(isSubmitting || captureSuccess != nil ? 0.48 : 1)
                .accessibilityLabel("Bulk add")
                .accessibilityIdentifier("capture.bulk")
            }

            Button(action: requestDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.filumaSubtle)
                    .frame(width: 44, height: 44)
                    .background(Color.filumaSurface2, in: Circle())
                    .contentShape(Circle())
            }
            .hearthPressStyle(scale: 0.94, pressedOpacity: 0.76)
            .disabled(isSubmitting)
            .opacity(isSubmitting ? 0.48 : 1)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("capture.close")
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: FilumaLayout.onboardingContentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(spatialAnimation) {
                        captureMode = mode
                        captureIssue = nil
                        showNotificationsDeniedNote = false
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(mode.rawValue)
                            .font(AppFont.bodySemibold(13))
                            .lineLimit(1)
                    }
                    .foregroundStyle(captureMode == mode ? Color.brand100 : Color.filumaSubtle)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        if captureMode == mode {
                            if reduceMotion {
                                captureModeSelectionCapsule
                            } else {
                                captureModeSelectionCapsule
                                    .matchedGeometryEffect(
                                        id: "capture-mode",
                                        in: modeSelectionNamespace
                                    )
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || captureSuccess != nil)
                .accessibilityAddTraits(captureMode == mode ? [.isSelected] : [])
                .accessibilityIdentifier("capture.mode.\(mode.rawValue.lowercased())")
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.filumaSurface))
        .overlay(Capsule().stroke(Color.filumaBorder, lineWidth: 1))
    }

    private var captureModeSelectionCapsule: some View {
        Capsule()
            .fill(Color.brand500.opacity(0.24))
            .overlay(Capsule().stroke(Color.brand500.opacity(0.34), lineWidth: 1))
    }

    // MARK: - Authored form surfaces

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleField

            if captureMode == .task {
                Divider()
                    .overlay(Color.filumaBorder)
                    .padding(.vertical, 14)
                firstStepField
            }
        }
        .padding(16)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.hero, style: .continuous)
                .stroke(
                    focusedField != nil || isListening
                        ? Color.brand500.opacity(0.38)
                        : Color.filumaBorder,
                    lineWidth: 1
                )
        }
        .hearthGlow(
            .brand500,
            radius: focusedField != nil || isListening ? 16 : 0,
            opacity: focusedField != nil || isListening ? 0.12 : 0
        )
        .animation(controlAnimation, value: focusedField)
        .animation(controlAnimation, value: isListening)
    }

    private var planShapeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            captureSectionHeading(
                eyebrow: "Plan shape",
                message: "Enough structure to place the work—nothing more."
            )
            contextPicker
            captureDivider
            deadlinePicker
            captureDivider
            effortPicker
        }
        .padding(16)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        }
    }

    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            captureSectionHeading(
                eyebrow: "When",
                message: "Filuma keeps the reminder here even if notifications are off."
            )
            reminderDatePicker
        }
        .padding(16)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        }
    }

    private var captureDivider: some View {
        Divider().overlay(Color.filumaBorder)
    }

    private func captureSectionHeading(
        eyebrow: String,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(AppFont.heading(14))
                .foregroundStyle(Color.filumaText)
            Text(message)
                .font(AppFont.body(12))
                .foregroundStyle(Color.filumaSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func captureIssueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.filumaRed)
                .accessibilityHidden(true)
            Text(message)
                .font(AppFont.body(13))
                .foregroundStyle(Color.filumaText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.filumaRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                .stroke(Color.filumaRed.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("capture.issue")
    }

    // MARK: - Fixed action boundary

    private var captureActionBar: some View {
        VStack(spacing: 8) {
            if showNotificationsDeniedNote {
                Text("Saved in Filuma. Notifications are off, so no alert will fire.")
                    .font(AppFont.body(12))
                    .foregroundStyle(Color.filumaSubtle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: performPrimaryAction) {
                HStack(spacing: 9) {
                    if isSubmitting {
                        ProgressView()
                            .tint(Color.filumaControlInk)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: primaryActionIcon)
                            .font(.system(size: 16, weight: .bold))
                            .accessibilityHidden(true)
                    }
                    Text(primaryActionTitle)
                        .lineLimit(1)
                }
                .primaryButtonStyle(enabled: canSubmit || captureSuccess != nil)
            }
            .disabled(!canSubmit && captureSuccess == nil)
            .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
            .accessibilityIdentifier(
                captureSuccess == nil ? "capture.primaryAction" : "capture.success"
            )
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: FilumaLayout.onboardingContentMaxWidth)
        .frame(maxWidth: .infinity)
        .background(Color.filumaBackground.opacity(0.98).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.filumaBorder)
                .frame(height: 1)
        }
    }

    private var primaryActionTitle: String {
        if let captureSuccess { return captureSuccess }
        if isSubmitting { return "Saving…" }
        return captureMode == .task ? "Schedule task" : "Set reminder"
    }

    private var primaryActionIcon: String {
        if captureSuccess != nil { return "checkmark" }
        return captureMode == .task ? "calendar.badge.clock" : "bell.badge"
    }

    private func performPrimaryAction() {
        if captureSuccess != nil {
            dismiss()
        } else if captureMode == .task {
            attemptSchedule()
        } else {
            saveReminder()
        }
    }

    private func requestDismiss() {
        guard !isSubmitting else { return }
        focusedField = nil
        if hasMeaningfulDraft {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    // MARK: - Reminder form

    private var reminderDatePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remind me at")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            DatePicker(
                "",
                selection: $reminderDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(Color.brand500)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Remind me at")
            .accessibilityIdentifier("capture.reminderDate")

            if showNotificationsDeniedNote {
                Button("Open notification settings", action: openAppSettings)
                    .font(AppFont.bodySemibold(12))
                    .foregroundStyle(Color.brand300)
                    .frame(minHeight: 44)
            }
        }
    }

    // MARK: - Title Field

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(captureMode == .task ? "Task" : "Reminder")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            HStack(spacing: 12) {
                TextField(
                    captureMode == .task
                        ? "e.g. Finish lab report"
                        : "e.g. Bring the permission form",
                    text: $title
                )
                    .font(AppFont.heading(19))
                    .foregroundStyle(Color.filumaText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .focused($focusedField, equals: .title)
                    .submitLabel(captureMode == .task ? .next : .done)
                    .onSubmit {
                        if captureMode == .task {
                            focusedField = .firstStep
                        } else {
                            focusedField = nil
                        }
                    }
                    .accessibilityIdentifier("capture.taskTitleField")

                Button {
                    toggleVoiceInput()
                } label: {
                    Image(systemName: isListening ? "mic.fill" : "mic")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isListening ? Color.filumaRed : Color.filumaSubtle)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isListening ? Color.filumaRed.opacity(0.13) : Color.filumaSurface2)
                        )
                }
                .contentShape(Circle())
                .disabled(isSubmitting || captureSuccess != nil)
                .opacity(isSubmitting || captureSuccess != nil ? 0.48 : 1)
                .accessibilityLabel(isListening ? "Stop voice input" : "Start voice input")
                .accessibilityValue(isListening ? "Listening" : "Not listening")
                .accessibilityHint(
                    isListening
                        ? "Stops listening and keeps the current task title."
                        : "Uses speech to fill in the task title."
                )
                .accessibilityIdentifier("capture.voiceInputButton")
            }
        }
    }

    // MARK: - First Step Field

    /// Optional, never required — but a concrete opening move is what makes a
    /// task startable later. Surfaces in the hero card, the block-start nudge,
    /// and the work session timer.
    private var firstStepField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First move · Optional")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            TextField("e.g. Open the doc and paste the data", text: $firstStep)
                .font(AppFont.body(15))
                .foregroundStyle(Color.filumaText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .submitLabel(.done)
                .focused($focusedField, equals: .firstStep)
                .onSubmit { focusedField = nil }
                .accessibilityIdentifier("capture.firstStepField")
        }
    }

    // MARK: - Context Picker

    private var contextPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        contextChoices
                    }
                } else {
                    HStack(spacing: 8) {
                        contextChoices
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contextChoices: some View {
        ForEach(TaskContext.allCases) { ctx in
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation(controlAnimation) {
                    context = ctx
                }
            } label: {
                Label(ctx.rawValue, systemImage: ctx.icon)
                    .font(AppFont.caption(12))
                    .foregroundStyle(context == ctx ? Color.filumaControlInk : Color.filumaText)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(
                        maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                        minHeight: 44
                    )
                    .background(
                        Capsule()
                            .fill(context == ctx ? ctx.color : Color.filumaSurface2)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(context == ctx ? [.isSelected] : [])
            .accessibilityIdentifier("capture.context.\(ctx.rawValue.lowercased())")
        }
    }

    // MARK: - Deadline Picker

    private var deadlinePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deadline")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            DatePicker(
                "",
                selection: $deadline,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(Color.brand500)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Deadline")
            .accessibilityIdentifier("capture.deadline")
        }
    }

    // MARK: - Effort Picker

    private var effortPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated effort")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        effortChoices
                    }
                } else {
                    HStack(spacing: 8) {
                        effortChoices
                    }
                }
            }

            if showCustomEffort {
                HStack(spacing: 12) {
                    Text(CountdownFormatter.effortString(minutes: customEffort))
                        .font(AppFont.mono(15))
                        .foregroundStyle(Color.filumaText)
                    Spacer(minLength: 8)
                    captureAdjustmentButton(
                        systemName: "minus",
                        label: "Decrease custom effort",
                        identifier: "capture.customEffort.decrement",
                        isDisabled: customEffort <= 180
                    ) {
                        customEffort = max(180, customEffort - 30)
                    }
                    captureAdjustmentButton(
                        systemName: "plus",
                        label: "Increase custom effort",
                        identifier: "capture.customEffort.increment",
                        isDisabled: customEffort >= 720,
                        isPrimary: true
                    ) {
                        customEffort = min(720, customEffort + 30)
                    }
                }
                .onChange(of: customEffort) { _, newValue in
                    effortMinutes = newValue
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var effortChoices: some View {
        ForEach(effortOptions, id: \.self) { mins in
            EffortChip(
                label: CountdownFormatter.effortString(minutes: mins),
                isSelected: !showCustomEffort && effortMinutes == mins,
                identifier: "capture.effort.\(mins)",
                fillsWidth: dynamicTypeSize.isAccessibilitySize
            ) {
                chooseEffort(mins)
            }
        }
        EffortChip(
            label: "3h+",
            isSelected: showCustomEffort,
            identifier: "capture.effort.custom",
            fillsWidth: dynamicTypeSize.isAccessibilitySize
        ) {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(spatialAnimation) {
                showCustomEffort = true
                effortMinutes = customEffort
            }
        }
    }

    private func chooseEffort(_ minutes: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(spatialAnimation) {
            showCustomEffort = false
            effortMinutes = minutes
        }
    }

    private func captureAdjustmentButton(
        systemName: String,
        label: String,
        identifier: String,
        isDisabled: Bool,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isPrimary ? Color.filumaControlInk : Color.filumaText)
                .frame(width: 44, height: 44)
                .background(isPrimary ? Color.brand500 : Color.filumaSurface3)
                .clipShape(
                    RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: FilumaRadius.button,
                        style: .continuous
                    )
                    .stroke(
                        isPrimary ? Color.brand300.opacity(0.5) : Color.filumaBorder,
                        lineWidth: 1
                    )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Repeat picker

    /// Weekly problem sets, readings, chores: capture once, and a fresh copy
    /// with the same shape appears each week until the end date.
    private var repeatPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repeats")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { repeatChoices }
                } else {
                    HStack(spacing: 8) { repeatChoices }
                }
            }

            if repeatWeekly {
                HStack {
                    Text("Until")
                        .font(AppFont.body(13))
                        .foregroundStyle(Color.filumaSubtle)
                    Spacer(minLength: 8)
                    DatePicker(
                        "",
                        selection: $repeatUntil,
                        in: Date()...,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Color.brand500)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Repeat until")
                }
                .padding(.top, 2)
                Text("A fresh copy appears each week, scheduled around whatever that week holds.")
                    .font(AppFont.body(11))
                    .foregroundStyle(Color.filumaFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var repeatChoices: some View {
        EffortChip(
            label: "One-off",
            isSelected: !repeatWeekly,
            identifier: "capture.repeat.oneOff",
            fillsWidth: dynamicTypeSize.isAccessibilitySize
        ) {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(spatialAnimation) {
                        repeatWeekly = false
            }
        }
        EffortChip(
            label: "Weekly",
            isSelected: repeatWeekly,
            identifier: "capture.repeat.weekly",
            fillsWidth: dynamicTypeSize.isAccessibilitySize
        ) {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(spatialAnimation) {
                repeatWeekly = true
                let nextWeek = Calendar.current.date(
                    byAdding: .day,
                    value: 7,
                    to: deadline
                ) ?? deadline
                repeatUntil = max(repeatUntil, nextWeek)
            }
        }
    }

    // MARK: - Estimate reality-check

    /// A gentle line from the record, not a lecture: "your last N tasks like
    /// this ran over — plan for X instead?" with a one-tap accept.
    @ViewBuilder
    private var estimateAdviceRow: some View {
        if let advice = estimateAdvice {
            if estimateAccepted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.personalColor)
                        .accessibilityHidden(true)
                    Text("Planned for \(CountdownFormatter.effortString(minutes: effortMinutes)) — future you says thanks.")
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.filumaSubtle)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.workColor)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        Text("Your last \(advice.sampleCount) \(context.rawValue) tasks ran about \(advice.ratioLabel) over their estimates.")
                            .font(AppFont.body(13))
                            .foregroundStyle(Color.filumaText)
                    }

                    Button {
                        acceptEstimateSuggestion()
                    } label: {
                        Text("Plan for \(CountdownFormatter.effortString(minutes: advice.suggestedMinutes)) instead")
                            .font(AppFont.caption(13))
                            .foregroundStyle(Color.filumaControlInk)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Color.workColor, in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.workColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                        .stroke(Color.workColor.opacity(0.25), lineWidth: 1)
                )
            }
        }
    }

    private func refreshEstimateAdvice() {
        estimateAdvice = EstimateAdvisor.advice(
            for: context,
            effortMinutes: effortMinutes,
            in: modelContext
        )
    }

    private func acceptEstimateSuggestion() {
        guard let advice = estimateAdvice else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(spatialAnimation) {
            if advice.suggestedMinutes >= 180 {
                showCustomEffort = true
                customEffort = advice.suggestedMinutes
            } else {
                showCustomEffort = false
            }
            effortMinutes = advice.suggestedMinutes
            estimateAccepted = true
        }
    }

    // MARK: - More scheduling options

    /// Repeat and delayed-start controls are valuable, but not part of the
    /// minimum path from thought to scheduled task. Keep them together in one
    /// calm disclosure and surface any non-default choices after it closes.
    private var schedulingOptionsDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation(spatialAnimation) {
                    showSchedulingOptions.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brand300)
                        .frame(width: 32, height: 32)
                        .background(Color.brand500.opacity(0.14), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("More scheduling options")
                            .font(AppFont.bodySemibold(14))
                            .foregroundStyle(Color.filumaText)

                        if !showSchedulingOptions,
                           let summary = schedulingOptionsSummary {
                            Text(summary)
                                .font(AppFont.caption(11))
                                .foregroundStyle(Color.brand300)
                                .transition(.opacity)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.filumaSubtle)
                        .rotationEffect(.degrees(showSchedulingOptions ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hearthPressStyle(scale: 0.985, pressedOpacity: 0.8)
            .accessibilityIdentifier("capture.moreSchedulingOptions")
            .accessibilityLabel(schedulingOptionsAccessibilityLabel)
            .accessibilityValue(showSchedulingOptions ? "Expanded" : "Collapsed")
            .accessibilityHint(
                showSchedulingOptions
                    ? "Hides repeat and earliest start controls"
                    : "Shows repeat and earliest start controls"
            )

            if showSchedulingOptions {
                VStack(alignment: .leading, spacing: 20) {
                    Divider()
                        .overlay(Color.filumaBorder)
                    repeatPicker
                    startPicker
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }
        }
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        )
    }

    private var schedulingOptionsSummary: String? {
        var choices: [String] = []
        if repeatWeekly { choices.append("Weekly") }
        if useCustomStart { choices.append("Starts later") }
        return choices.isEmpty ? nil : choices.joined(separator: " · ")
    }

    private var schedulingOptionsAccessibilityLabel: String {
        guard let summary = schedulingOptionsSummary else {
            return "More scheduling options"
        }
        return "More scheduling options, \(summary)"
    }

    // MARK: - Earliest start

    private var startPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Earliest start")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { startChoices }
                } else {
                    HStack(spacing: 8) { startChoices }
                }
            }

            if useCustomStart {
                DatePicker(
                    "",
                    selection: $customStart,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(Color.brand500)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Earliest start")
                .padding(.top, 4)
            } else {
                Text("Leaves a short gap before your first block so you can settle in.")
                    .font(AppFont.body(11))
                    .foregroundStyle(Color.filumaFaint)
            }
        }
    }

    @ViewBuilder
    private var startChoices: some View {
        EffortChip(
            label: "Soon",
            isSelected: !useCustomStart,
            identifier: "capture.start.soon",
            fillsWidth: dynamicTypeSize.isAccessibilitySize
        ) {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(spatialAnimation) {
                useCustomStart = false
            }
        }
        EffortChip(
            label: "Pick a time",
            isSelected: useCustomStart,
            identifier: "capture.start.custom",
            fillsWidth: dynamicTypeSize.isAccessibilitySize
        ) {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(spatialAnimation) {
                useCustomStart = true
                customStart = max(customStart, Date())
            }
        }
    }

    // MARK: - Scheduling Logic

    private func attemptSchedule() {
        guard canSubmit else { return }
        discardPending()
        focusedField = nil
        captureIssue = nil
        isSubmitting = true

        let prepared: PreparedTaskCapture
        do {
            prepared = try CaptureCoordinator.prepareTask(
                title: title,
                firstStep: firstStep,
                taskContext: context,
                deadline: deadline,
                effortMinutes: effortMinutes,
                preferredStart: useCustomStart ? customStart : nil,
                context: modelContext
            )
        } catch {
            failCapture("Filuma couldn't read your plan yet. Your capture is still here—try again.")
            return
        }

        pendingCapture = prepared
        switch prepared.result {
        case .success(let blocks):
            guard !blocks.isEmpty || effortMinutes == 0 else {
                isSubmitting = false
                scheduleWarning = "No open gaps appeared before your deadline. Make Room can rebuild the plan around this task, or you can adjust the deadline."
                showWarning = true
                return
            }
            commitPending()

        case .partialFit(_, let unscheduledMinutes):
            isSubmitting = false
            let timeStr = CountdownFormatter.effortString(minutes: unscheduledMinutes)
            scheduleWarning = "\(timeStr) of effort couldn't fit in the open gaps before your deadline. Make Room moves later-deadline work aside; Save Anyway keeps the partial plan."
            showWarning = true

        case .noSlots:
            isSubmitting = false
            scheduleWarning = "No open gaps before your deadline. Make Room moves later-deadline work aside, or extend the deadline."
            showWarning = true
        }
    }

    private func commitPending() {
        guard let pendingCapture else { return }
        isSubmitting = true
        do {
            let receipt = try CaptureCoordinator.commit(
                pendingCapture,
                repeatWeeklyUntil: repeatWeekly ? repeatUntil : nil,
                context: modelContext
            )
            self.pendingCapture = nil
            finishTaskCapture(receipt)
        } catch {
            CaptureCoordinator.discard(pendingCapture)
            self.pendingCapture = nil
            failCapture("Filuma couldn't save this task yet. Your words are still here—try again.")
        }
    }

    /// The new task doesn't fit in the gaps: commit it and rebuild the whole
    /// plan by deadline, letting it bump later-deadline work.
    private func makeRoom() {
        guard let pendingCapture else { return }
        isSubmitting = true
        do {
            let receipt = try CaptureCoordinator.commitMakingRoom(
                pendingCapture,
                repeatWeeklyUntil: repeatWeekly ? repeatUntil : nil,
                context: modelContext
            )
            self.pendingCapture = nil
            finishTaskCapture(receipt)
        } catch {
            CaptureCoordinator.discard(pendingCapture)
            self.pendingCapture = nil
            failCapture("Filuma couldn't rebuild your plan yet. Nothing was added—try again.")
        }
    }

    private func discardPending() {
        guard let pendingCapture else { return }
        CaptureCoordinator.discard(pendingCapture)
        self.pendingCapture = nil
        isSubmitting = false
    }

    private func finishTaskCapture(_ receipt: TaskCaptureReceipt) {
        isSubmitting = false
        captureSuccess = receipt.unscheduledMinutes > 0
            ? "Task saved"
            : "Added to your plan"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onTaskCaptured?(receipt)

        let timing: String
        if let firstBlockStart = receipt.firstBlockStart {
            timing = ", starting \(firstBlockStart.formatted(date: .omitted, time: .shortened))"
        } else if receipt.unscheduledMinutes > 0 {
            timing = ", with \(CountdownFormatter.effortString(minutes: receipt.unscheduledMinutes)) still to place"
        } else {
            timing = ""
        }
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(receipt.title) added to your plan\(timing)."
        )

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard isViewActive, captureSuccess != nil else { return }
            dismiss()
        }
    }

    private func saveReminder() {
        guard canSubmit else { return }
        focusedField = nil
        captureIssue = nil
        isSubmitting = true

        let receipt: ReminderCaptureReceipt
        do {
            receipt = try CaptureCoordinator.saveReminder(
                title: title,
                dueDate: reminderDate,
                context: modelContext
            )
        } catch {
            failCapture("Filuma couldn't save this reminder yet. Your words are still here—try again.")
            return
        }

        onReminderCaptured?(receipt)
        Task { @MainActor in
            let granted = await NotificationService.requestAuthorization()
            guard isViewActive else { return }

            isSubmitting = false
            captureSuccess = "Reminder saved"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(receipt.title) saved for \(receipt.dueDate.formatted(date: .abbreviated, time: .shortened))."
            )

            guard granted else {
                showNotificationsDeniedNote = true
                return
            }
            NotificationService.schedule(receipt: receipt)
            try? await Task.sleep(for: .milliseconds(700))
            guard isViewActive else { return }
            dismiss()
        }
    }

    private func failCapture(_ message: String) {
        isSubmitting = false
        captureIssue = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private static func defaultDeadline() -> Date {
        Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    }

    // MARK: - Voice Input

    private func toggleVoiceInput() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        guard speechRecognizer?.isAvailable == true else {
            voiceInputIssue = .recognizerUnavailable
            return
        }

        let authorizationID = UUID()
        activeVoiceAuthorizationID = authorizationID
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard isViewActive,
                      activeVoiceAuthorizationID == authorizationID,
                      scenePhase != .background else { return }

                switch status {
                case .authorized:
                    requestMicrophoneAccess(authorizationID: authorizationID)
                case .denied, .restricted:
                    activeVoiceAuthorizationID = nil
                    voiceInputIssue = .speechPermission
                case .notDetermined:
                    activeVoiceAuthorizationID = nil
                    voiceInputIssue = .recognizerUnavailable
                @unknown default:
                    activeVoiceAuthorizationID = nil
                    voiceInputIssue = .recognizerUnavailable
                }
            }
        }
    }

    private func requestMicrophoneAccess(authorizationID: UUID) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard isViewActive,
                      activeVoiceAuthorizationID == authorizationID,
                      scenePhase != .background else { return }
                guard granted else {
                    activeVoiceAuthorizationID = nil
                    voiceInputIssue = .microphonePermission
                    return
                }
                beginRecognition(authorizationID: authorizationID)
            }
        }
    }

    private func beginRecognition(authorizationID: UUID) {
        guard isViewActive,
              activeVoiceAuthorizationID == authorizationID else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            activeVoiceAuthorizationID = nil
            voiceInputIssue = .recognizerUnavailable
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            activeVoiceAuthorizationID = nil
            voiceInputIssue = .audioUnavailable
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledAudioTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
            request.endAudio()
            recognitionRequest = nil
            activeVoiceAuthorizationID = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            voiceInputIssue = .audioUnavailable
            return
        }
        activeVoiceAuthorizationID = nil
        isListening = true

        let recognitionID = UUID()
        activeRecognitionID = recognitionID
        recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                guard isViewActive,
                      activeRecognitionID == recognitionID else { return }

                if let result {
                    title = result.bestTranscription.formattedString
                }

                if error != nil {
                    stopListening()
                    voiceInputIssue = .recognitionFailed
                } else if result?.isFinal ?? false {
                    stopListening()
                }
            }
        }
    }

    private func stopListening() {
        activeVoiceAuthorizationID = nil
        activeRecognitionID = nil
        audioEngine.stop()
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private enum VoiceInputIssue: String, Identifiable {
    case speechPermission
    case microphonePermission
    case recognizerUnavailable
    case audioUnavailable
    case recognitionFailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speechPermission:
            "Speech recognition is off"
        case .microphonePermission:
            "Microphone access is off"
        case .recognizerUnavailable:
            "Voice input isn't available"
        case .audioUnavailable:
            "Couldn't start voice input"
        case .recognitionFailed:
            "Voice input stopped"
        }
    }

    var message: String {
        switch self {
        case .speechPermission:
            "Allow Speech Recognition in Settings to speak a task. You can still type it here."
        case .microphonePermission:
            "Allow Microphone access in Settings to speak a task. You can still type it here."
        case .recognizerUnavailable:
            "Voice input isn't ready right now. Try again in a moment, or type the task instead."
        case .audioUnavailable:
            "The microphone didn't start. Try again, or type the task instead."
        case .recognitionFailed:
            "Your spoken title couldn't be finished. You can try again or keep typing."
        }
    }

    var offersSettings: Bool {
        self == .speechPermission || self == .microphonePermission
    }
}

// MARK: - Effort Chip

private struct EffortChip: View {
    let label: String
    let isSelected: Bool
    let identifier: String
    let fillsWidth: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(AppFont.caption(12))
                .foregroundStyle(isSelected ? Color.filumaControlInk : Color.filumaText)
                .padding(.horizontal, 14)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.brand100 : Color.filumaSurface2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}
