# Filuma — App Store metadata draft

Prepared for iOS 1.3.0 (build 6) on 2026-08-23. Copy is intentionally
limited to behavior present in the submitted binary. Subscription language is
excluded until the StoreKit product and entitlement behavior are implemented.

## Listing

- **Name:** Filuma
- **Subtitle:** Plan tasks into real time
- **Primary category:** Productivity
- **Secondary category:** Utilities
- **Support URL:** https://sparkbiscuit.me/
- **Marketing URL:** https://sparkbiscuit.me/
- **Privacy Policy URL:** https://sparkbiscuit.me/privacy/
- **Copyright:** 2026 Nicholas Christoforakis
- **Version:** 1.3.0

### Promotional text

Turn tasks into realistic work blocks, see what is next, and keep moving with
gentle replanning, focused sessions, widgets, and optional calendar sync.

### Description

Filuma turns tasks into a plan you can actually use.

Add a task, its deadline, and a realistic effort estimate. Filuma breaks the
work into manageable blocks and places them into the free time you have before
the deadline—around sleep, meetings, classes, and the limits you set for your
day.

The Focus card keeps the next useful step in front of you. Start a full work
session or choose a ten-minute start when beginning is the hardest part. When
the day changes, Filuma gently replans the remaining work instead of leaving a
guilt-filled pile behind.

FEATURES

• Fast task, reminder, voice, and bulk capture
• Automatic time blocking around your real availability
• Clear day and week schedule views
• Focused work-session timer with Live Activities
• Optional Apple Calendar and Google Calendar connections
• Home Screen and Lock Screen widgets
• Weekly task repeats and blocked-time rules
• Calm overdue triage with reschedule, complete, or let-go choices
• A two-week Weave that reflects time spent and work completed
• Plain JSON export of your authored Filuma data

Filuma does not require an account. Your task data stays on your device unless
you choose an optional calendar connection or export.

### Keywords

task manager,planner,schedule,focus,time blocking,productivity,reminders,calendar,habits

## App Review information

Filuma is fully usable without an account. Google Calendar sync is optional.
Microphone and speech access are requested only when the reviewer chooses voice
dictation in the Capture sheet. Calendar permissions are optional. The Live
Activity pause/resume control changes only the active work-session timer.

The App Store version should have **Sign-in required** turned off.

## Privacy and rating position

- The current binary contains no analytics, advertising, tracking SDK, Filuma
  server, or Filuma account system.
- Most data is local-only. However, when the user enables Google Calendar
  export, task-derived work-block titles and times are written to the user's
  Google account on an ongoing basis. Apple's definition of collection includes
  data retained by a third-party partner beyond a real-time request, and its
  optional-disclosure exception does not apply to ongoing collection after one
  permission. Use the conservative App Store privacy disclosure documented in
  `app-store-privacy-disclosure.md`; do **not** publish “Data Not Collected.”
- The listing makes no medical or diagnostic claims. The age-rating
  questionnaire should be answered from the app's actual general-productivity
  content rather than targeting a predetermined rating.

## Release decisions still required

- Subscription versus free-at-launch; no subscription product or StoreKit
  entitlement currently exists.
- If subscription is chosen: gated value, monthly and annual product IDs and
  prices, trial, Family Sharing, existing-user treatment, Terms URL, and
  restore/manage-subscription behavior.
- Manual versus automatic App Store release after review.
- Distribution territories and Digital Services Act trader-status handling for
  the European Union.
- Review contact phone number and final permission to transmit the owner's
  contact details to Apple.
