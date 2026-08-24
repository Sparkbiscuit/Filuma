import SwiftUI

// MARK: - Task completion ritual

/// Completion is a receipt first and a ritual second. The view never reaches
/// back into SwiftData, so it cannot celebrate a task that failed to persist or
/// retain a model that just moved out of an active query.
struct TaskCompletionView: View {
    let receipt: TaskCompletionReceipt
    var onDone: () -> Void
    /// Return an error message to keep the ritual open and explain why the
    /// durable restore did not happen. `nil` means the parent restored and is
    /// dismissing this cover.
    var onUndo: () -> String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var headingFocused: Bool

    @State private var threadProgress: CGFloat = 0
    @State private var checkIsVisible = false
    @State private var sealScale: CGFloat = 0.94
    @State private var successFeedback = 0
    @State private var didResolve = false
    @State private var restoreFailureMessage: String?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 24 : 44)

                    ThreadTieSeal(
                        color: receipt.context.color,
                        progress: threadProgress,
                        checkIsVisible: checkIsVisible
                    )
                    .frame(
                        width: dynamicTypeSize.isAccessibilitySize ? 116 : 148,
                        height: dynamicTypeSize.isAccessibilitySize ? 116 : 148
                    )
                    .scaleEffect(sealScale)
                    .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 20 : 28)
                    .accessibilityHidden(true)

                    Text("Thread tied")
                        .font(AppFont.settingsSectionHeader(11))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(receipt.context.displayColor)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("completion.eyebrow")

                    Text("Task complete")
                        .font(AppFont.title(28))
                        .foregroundStyle(Color.filumaText)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("completion.title")
                        .accessibilityFocused($headingFocused)
                        .padding(.bottom, 8)

                    Text(receipt.title)
                        .font(AppFont.bodySemibold(16))
                        .foregroundStyle(Color.filumaSubtle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                        .padding(.bottom, 28)

                    VStack(spacing: 10) {
                        if receipt.timeSpentMinutes > 0 {
                            statRow(
                                icon: "stopwatch",
                                label: "Time worked",
                                value: CountdownFormatter.effortString(
                                    minutes: receipt.timeSpentMinutes
                                )
                            )
                        }
                        statRow(
                            icon: "calendar.badge.checkmark",
                            label: "Finished",
                            value: receipt.deadlineSummary
                        )
                    }
                    .frame(maxWidth: 420)
                    .padding(.bottom, 30)

                    Spacer(minLength: 28)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background {
            HearthScreenBackground(topGlow: 0.22, bottomGlow: 0.34, embers: 0)
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .sensoryFeedback(.success, trigger: successFeedback)
        .task(id: receipt.id) {
            await playRitual()
        }
        .alert(
            "Task still completed",
            isPresented: Binding(
                get: { restoreFailureMessage != nil },
                set: { if !$0 { restoreFailureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                restoreFailureMessage = nil
            }
        } message: {
            Text(restoreFailureMessage ?? "")
        }
    }

    private var actionBar: some View {
        VStack(spacing: 6) {
            Button {
                resolve(onDone)
            } label: {
                Text("Done")
                    .primaryButtonStyle()
            }
            .hearthPressStyle(scale: 0.98, pressedOpacity: 0.9)
            .accessibilityIdentifier("completion.done")

            Button {
                restore()
            } label: {
                Text("Restore task")
                    .font(AppFont.heading(16))
                    .foregroundStyle(Color.brand300)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        Color.filumaSurface,
                        in: RoundedRectangle(
                            cornerRadius: FilumaRadius.button,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: FilumaRadius.button,
                            style: .continuous
                        )
                        .stroke(Color.filumaBorder, lineWidth: 1)
                    }
            }
            .hearthPressStyle(scale: 0.98, pressedOpacity: 0.88)
            .accessibilityHint("Returns the remaining work to your current plan")
            .accessibilityIdentifier("completion.restore")
        }
        .frame(maxWidth: 476)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color.filumaBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.filumaBorder)
                .frame(height: 1)
        }
    }

    private func resolve(_ action: () -> Void) {
        guard !didResolve else { return }
        didResolve = true
        action()
    }

    private func restore() {
        guard !didResolve else { return }
        didResolve = true
        if let failure = onUndo() {
            didResolve = false
            restoreFailureMessage = failure
        }
    }

    @ViewBuilder
    private func statRow(icon: String, label: String, value: String) -> some View {
        let iconView = Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(receipt.context.displayColor)
            .frame(width: 22)
            .accessibilityHidden(true)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        iconView
                        Text(label)
                            .font(AppFont.body(14))
                            .foregroundStyle(Color.filumaSubtle)
                    }
                    Text(value)
                        .font(AppFont.mono(13))
                        .foregroundStyle(Color.filumaText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    iconView
                    Text(label)
                        .font(AppFont.body(14))
                        .foregroundStyle(Color.filumaSubtle)
                    Spacer()
                    Text(value)
                        .font(AppFont.mono(13))
                        .foregroundStyle(Color.filumaText)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }

    @MainActor
    private func playRitual() async {
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        headingFocused = true

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                sealScale = 1
                threadProgress = 1
                checkIsVisible = true
            }
            successFeedback &+= 1
            return
        }

        withAnimation(HearthMotion.reveal) {
            sealScale = 1
            threadProgress = 1
        }
        try? await Task.sleep(for: .milliseconds(420))
        guard !Task.isCancelled else { return }

        withAnimation(HearthMotion.selection) {
            checkIsVisible = true
        }
        successFeedback &+= 1
    }
}

// MARK: - Woven seal

/// A deterministic filament closes around the checkmark, then ties once at
/// the bottom. Unlike confetti, it has a stable silhouette and a clear resting
/// state that can become recognizably Filuma's.
private struct ThreadTieSeal: View {
    let color: Color
    let progress: CGFloat
    let checkIsVisible: Bool

    private var ringProgress: CGFloat {
        min(1, progress / 0.74)
    }

    private var knotProgress: CGFloat {
        min(1, max(0, (progress - 0.68) / 0.32))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.filumaSurface)
                .overlay(Circle().stroke(Color.filumaBorder, lineWidth: 1))
                .padding(17)

            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(
                    LinearGradient(
                        colors: [color.opacity(0.45), color, color.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(10)

            ThreadKnotShape()
                .trim(from: 0, to: knotProgress)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 72, height: 38)
                .offset(y: 46)

            CompletionCheckmarkShape()
                .trim(from: 0, to: checkIsVisible ? 1 : 0)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 43, height: 32)
        }
        .hearthGlow(color, radius: 24, opacity: 0.46)
    }
}

private struct CompletionCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 2))
        return path
    }
}

/// The small crossing loop at the base turns a completed ring into a tied
/// thread rather than another generic success badge.
private struct ThreadKnotShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
        path.addCurve(
            to: CGPoint(x: rect.minX + 5, y: rect.midY),
            control1: CGPoint(x: rect.midX - 8, y: rect.minY + 7),
            control2: CGPoint(x: rect.minX + 18, y: rect.minY + 2)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY - 3),
            control1: CGPoint(x: rect.minX + 3, y: rect.maxY - 4),
            control2: CGPoint(x: rect.midX - 13, y: rect.maxY - 5)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - 5, y: rect.midY),
            control1: CGPoint(x: rect.midX + 13, y: rect.maxY - 5),
            control2: CGPoint(x: rect.maxX - 3, y: rect.maxY - 4)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY + 2),
            control1: CGPoint(x: rect.maxX - 18, y: rect.minY + 2),
            control2: CGPoint(x: rect.midX + 8, y: rect.minY + 7)
        )
        return path
    }
}
