import AppIntents
import Foundation
import SwiftData

// MARK: - Capture from anywhere

/// Capture a task without opening the app: Siri, Shortcuts, Spotlight, the
/// Action button. Capture friction is the core ADHD failure mode — the thought
/// "I should write that down" has a half-life of seconds, so the path from
/// thought to scheduled plan has to survive a pocket.
struct CaptureTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture a Task"
    static var description = IntentDescription(
        "Add a task to Filuma. It gets an hour's estimate, a deadline, and real time blocks on your schedule — refine it in the app later if you want.",
        categoryName: "Capture"
    )

    @Parameter(title: "Task", requestValueDialog: "What needs to get done?")
    var taskTitle: String

    @Parameter(title: "Due in (days)", default: 3, inclusiveRange: (1, 60))
    var daysUntilDue: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Nothing captured — the task needs a name.")
        }

        let container = try SharedStore.makeContainer()
        let context = ModelContext(container)
        let now = Date()
        let deadline = Calendar.current.date(
            byAdding: .day,
            value: daysUntilDue,
            to: now
        ) ?? now

        let receipt: TaskCaptureReceipt
        do {
            let prepared = try CaptureCoordinator.prepareTask(
                title: trimmed,
                firstStep: "",
                taskContext: .personal,
                deadline: deadline,
                effortMinutes: 60,
                now: now,
                context: context
            )
            receipt = try CaptureCoordinator.commit(
                prepared,
                context: context,
                publish: { context, _ in
                    PlanCoordinator.publishChange(
                        context: context,
                        interactive: false
                    )
                }
            )
        } catch CaptureCoordinatorError.missingSettings {
            return .result(
                dialog: "Open Filuma once to finish setup, then I can place this task in your plan."
            )
        } catch {
            return .result(
                dialog: "I couldn't save that task yet. Nothing was added — please try again."
            )
        }

        if let firstBlockStart = receipt.firstBlockStart {
            if receipt.unscheduledMinutes > 0 {
                let remaining = CountdownFormatter.effortString(
                    minutes: receipt.unscheduledMinutes
                )
                return .result(
                    dialog: "Captured. First block \(Self.relative(firstBlockStart)); \(remaining) still needs time."
                )
            }
            return .result(
                dialog: "Captured. First block \(Self.relative(firstBlockStart))."
            )
        }
        return .result(
            dialog: "Captured, but nothing fits before the deadline — open Filuma to make room."
        )
    }

    private static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = TimeFormatter.clock.string(from: date)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return "\(formatter.string(from: date)) at \(time)"
    }
}

// MARK: - App Shortcuts

/// Zero-setup phrases: these work with Siri and appear in the Shortcuts app
/// (and on the Action button) without the user configuring anything.
struct FilumaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureTaskIntent(),
            phrases: [
                "Capture a task in \(.applicationName)",
                "Add a task to \(.applicationName)",
                "Capture in \(.applicationName)"
            ],
            shortTitle: "Capture Task",
            systemImageName: "plus.circle.fill"
        )
    }
}
