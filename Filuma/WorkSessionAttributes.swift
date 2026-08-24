import Foundation
import ActivityKit
import AppIntents
import SwiftUI

// MARK: - Live Activity attributes (shared with the FilumaWidgets extension)

struct WorkSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Baseline for the system count-up; rebased when work resumes.
        var startedAt: Date
        var isPaused: Bool = false
        /// Static worked time shown while the session is paused.
        var pausedElapsedSeconds: Int = 0
    }

    var taskTitle: String
    /// Identifies the timer behind this activity so an inline intent can only
    /// mutate the session that rendered its button. Filuma permits one active
    /// timer, but the identifier also makes a delayed tap harmless after a
    /// rapid stop/restart.
    var sessionID: UUID
    /// Lets every non-control surface of the Live Activity deep-link back to
    /// the task's work-session screen.
    var taskID: UUID
    /// TaskContext.rawValue — kept as a string so the widget target doesn't
    /// need the SwiftData models.
    var contextName: String
    var effortMinutes: Int
    /// End of the scheduled block the session started inside, when there is
    /// one — the Live Activity counts down to it ("held flame" style).
    var blockEndsAt: Date? = nil
    /// The moment the progress ring reads empty. Inside a scheduled block
    /// this is the block's own start, so a session begun mid-block picks the
    /// ring up partway around instead of resetting to zero — and restarting
    /// a session in the same block resumes where the ring already was.
    /// Outside a block it's backdated by the time already spent on the task,
    /// so the budget ring carries earlier sessions too.
    var ringStartsAt: Date? = nil
    /// When the progress ring reads full: `ringStartsAt` plus the scheduled
    /// block's duration (or the full effort budget when the session floats
    /// outside any block).
    var ringEndsAt: Date? = nil
}

// MARK: - Shared work-session clock

/// Durable recovery journal shared by the app and its Live Activity intent.
/// The in-app timer still renders once per second, but it derives elapsed work
/// from this wall-clock state so actions performed while the app is suspended
/// are accounted for when it returns. Identifiers and ring dates stay model-
/// layer-free so the widget target can read the same value.
struct WorkSessionControlState: Codable, Hashable {
    let sessionID: UUID
    let startedAt: Date
    var accumulatedPausedSeconds: Int = 0
    var pauseBeganAt: Date?
    var taskID: UUID? = nil
    var scheduledBlockID: UUID? = nil
    var blockEndsAt: Date? = nil
    var ringStartsAt: Date? = nil
    var ringEndsAt: Date? = nil

    var isPaused: Bool { pauseBeganAt != nil }

    func elapsedWorkedSeconds(at date: Date) -> Int {
        let currentPause = pauseBeganAt.map {
            max(0, Int(date.timeIntervalSince($0)))
        } ?? 0
        return max(
            0,
            Int(date.timeIntervalSince(startedAt))
                - accumulatedPausedSeconds
                - currentPause
        )
    }

    mutating func setPaused(_ paused: Bool, at date: Date) {
        guard paused != isPaused else { return }
        if paused {
            pauseBeganAt = date
        } else if let pauseBeganAt {
            accumulatedPausedSeconds += max(0, Int(date.timeIntervalSince(pauseBeganAt)))
            self.pauseBeganAt = nil
        }
    }

    mutating func togglePause(at date: Date) {
        setPaused(!isPaused, at: date)
    }
}

/// One small App Group recovery journal bridges the system-run intent back to
/// the timer view and restores an interrupted foreground process. It contains
/// no task content or SwiftData models, which keeps intent execution fast and
/// avoids opening the store from the Lock Screen.
enum WorkSessionControlStore {
    private static let key = "activeWorkSessionControl.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedStore.appGroupId) ?? .standard
    }

    static func load(sessionID: UUID? = nil) -> WorkSessionControlState? {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(WorkSessionControlState.self, from: data),
              sessionID == nil || state.sessionID == sessionID else {
            return nil
        }
        return state
    }

    static func save(_ state: WorkSessionControlState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(
            name: .workSessionControlDidChange,
            object: state.sessionID
        )
    }

    static func clear(sessionID: UUID? = nil) {
        let active = load()
        if let sessionID, active?.sessionID != sessionID { return }
        defaults.removeObject(forKey: key)
        if let active {
            NotificationCenter.default.post(
                name: .workSessionControlDidChange,
                object: active.sessionID
            )
        }
    }
}

extension Notification.Name {
    static let workSessionControlDidChange = Notification.Name(
        "workSessionControlDidChange"
    )
}

/// Interactive Live Activity action. `LiveActivityIntent` makes the system run
/// this in Filuma's process without bringing the app to the foreground.
struct ToggleWorkSessionPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or Resume Work Session"
    static var description = IntentDescription(
        "Pause or resume the work timer shown in Filuma's Live Activity."
    )
    static var isDiscoverable = false

    @Parameter(title: "Session")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID),
              var control = WorkSessionControlStore.load(sessionID: id) else {
            return .result()
        }

        let now = Date()
        control.togglePause(at: now)
        WorkSessionControlStore.save(control)
        await WorkSessionActivityController.update(control, at: now)
        return .result()
    }
}

extension WorkSessionAttributes {
    /// Context accent color, resolved without the app's model layer.
    var contextColor: Color {
        switch contextName {
        case "School": return Color(red: 0x5A / 255, green: 0x78 / 255, blue: 0xE0 / 255)
        case "Work": return Color(red: 0xE0 / 255, green: 0xA0 / 255, blue: 0x20 / 255)
        case "Personal": return Color(red: 0x3F / 255, green: 0xA3 / 255, blue: 0x72 / 255)
        default: return Color(red: 0xC1 / 255, green: 0x57 / 255, blue: 0x1F / 255)
        }
    }
}

// MARK: - App-side controller

/// Starts and ends the Lock Screen / Dynamic Island activity that mirrors a
/// running work session. Only the app process may call this — extensions
/// cannot request activities.
@MainActor
enum WorkSessionActivityController {

    static func start(
        sessionID: UUID,
        taskID: UUID,
        taskTitle: String,
        contextName: String,
        effortMinutes: Int,
        startedAt: Date,
        blockEndsAt: Date? = nil,
        ringStartsAt: Date? = nil,
        ringEndsAt: Date? = nil
    ) {
        guard FilumaProAccess.isPro,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = WorkSessionAttributes(
            taskTitle: taskTitle,
            sessionID: sessionID,
            taskID: taskID,
            contextName: contextName,
            effortMinutes: effortMinutes,
            blockEndsAt: blockEndsAt,
            ringStartsAt: ringStartsAt,
            ringEndsAt: ringEndsAt
        )
        // End-then-request inside one Task so a rapid restart can't leave two
        // activities alive.
        Task {
            for activity in Activity<WorkSessionAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            // Stop may have run while the awaits above were ending an older
            // activity. Only request this one if its session is still the
            // active App Group control; otherwise a rapid start/stop could
            // resurrect an orphan after endAll() had already taken its snapshot.
            guard let latestControl = WorkSessionControlStore.load(sessionID: sessionID) else {
                return
            }
            let content = ActivityContent(
                state: contentState(for: latestControl, at: Date()),
                staleDate: nil
            )
            _ = try? Activity.request(attributes: attributes, content: content)
        }
    }

    private static func contentState(
        for control: WorkSessionControlState,
        at date: Date
    ) -> WorkSessionAttributes.ContentState {
        let elapsed = control.elapsedWorkedSeconds(at: date)
        return WorkSessionAttributes.ContentState(
            startedAt: date.addingTimeInterval(-Double(elapsed)),
            isPaused: control.isPaused,
            pausedElapsedSeconds: elapsed
        )
    }

    /// Ends only the timer identity that completed its durable attendance
    /// boundary. A stale or idle WorkSessionView must not clear a newer task's
    /// recovery journal or dismiss its Live Activity.
    static func end(sessionID: UUID) {
        WorkSessionControlStore.clear(sessionID: sessionID)
        let activities = Activity<WorkSessionAttributes>.activities.filter {
            $0.attributes.sessionID == sessionID
        }
        guard !activities.isEmpty else { return }
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    static func isActive(sessionID: UUID) -> Bool {
        Activity<WorkSessionAttributes>.activities.contains {
            $0.attributes.sessionID == sessionID
        }
    }

    static func update(_ control: WorkSessionControlState, at date: Date = Date()) async {
        guard let activity = Activity<WorkSessionAttributes>.activities.first(where: {
            $0.attributes.sessionID == control.sessionID
        }) else { return }

        let elapsed = control.elapsedWorkedSeconds(at: date)
        var state = activity.content.state
        state.isPaused = control.isPaused
        state.pausedElapsedSeconds = elapsed
        if !control.isPaused {
            state.startedAt = date.addingTimeInterval(-Double(elapsed))
        }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    static func updateSoon(_ control: WorkSessionControlState, at date: Date = Date()) {
        Task {
            await update(control, at: date)
        }
    }

    /// Ends every Filuma activity and clears its journal after a durable stop or
    /// when foreground recovery rejects abandoned state.
    static func endAll() {
        WorkSessionControlStore.clear()
        let activities = Activity<WorkSessionAttributes>.activities
        guard !activities.isEmpty else { return }
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
