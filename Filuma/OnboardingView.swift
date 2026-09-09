import SwiftUI
import SwiftData
import UIKit

/// Filuma's opening chapter: one honest product promise, followed by two
/// optional rhythm-tuning screens. The welcome reuses the same first-thread
/// journey shown on an empty Tasks screen so first launch feels continuous.
struct OnboardingView: View {
    let settings: UserSettings

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var step = 0
    @State private var movingForward = true
    @State private var journeyRevealed = false
    @State private var issue: OnboardingIssue?
    @AccessibilityFocusState private var headingFocused: Bool

    private let stepCount = 3

    private struct OnboardingIssue: Identifiable {
        let id = UUID()
        let message: String
    }

    var body: some View {
        ZStack {
            HearthScreenBackground(
                topGlow: 0.22,
                bottomGlow: 0.28,
                embers: 8,
                emberIntensity: 0.65
            )

            GeometryReader { geometry in
                ScrollView {
                    Group {
                        switch step {
                        case 0: welcomeStep
                        case 1: dayStep
                        default: blocksStep
                        }
                    }
                    .id(step)
                    .transition(stepTransition)
                    .frame(maxWidth: FilumaLayout.onboardingContentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(0, geometry.size.height - 32))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .interactiveDismissDisabled()
        .onAppear {
            revealJourney()
            focusHeading()
        }
        .onChange(of: step) { _, _ in
            focusHeading()
        }
        .alert(item: $issue) { issue in
            Alert(
                title: Text("Your setup is still here"),
                message: Text(issue.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var stepAnimation: Animation? {
        reduceMotion ? HearthMotion.reduced : HearthMotion.selection
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertion: Edge = movingForward ? .trailing : .leading
        let removal: Edge = movingForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertion).combined(with: .opacity),
            removal: .move(edge: removal).combined(with: .opacity)
        )
    }

    // MARK: - Welcome

    @ViewBuilder
    private var welcomeStep: some View {
        if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .center, spacing: 26) {
                journey
                    .scaleEffect(0.84)
                    .frame(width: 268)
                welcomeCopy
                    .frame(maxWidth: 310, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                if !dynamicTypeSize.isAccessibilitySize {
                    journey
                        .frame(maxWidth: .infinity)
                }
                welcomeCopy
            }
            .frame(maxWidth: 520)
        }
    }

    private var journey: some View {
        HearthThreadJourney(
            isRevealed: journeyRevealed,
            reduceMotion: reduceMotion
        )
    }

    private var welcomeCopy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("THE FIRST THREAD")
                .font(AppFont.caption(11))
                .foregroundStyle(Color.brand300)
                .kerning(1.8)

            Text("You add the task. Filuma finds the time.")
                .font(AppFont.title(28))
                .foregroundStyle(Color.filumaText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
                .accessibilityIdentifier("onboarding.welcome.title")

            Text("Give it a deadline and a rough effort estimate. Filuma shapes the work into manageable blocks and replans when life moves.")
                .font(AppFont.body(15))
                .foregroundStyle(Color.filumaSubtle)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            defaultsSummary
        }
    }

    private var defaultsSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryRow(icon: "sunrise.fill", text: "8 AM–11 PM planning window")
            summaryRow(icon: "rectangle.split.3x1", text: "30–90 minute work blocks")
            summaryRow(icon: "flag.checkered", text: "1-day Safe Zone")
        }
        .font(AppFont.bodySemibold(13))
        .foregroundStyle(Color.filumaText)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recommended defaults: 8 AM to 11 PM, 30 to 90 minute blocks, 1-day Safe Zone")
    }

    private func summaryRow(icon: String, text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Color.brand300)
        }
    }

    // MARK: - Shape your day

    private var dayStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            setupHeading(
                eyebrow: "YOUR RHYTHM",
                title: "Shape your day",
                message: "Filuma only schedules work inside these hours. A bedtime after midnight is fine.",
                identifier: "onboarding.day.title"
            )

            VStack(spacing: 0) {
                settingRow(label: "Wake time", icon: "sunrise.fill", iconColor: .workColor) {
                    DatePicker("", selection: timeBinding(
                        hour: { settings.wakeHour }, setHour: { settings.wakeHour = $0 },
                        minute: { settings.wakeMinute }, setMinute: { settings.wakeMinute = $0 }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Wake time")
                    .accessibilityIdentifier("onboarding.wakeTime")
                }

                Divider().overlay(Color.filumaBorder).padding(.leading, 16)

                settingRow(label: "Sleep time", icon: "moon.fill", iconColor: .schoolColor) {
                    DatePicker("", selection: timeBinding(
                        hour: { settings.sleepHour }, setHour: { settings.sleepHour = $0 },
                        minute: { settings.sleepMinute }, setMinute: { settings.sleepMinute = $0 }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Sleep time")
                    .accessibilityIdentifier("onboarding.sleepTime")
                }
            }
            .background(Color.filumaSurface)
            .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                    .stroke(Color.filumaBorder, lineWidth: 1)
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: - Work rhythm

    private var blocksStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            setupHeading(
                eyebrow: "HELD, NOT PACKED",
                title: "Choose your work rhythm",
                message: "Set the smallest and largest block Filuma can use, plus how early it should aim to finish.",
                identifier: "onboarding.blocks.title"
            )

            VStack(spacing: 0) {
                stepperRow(
                    label: "Minimum block",
                    identifier: "onboarding.minimumBlock",
                    value: { settings.minBlockMinutes },
                    set: { settings.minBlockMinutes = $0 },
                    range: 15...60,
                    step: 15
                )
                Divider().overlay(Color.filumaBorder).padding(.leading, 16)
                stepperRow(
                    label: "Maximum block",
                    identifier: "onboarding.maximumBlock",
                    value: { settings.maxBlockMinutes },
                    set: { settings.maxBlockMinutes = $0 },
                    range: 60...180,
                    step: 30
                )
                Divider().overlay(Color.filumaBorder).padding(.leading, 16)
                stepperRow(
                    label: "Safe Zone",
                    identifier: "onboarding.deadlineBuffer",
                    value: { settings.deadlineBufferMinutes },
                    set: { settings.deadlineBufferMinutes = $0 },
                    range: 0...43200,
                    step: 360
                )
            }
            .background(Color.filumaSurface)
            .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                    .stroke(Color.filumaBorder, lineWidth: 1)
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.brand300)
                    .accessibilityHidden(true)
                Text("Miss a block? Filuma quietly replans the remaining work. You can change every setting later.")
                    .font(AppFont.body(13))
                    .foregroundStyle(Color.filumaSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Color.brand500.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                    .stroke(Color.brand500.opacity(0.18), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: 520)
    }

    private func setupHeading(
        eyebrow: String,
        title: String,
        message: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow)
                .font(AppFont.caption(11))
                .foregroundStyle(Color.brand300)
                .kerning(1.8)
            Text(title)
                .font(AppFont.title(27))
                .foregroundStyle(Color.filumaText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
                .accessibilityIdentifier(identifier)
            Text(message)
                .font(AppFont.body(15))
                .foregroundStyle(Color.filumaSubtle)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Fixed actions

    private var actionBar: some View {
        VStack(spacing: 10) {
            progressIndicator
                .padding(.bottom, 4)

            if step == 0 {
                Button(action: useRecommendedDefaults) {
                    Text("Start with defaults")
                        .primaryButtonStyle()
                }
                .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
                .accessibilityIdentifier("onboarding.startWithDefaults")

                secondaryButton("Tune my schedule", identifier: "onboarding.customize") {
                    advance()
                }
            } else {
                Button {
                    step == stepCount - 1 ? finishCustomSetup() : advance()
                } label: {
                    Text(step == stepCount - 1 ? "Use these settings" : "Continue")
                        .primaryButtonStyle()
                }
                .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
                .accessibilityIdentifier(
                    step == stepCount - 1 ? "onboarding.finish" : "onboarding.continue"
                )

                secondaryButton("Back", identifier: "onboarding.back", action: goBack)
            }
        }
        .padding(.horizontal, 24)
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

    private func secondaryButton(
        _ title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.heading(15))
                .foregroundStyle(Color.filumaSubtle)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .hearthPressStyle(scale: 0.98, pressedOpacity: 0.76)
        .accessibilityIdentifier(identifier)
    }

    private var progressIndicator: some View {
        HStack(spacing: 7) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.brand500 : Color.filumaSurface3)
                    .frame(width: index == step ? 22 : 7, height: 6)
            }
        }
        .animation(reduceMotion ? nil : HearthMotion.selection, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(stepCount)")
        .accessibilityIdentifier("onboarding.progress")
    }

    // MARK: - Actions

    private func advance() {
        guard step < stepCount - 1 else { return }
        movingForward = true
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(stepAnimation) {
            step += 1
        }
    }

    private func goBack() {
        guard step > 0 else { return }
        movingForward = false
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(stepAnimation) {
            step -= 1
        }
    }

    private func useRecommendedDefaults() {
        settings.applyRecommendedSchedulingDefaults()
        commitOnboarding()
    }

    private func finishCustomSetup() {
        commitOnboarding()
    }

    private func commitOnboarding() {
        issue = nil
        do {
            try OnboardingCompletionCoordinator.commit(
                settings,
                in: modelContext
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            issue = OnboardingIssue(
                message: "Filuma couldn’t save the final handoff yet. Your choices are still on screen—please try again."
            )
        }
    }

    private func revealJourney() {
        guard !journeyRevealed else { return }
        if reduceMotion {
            journeyRevealed = true
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                journeyRevealed = true
            }
        }
    }

    private func focusHeading() {
        headingFocused = false
        Task { @MainActor in
            await Task.yield()
            headingFocused = true
        }
    }

    // MARK: - Controls

    private func settingRow<Content: View>(
        label: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    Label(label, systemImage: icon)
                        .font(AppFont.bodySemibold(15))
                        .foregroundStyle(iconColor)
                    content()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack {
                    Label(label, systemImage: icon)
                        .font(AppFont.bodySemibold(15))
                        .foregroundStyle(iconColor)
                    Spacer(minLength: 12)
                    content()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }

    private func stepperRow(
        label: String,
        identifier: String,
        value: @escaping () -> Int,
        set: @escaping (Int) -> Void,
        range: ClosedRange<Int>,
        step stride: Int
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Text(label)
                        .font(AppFont.bodySemibold(15))
                        .foregroundStyle(Color.filumaText)

                    HStack(spacing: 12) {
                        Text(CountdownFormatter.effortString(minutes: value()))
                            .font(AppFont.mono(14))
                            .foregroundStyle(Color.filumaSubtle)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        onboardingAdjustmentButton(
                            systemName: "minus",
                            accessibilityLabel: "Decrease \(label.lowercased())",
                            identifier: "\(identifier).decrement",
                            isDisabled: value() <= range.lowerBound
                        ) {
                            set(max(range.lowerBound, value() - stride))
                        }

                        onboardingAdjustmentButton(
                            systemName: "plus",
                            accessibilityLabel: "Increase \(label.lowercased())",
                            identifier: "\(identifier).increment",
                            isDisabled: value() >= range.upperBound,
                            isPrimary: true
                        ) {
                            set(min(range.upperBound, value() + stride))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 112)
            } else {
                Stepper(value: Binding(get: value, set: set), in: range, step: stride) {
                    HStack {
                        Text(label)
                            .font(AppFont.body(15))
                            .foregroundStyle(Color.filumaText)
                        Spacer(minLength: 8)
                        Text(CountdownFormatter.effortString(minutes: value()))
                            .font(AppFont.mono(14))
                            .foregroundStyle(Color.filumaSubtle)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 60)
                .contentShape(Rectangle())
                .accessibilityIdentifier(identifier)
            }
        }
    }

    private func onboardingAdjustmentButton(
        systemName: String,
        accessibilityLabel: String,
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
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isPrimary ? Color.filumaControlInk : Color.filumaText)
                .frame(width: 48, height: 48)
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

    private func timeBinding(
        hour: @escaping () -> Int,
        setHour: @escaping (Int) -> Void,
        minute: @escaping () -> Int,
        setMinute: @escaping (Int) -> Void
    ) -> Binding<Date> {
        Binding<Date>(
            get: {
                var components = DateComponents()
                components.hour = hour()
                components.minute = minute()
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                setHour(components.hour ?? 8)
                setMinute(components.minute ?? 0)
            }
        )
    }
}

/// Makes the onboarding handoff a deliberate two-boundary write: the user's
/// rhythm is durable before the completion flag can reveal the app shell. A
/// failed first write restores the draft to the live form for retry; a failed
/// final write leaves the already-saved rhythm intact and onboarding active.
@MainActor
enum OnboardingCompletionCoordinator {
    private struct SchedulingDraft {
        let wakeHour: Int
        let wakeMinute: Int
        let sleepHour: Int
        let sleepMinute: Int
        let minBlockMinutes: Int
        let maxBlockMinutes: Int
        let deadlineBufferMinutes: Int
        let startBufferMinutes: Int

        init(_ settings: UserSettings) {
            wakeHour = settings.wakeHour
            wakeMinute = settings.wakeMinute
            sleepHour = settings.sleepHour
            sleepMinute = settings.sleepMinute
            minBlockMinutes = settings.minBlockMinutes
            maxBlockMinutes = settings.maxBlockMinutes
            deadlineBufferMinutes = settings.deadlineBufferMinutes
            startBufferMinutes = settings.startBufferMinutes
        }

        func apply(to settings: UserSettings) {
            settings.wakeHour = wakeHour
            settings.wakeMinute = wakeMinute
            settings.sleepHour = sleepHour
            settings.sleepMinute = sleepMinute
            settings.minBlockMinutes = minBlockMinutes
            settings.maxBlockMinutes = maxBlockMinutes
            settings.deadlineBufferMinutes = deadlineBufferMinutes
            settings.startBufferMinutes = startBufferMinutes
        }
    }

    static func commit(
        _ settings: UserSettings,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let draft = SchedulingDraft(settings)

        do {
            try save(context)
        } catch {
            context.rollback()
            draft.apply(to: settings)
            settings.hasCompletedOnboarding = false
            context.processPendingChanges()
            throw error
        }

        settings.hasCompletedOnboarding = true
        do {
            try save(context)
        } catch {
            context.rollback()
            settings.hasCompletedOnboarding = false
            context.processPendingChanges()
            throw error
        }
    }
}
