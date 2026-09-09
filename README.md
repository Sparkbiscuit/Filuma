# Filuma

Filuma is a time-aware task manager built around one idea: big tasks don't get done in
one heroic sitting. You give Filuma a task, a deadline, and an effort estimate; it
splits the work into manageable blocks and schedules them into the real free time
you have before the deadline — around your sleep, your classes and meetings, and a
daily focus limit if you set one.

## Features

- **Capture in seconds** — type or dictate a task, pick a context (School / Work /
  Personal), a deadline, and an effort estimate. Repeat and delayed-start controls
  stay tucked under “More scheduling options,” and bulk entry handles a whole syllabus.
- **Right Now card** — the top of the Tasks tab always answers "what should I be
  doing this minute?": the running block (with elapsed/remaining) or the next one
  up, with a single big Start button. Opening the app never requires a decision.
- **First step** — optionally capture the very first physical action ("open the doc,
  paste the data table"). It shows in the Right Now card, the block-start
  notification, and the session timer, then clears itself once you've started.
- **Overdue triage** — tasks that slip past their deadline move into a "Needs a
  decision" queue with three kind exits: new deadline, done actually, or let it go.
  No guilt pile.
- **Estimate reality-check** — completed tasks keep their planned-vs-actual record,
  and capture compares your guess against your recent history in that context:
  "Your last 5 School tasks ran about 1.6× over. Plan for 2h 30m instead?" with a
  one-tap accept. Needs at least 3 tracked completions; suggestions cap at 2×.
- **Pace dots** — every task carries a quiet pressure reading: remaining effort
  versus the free time left before its deadline. Green under 50%, amber
  to 80%, red beyond — plus one honest sentence in the stats bar about the most
  pressured task, days before anything turns into a crisis.
- **Morning preview & evening wrap-up** — a notification 30 minutes after wake
  time pre-loads the day's shape ("First block: 9:00 Lab report. 3 blocks total,
  done by 4:30"), and a configurable evening one closes the day and names
  tomorrow's opener. Both optional, in Settings → Nudges.
- **Start streak** — a flame in the header counting days you *started* a session,
  not days you finished things, with two free mend days a week so one bad day
  can't torch the thread.
- **Widget start** — tapping a block on the Up Next widget deep-links straight
  into that task's work session timer; one tap from Home Screen to running timer.
- **Session immersion** — the screen stays awake during a work session, a gentle
  haptic warns ten minutes before the block ends, and another marks the boundary:
  stopping on time is the win, not the interruption.
- **Weekly repeats** — capture a problem set once with "Weekly until…" and fresh
  copies appear a rolling two weeks ahead, each scheduled around that week's
  reality. Missed weeks are skipped silently — recurrence never manufactures
  overdue guilt. Stop any recurrence from its task's context menu.
- **The Weave** — a reflection tab that renders your last two weeks as a woven
  tapestry: one column per day, threads colored by context and sized by time
  actually worked, rest days shown as bare warp (they hold the cloth together).
  With week totals, start counts, your streak, an estimate-heat reading, and
  the week's finished tasks.
- **Just 10 minutes** — a micro-start next to the session button: commit to ten
  minutes, watch them count down, and get released at zero. Keep going or stop —
  both count.
- **Capture from anywhere** — "Add a task to Filuma" via Siri, Shortcuts,
  Spotlight, or the Action button. The task lands fully scheduled without the
  app ever opening, and Siri tells you when its first block is.
- **Can't right now** — one tap under the Right Now card pushes the plan 30
  minutes, an hour, or to tomorrow morning. The whole task replans from the new
  start, so nothing quietly rots and the deadline math stays honest.
- **Today widget** — a Lock Screen ring of blocks done vs planned (and your
  streak on quiet days), plus a Home Screen card with today's count, progress,
  and what's next. Tapping jumps straight into the next block's timer.
- **Data export** — Settings → Export my data writes your tasks, scheduled
  blocks, work history, reminders, recurring and blocked time, planning
  preferences, and integration choices to plain, pretty-printed JSON. OAuth
  credentials, sync cursors, and imported calendar-event copies stay out of
  the portable file. Your authored data is yours.
- **Auto-scheduling** — work is chunked into blocks (configurable min/max size) and
  spread across the available days before a preferred Safe Zone, with the actual
  deadline available when needed. Fragmented
  calendars and daily focus limits are reflected in both placement and pace.
- **Catch-up replanning** — blocks you miss are automatically replanned, and the
  whole schedule rebalances earliest-deadline-first, so an urgent task claims
  near slots from work that can wait.
- **Reminders** — one-off reminders with local notifications, alongside the
  scheduled tasks. They appear in the Up Next widget with your work blocks, and
  completed ones land in the Completed section where they can be restored.
- **Work sessions** — a focused timer per task with self-reported progress; finish at
  100% and the task completes with a small celebration. A Live Activity mirrors the
  running timer on the Lock Screen and in the Dynamic Island.
- **Honest progress** — checking off a time block logs attendance; timed sessions are
  linked to their block so the same work is never counted twice. How much of the task
  is actually done is always yours to say, and skipped progress keeps the remaining
  effort fully scheduled.
- **Schedule views** — a day timeline and a compact week grid, including recurring
  blocked times the scheduler works around. Long-press an upcoming block to lock it
  in place through automatic replans, or allow Filuma to move it again later.
- **Apple Calendar sync** — optional one-way export of your work blocks into a
  dedicated "Filuma" calendar, and optional import that treats events from the
  calendars you choose as busy time the scheduler works around.
- **Widgets** — an Up Next widget for the Home Screen and Lock Screen, plus a
  Live Activity while a work session timer is running.

- **Safe Zone** — a preferred early finish, globally configurable with optional
  task overrides. New users start with one day; existing saved buffers stay intact.
  A task preview shows its actual spread, sessions, and whether the buffer is used.
- **Room to breathe** — a landscape-backed Today, native Dynamic Type, an ember
  focus ring, and context threads woven from recorded effort in both appearances.

## Project

SwiftUI + SwiftData, iOS 18.0+. Open `Filuma.xcodeproj` in Xcode and run the `Filuma`
scheme. The visual system (colors, type, spacing, per-screen specs) lives in
`design-handoff/`.

## Tests

Unit tests live in `FilumaTests` (scheduler geometry and focus limits, plan
reconciliation, work-log accounting, export compatibility, estimate advice,
streaks, digests, and recurrence). `FilumaUITests` uses an isolated in-memory
store to cover first launch, core tab navigation, and the capture flow without
touching personal data. The shared `Filuma` scheme includes both test bundles, so
**Product → Test** (⌘U) runs everything; they also appear in Xcode's Test
navigator (⌘6).
