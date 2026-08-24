import SwiftUI
import SwiftData

/// Edit an existing task. Changes stay in this draft until Save; edits that
/// invalidate the plan (deadline or effort) use the existing reschedule path.
struct TaskEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let task: FilumaTask
    /// Overdue-triage entry point: preload a doable future deadline and put
    /// that decision before the rest of the task details.
    var emphasizeDeadline: Bool = false

    @State private var title = ""
    @State private var firstStep = ""
    @State private var context: TaskContext = .school
    @State private var deadline = Date()
    @State private var effortMinutes = 60
    @State private var earliestDeadline = Date()
    @State private var savedDraft: TaskEditDraft?
    @State private var didLoadTask = false

    @State private var scheduleWarningTitle = "Scheduling warning"
    @State private var scheduleWarning: String?
    @State private var showWarning = false
    @State private var warningAllowsDismissal = true
    @State private var showDiscardConfirmation = false

    private enum FocusedField: Hashable {
        case title
        case firstStep
    }

    @FocusState private var focusedField: FocusedField?

    private struct TaskEditDraft: Equatable {
        let title: String
        let firstStep: String
        let context: TaskContext
        let deadline: Date
        let effortMinutes: Int
    }

    private var selectionAnimation: Animation {
        reduceMotion ? HearthMotion.reduced : HearthMotion.selection
    }

    private var currentDraft: TaskEditDraft {
        TaskEditDraft(
            title: title,
            firstStep: firstStep,
            context: context,
            deadline: deadline,
            effortMinutes: effortMinutes
        )
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var titleValidationMessage: String? {
        guard didLoadTask, trimmedTitle.isEmpty else { return nil }
        return "Enter a task title before saving."
    }

    private var deadlineValidationMessage: String? {
        guard didLoadTask, deadline <= earliestDeadline else { return nil }
        return "Choose a deadline that has not passed."
    }

    private var isValid: Bool {
        !trimmedTitle.isEmpty && deadline > earliestDeadline
    }

    private var isDraftDirty: Bool {
        guard didLoadTask, let savedDraft else { return false }
        return currentDraft != savedDraft
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HearthScreenBackground(
                    topGlow: 0.14,
                    bottomGlow: 0.2,
                    embers: reduceMotion ? 0 : 8,
                    emberIntensity: 0.56
                )

                VStack(spacing: 0) {
                    sheetHeader

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if emphasizeDeadline {
                                deadlineFocusCard
                                taskDetailsCard
                                planShapeCard(includesDeadline: false)
                            } else {
                                taskDetailsCard
                                planShapeCard(includesDeadline: true)
                            }
                        }
                        .frame(maxWidth: FilumaLayout.readableContentMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, FilumaSpacing.screen)
                        .padding(.top, 4)
                        .padding(.bottom, 32)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                saveActionBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert(scheduleWarningTitle, isPresented: $showWarning) {
                Button("Keep Editing", role: .cancel) { }
                if warningAllowsDismissal {
                    Button("Done") { dismiss() }
                }
            } message: {
                Text(scheduleWarning ?? "")
            }
            .alert("Discard unsaved changes?", isPresented: $showDiscardConfirmation) {
                Button("Keep Editing", role: .cancel) { }
                Button("Discard Changes", role: .destructive) { dismiss() }
            } message: {
                Text("Your latest edits have not been saved. The task will keep its last saved details.")
            }
            .onAppear(perform: loadTask)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(FilumaRadius.sheet)
        // A clean draft can still use the familiar sheet gesture. Once a field
        // changes, Cancel provides the explicit discard decision instead.
        .interactiveDismissDisabled(!didLoadTask || isDraftDirty)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(emphasizeDeadline ? "OVERDUE TASK" : "TASK DETAILS")
                    .font(AppFont.caption(10))
                    .foregroundStyle(Color.brand300)
                    .kerning(1.6)

                Spacer(minLength: 8)

                cancelButton
            }

            Text(emphasizeDeadline ? "Choose a new deadline" : "Edit task")
                .font(AppFont.title(25))
                .foregroundStyle(Color.filumaText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("taskEdit.title")

            Text(
                emphasizeDeadline
                    ? "Give this work a doable place to land, then adjust anything else that changed."
                    : "Keep the task recognizable while Filuma holds the plan around it."
            )
            .font(AppFont.body(12))
            .foregroundStyle(Color.filumaSubtle)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: FilumaLayout.readableContentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var cancelButton: some View {
        Button(action: requestDismiss) {
            Text("Cancel")
                .font(AppFont.bodySemibold(13))
                .foregroundStyle(Color.filumaSubtle)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color.filumaSurface2, in: Capsule())
                .contentShape(Rectangle())
        }
        .hearthPressStyle(scale: 0.96, pressedOpacity: 0.78)
        .accessibilityHint("Closes the editor. Unsaved changes require confirmation.")
        .accessibilityIdentifier("taskEdit.cancel")
    }

    // MARK: - Authored form surfaces

    private var taskDetailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(
                eyebrow: "The work",
                message: "Name it clearly, then leave yourself one easy way in."
            )

            titleField
                .padding(.top, 16)

            taskEditDivider
                .padding(.vertical, 14)

            firstStepField
        }
        .padding(16)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.hero, style: .continuous)
                .stroke(
                    focusedField != nil
                        ? Color.brand500.opacity(0.38)
                        : Color.filumaBorder,
                    lineWidth: 1
                )
        }
        .hearthGlow(
            .brand500,
            radius: focusedField != nil ? 14 : 0,
            opacity: focusedField != nil ? 0.1 : 0
        )
        .animation(selectionAnimation, value: focusedField)
    }

    private var deadlineFocusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading(
                eyebrow: "Start here",
                message: "This date has passed. Pick a time you can still act on."
            )
            deadlinePicker
        }
        .padding(16)
        .background(Color.brand500.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.brand500.opacity(0.4), lineWidth: 1.5)
        }
    }

    private func planShapeCard(includesDeadline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading(
                eyebrow: "Plan shape",
                message: includesDeadline
                    ? "These choices decide where the work can fit."
                    : "Confirm the setting and how much work remains."
            )

            contextPicker

            if includesDeadline {
                taskEditDivider
                deadlinePicker
            }

            taskEditDivider
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

    private var taskEditDivider: some View {
        Divider().overlay(Color.filumaBorder)
    }

    private func sectionHeading(eyebrow: String, message: String) -> some View {
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

    // MARK: - Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            TextField("Task title", text: $title)
                .font(AppFont.heading(19))
                .foregroundStyle(Color.filumaText)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Color.filumaSurface2)
                .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                        .stroke(
                            titleValidationMessage == nil
                                ? Color.filumaBorder
                                : Color.filumaRed.opacity(0.65),
                            lineWidth: 1
                        )
                }
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .onSubmit { focusedField = .firstStep }
                .accessibilityIdentifier("taskEdit.titleField")

            Group {
                if let titleValidationMessage {
                    validationMessage(titleValidationMessage, identifier: "taskEdit.titleValidation")
                } else {
                    Color.clear
                        .frame(height: 16)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 16, alignment: .topLeading)
        }
    }

    private var firstStepField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First move · Optional")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            TextField("The very first physical action", text: $firstStep)
                .font(AppFont.body(15))
                .foregroundStyle(Color.filumaText)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Color.filumaSurface2)
                .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                        .stroke(Color.filumaBorder, lineWidth: 1)
                }
                .focused($focusedField, equals: .firstStep)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
                .accessibilityIdentifier("taskEdit.firstStepField")
        }
    }

    private var contextPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
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
        ForEach(TaskContext.allCases) { choice in
            Button {
                withAnimation(selectionAnimation) {
                    context = choice
                }
            } label: {
                Label(choice.rawValue, systemImage: choice.icon)
                    .font(AppFont.caption(12))
                    .foregroundStyle(
                        context == choice ? Color.filumaControlInk : Color.filumaText
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                            .fill(context == choice ? choice.color : Color.filumaSurface2)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                            .stroke(
                                context == choice
                                    ? choice.displayColor.opacity(0.45)
                                    : Color.filumaBorder,
                                lineWidth: 1
                            )
                    }
                    .contentShape(Rectangle())
            }
            .hearthPressStyle(scale: 0.97, pressedOpacity: 0.8)
            .accessibilityAddTraits(context == choice ? [.isSelected] : [])
            .accessibilityIdentifier("taskEdit.context.\(choice.rawValue.lowercased())")
        }
    }

    private var deadlinePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emphasizeDeadline ? "New deadline" : "Deadline")
                .font(AppFont.caption(12))
                .foregroundStyle(emphasizeDeadline ? Color.brand300 : Color.filumaSubtle)

            DatePicker(
                "",
                selection: $deadline,
                in: earliestDeadline...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(Color.brand500)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityLabel(emphasizeDeadline ? "New deadline" : "Deadline")
            .accessibilityValue(
                deadline.formatted(date: .abbreviated, time: .shortened)
            )
            .accessibilityIdentifier("taskEdit.deadline")

            Group {
                if let deadlineValidationMessage {
                    validationMessage(
                        deadlineValidationMessage,
                        identifier: "taskEdit.deadlineValidation"
                    )
                } else if emphasizeDeadline {
                    Text("The schedule rebuilds around this choice when you save.")
                        .font(AppFont.body(12))
                        .foregroundStyle(Color.filumaSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("taskEdit.deadlineHint")
                } else {
                    Color.clear
                        .frame(height: 16)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 16, alignment: .topLeading)
        }
    }

    private var effortPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated effort")
                .font(AppFont.caption(12))
                .foregroundStyle(Color.filumaSubtle)

            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    Text(CountdownFormatter.effortString(minutes: effortMinutes))
                        .font(AppFont.mono(15))
                        .foregroundStyle(Color.filumaText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Estimated effort")
                        .accessibilityValue(
                            CountdownFormatter.effortString(minutes: effortMinutes)
                        )
                        .accessibilityIdentifier("taskEdit.effort.value")

                    Spacer(minLength: 8)

                    effortAdjustmentButton(
                        systemName: "minus",
                        accessibilityLabel: "Decrease estimated effort",
                        identifier: "taskEdit.effort.decrement",
                        isDisabled: effortMinutes <= 15
                    ) {
                        effortMinutes = max(15, effortMinutes - 15)
                    }

                    effortAdjustmentButton(
                        systemName: "plus",
                        accessibilityLabel: "Increase estimated effort",
                        identifier: "taskEdit.effort.increment",
                        isDisabled: effortMinutes >= 720,
                        isPrimary: true
                    ) {
                        effortMinutes = min(720, effortMinutes + 15)
                    }
                }
                .frame(minHeight: 60)
            } else {
                Stepper(value: $effortMinutes, in: 15...720, step: 15) {
                    Text(CountdownFormatter.effortString(minutes: effortMinutes))
                        .font(AppFont.mono(15))
                        .foregroundStyle(Color.filumaText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
                .frame(minHeight: 60)
                .contentShape(Rectangle())
                .accessibilityLabel("Estimated effort")
                .accessibilityValue(CountdownFormatter.effortString(minutes: effortMinutes))
                .accessibilityIdentifier("taskEdit.effort")
            }
        }
    }

    private func effortAdjustmentButton(
        systemName: String,
        accessibilityLabel: String,
        identifier: String,
        isDisabled: Bool,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(selectionAnimation) {
                action()
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isPrimary ? Color.filumaControlInk : Color.filumaText)
                .frame(width: 48, height: 48)
                .background(isPrimary ? Color.brand500 : Color.filumaSurface3)
                .clipShape(
                    RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous)
                        .stroke(
                            isPrimary ? Color.brand300.opacity(0.55) : Color.filumaBorder,
                            lineWidth: 1
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    private func validationMessage(_ message: String, identifier: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(AppFont.body(12))
            .foregroundStyle(Color.filumaRed)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    // MARK: - Fixed action boundary

    private var saveActionBar: some View {
        VStack(spacing: 0) {
            Button(action: save) {
                Label("Save changes", systemImage: "checkmark")
                    .primaryButtonStyle(enabled: isValid)
            }
            .disabled(!isValid)
            .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(
                isValid
                    ? "Saves these details and rebuilds the schedule if the deadline or effort changed."
                    : "Resolve the validation message before saving."
            )
            .accessibilityIdentifier("taskEdit.save")
        }
        .padding(.horizontal, FilumaSpacing.screen)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: FilumaLayout.readableContentMaxWidth)
        .frame(maxWidth: .infinity)
        .background {
            Color.filumaBackground.opacity(0.98)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.filumaBorder)
                .frame(height: 1)
        }
    }

    // MARK: - Draft lifecycle

    private func loadTask() {
        guard !didLoadTask else { return }

        let loadedAt = Date()
        earliestDeadline = loadedAt
        title = task.title
        firstStep = task.firstStep ?? ""
        context = task.context
        deadline = task.deadline
        effortMinutes = task.effortMinutes

        // A past deadline cannot be picked. Triage begins from a fresh, doable
        // suggestion without mutating the task until the user chooses Save.
        if emphasizeDeadline && deadline <= loadedAt {
            deadline = Calendar.current.date(byAdding: .day, value: 1, to: loadedAt) ?? loadedAt
        }

        didLoadTask = true
        savedDraft = currentDraft
    }

    private func requestDismiss() {
        focusedField = nil
        if isDraftDirty {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    // MARK: - Save

    private func save() {
        let saveTime = Date()
        guard !trimmedTitle.isEmpty else { return }
        guard deadline > saveTime else {
            // A long-open editor can cross the selected minute. Refresh the
            // validation floor at the actual commit attempt so the visible
            // error and disabled Save state stay truthful.
            earliestDeadline = saveTime
            return
        }
        focusedField = nil

        let trimmedStep = firstStep.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: ScheduleResult?
        do {
            result = try PlanCoordinator.saveTaskEdits(
                task,
                update: TaskEditUpdate(
                    title: trimmedTitle,
                    firstStep: trimmedStep.isEmpty ? nil : trimmedStep,
                    taskContext: context,
                    deadline: deadline,
                    effortMinutes: effortMinutes
                ),
                context: modelContext,
                now: saveTime
            )
        } catch {
            // The coordinator restores both the held task and its durable plan.
            // Keep this draft onscreen so Save is a truthful, retryable action.
            scheduleWarningTitle = "Changes not saved"
            scheduleWarning = "Filuma couldn’t save these edits yet. Your task and schedule are still exactly as they were before you tapped Save. Keep editing or try Save again."
            warningAllowsDismissal = false
            showWarning = true
            return
        }

        // This is now the last submitted draft. A warning keeps the editor open
        // without making already-submitted values look unsaved.
        savedDraft = currentDraft

        switch result {
        case .partialFit(_, let unscheduledMinutes):
            // A retained locked row can begin before `now` or cross the
            // buffered deadline. The scheduler credits only its usable
            // overlap, even though the durable row retains its full duration.
            // Derive the truthful placed amount from the shortfall instead of
            // summing those full rows into impossible feedback.
            let scheduledMinutes = max(0, task.remainingMinutes - unscheduledMinutes)
            let scheduledText = CountdownFormatter.effortString(minutes: scheduledMinutes)
            let unscheduledText = CountdownFormatter.effortString(minutes: unscheduledMinutes)
            let deadlineText = deadline.formatted(date: .abbreviated, time: .shortened)
            scheduleWarningTitle = "Some work is still unscheduled"
            scheduleWarning = "Your changes are saved. Filuma placed \(scheduledText), but \(unscheduledText) could not fit before \(deadlineText). Keep Editing to extend the deadline or reduce the estimate. Done leaves that remaining time unscheduled."
            warningAllowsDismissal = true
            showWarning = true

        case .noSlots:
            let deadlineText = deadline.formatted(date: .abbreviated, time: .shortened)
            scheduleWarningTitle = "No open time was found"
            scheduleWarning = "Your changes are saved, but Filuma could not place any of the remaining work before \(deadlineText). Keep Editing to extend the deadline or reduce the estimate. Done leaves the remaining work unscheduled."
            warningAllowsDismissal = true
            showWarning = true

        case .success, nil:
            dismiss()
        }
    }
}
