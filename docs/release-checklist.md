> Historical 1.3.0 material. For the current update, see [1.4.0 submission guide](1.4.0-update-submission.md).

# Filuma â TestFlight / App Store submission checklist

State as of 2026-08-23 (v1.3.0, build 6). Checked items below were verified
against frozen compiled-input fingerprint
`62608e6481ef259eacb3496a0968e1e530eb4e6bfd4395f0b024ff5163398b3f`.
Unchecked items require a human, App Store Connect / Google Cloud access,
distribution signing, or a physical-device pass.

## Verified in the current repository

- [x] App and widget `Info.plist`, entitlements, privacy manifests, and the
      Xcode project pass `plutil -lint`.
- [x] The app and widget privacy manifests are included in their respective
      Resources build phases.
- [x] App and widget entitlements use the same App Group as `SharedStore`:
      `group.com.christoforakis.Filuma`.
- [x] The app targets both iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`),
      with portrait and both landscape orientations enabled for iPad.
- [x] The work-session Live Activity now has an interactive pause/resume
      `LiveActivityIntent`, session-scoped App Group state, 44-point controls,
      accessibility labels, and task deep links. This still needs the physical
      device verification listed below.
- [x] Custom Settings switches expose native labeled switch semantics and use
      at least 44-point interaction targets without replacing the Hearth style.
- [x] Tasks, Settings, and Weave use centered readable-width content on iPad;
      the custom bottom bar is capped while Schedule retains the wider canvas.
- [x] Onboarding is a three-stage welcome â day â block setup with a one-tap
      recommended-defaults path. Its actions remain fixed and reachable on
      short windows, Accessibility 5, and iPad landscape, and it honors Reduce
      Motion.
- [x] The frozen simulator bundle passed **210/210 unit tests** on 2026-08-23:
      178 `FilumaTests` and 32 `GoogleCalendarTests`, with no failures or skips.
- [x] The once-only full iPhone UI class passed all **26/26 applicable phone
      journeys**; its three iPad-only methods skipped as designed. The same
      three authored journeys then passed **3/3** on a 13-inch iPad in
      landscape. Coverage includes the Hearthlight empty and populated Tasks
      states, completion/undo, Capture, Bulk entry, Work Session, Task Edit,
      Blocked Time, Weave, Schedule continuity, onboarding, largest Dynamic
      Type, and native accessibility semantics.
- [x] A fresh Debug simulator build, development-signed Release device build,
      Release analysis, and unsigned generic-device archive all completed with
      zero compiler, linker, or analyzer diagnostics on the frozen source.
      Xcode 26.6 (17F113), Swift 6.3.3, and the iOS 26.5 SDK (23F81a) were used.
      The archive contains the app and widget, matching arm64 dSYMs, valid
      privacy manifests, iOS 18 deployment metadata, and iPhone+iPad device
      families. The separately development-signed Release build confirms that
      the app and widget carry the matching Filuma App Group entitlement.
- [x] The final Hallmark native-design audit passes **58/58 gates**, including
      semantic contrast, 44-point targets, Dynamic Type, Reduce Motion, native
      controls, layout containment, and Hearthlight-specific restraint.
- [x] Urgency red now maintains at least 4.68:1 contrast against Filuma's lightest
      dark card surface, clearing normal-text contrast guidance.
- [x] `ITSAppUsesNonExemptEncryption = NO` is declared in the app plist.

## Blockers â do before submitting

- [ ] **App name: âFilumaâ chosen 2026-07-18** (the original name, âLoom,â was
      not available). The full rename shipped the same day â bundle IDs
      (`com.christoforakis.Filuma` / `.FilumaWidgets`), App Group, keychain
      service, `filuma://` URL scheme, notification category IDs, store
      filename, and all user-facing copy. Remaining human steps:
      - Reserve the name âFilumaâ in App Store Connect and run a trademark
        search to confirm availability.
      - **Google OAuth client**: build 6 reaches Google's branded âSign in to
        continue to Filumaâ page and Google displays Filuma's Privacy Policy and
        Terms of Service links, proving the current client ID and redirect enter
        a valid Filuma OAuth flow. Google Cloud Console must still confirm that
        the iOS client's registered bundle ID is
        `com.christoforakis.Filuma` and that production publishing/verification
        is complete.
      - **Apple Developer portal**: register the new bundle IDs and App Group
        `group.com.christoforakis.Filuma` (automatic signing will offer this on
        the next signed build; confirm provisioning for both targets).
      - Dev devices only: pre-rename installs used the old identifiers, so the
        old âLoomâ Apple calendar and Google events tagged `private.loom=1`
        will not be recognized by the renamed app. No public users exist, so
        no migration shim is needed â delete the old install and calendar.
- [x] **Support and Privacy Policy URLs are live.** On 2026-08-23,
      `https://sparkbiscuit.me/` and `https://sparkbiscuit.me/privacy/` both
      returned HTTP 200 over HTTPS. Enter and re-check these exact URLs in App
      Store Connect before submission.
- [x] **Tighten two privacy-policy absolutes before submission.** The policy
      now names the exact portable export categories and exclusions, explains
      direct optional Calendar transmission, and accurately describes local,
      Keychain, backup, and exported-calendar deletion behavior. The corrected
      page was deployed and returned HTTP 200 on 2026-08-23.
- [x] **Add the Privacy Policy link inside the app.** Settings â About now
      links to `https://sparkbiscuit.me/privacy/` (added 2026-07-18).
- [ ] **Choose and implement the subscription product before charging.** The
      repository currently contains no StoreKit products, entitlement source
      of truth, paywall, purchase/restore/manage-subscription paths, or Terms
      link. Decide the gated value, monthly/annual product IDs and prices,
      trial, Family Sharing, existing-user treatment, and Terms URL first;
      then implement and sandbox-test purchase, pending, cancellation,
      expiration, restore, offline launch, and refund/revocation behavior. Do
      not submit subscription metadata or promise pricing until those values
      are real.
- [x] **Archive with Xcode 26 or later and the iOS 26 SDK or later.** The frozen
      local archive was built with Xcode 26.6 and the iOS 26.5 SDK, satisfying
      the technical SDK floor in effect for uploads since April 28, 2026.
- [x] **Prove distribution signing and upload.** Build 6 exported successfully
      with Apple's cloud-managed distribution certificate and App Store
      provisioning for both app and widget. The exported app has
      `get-task-allow=false`, both targets retain
      `group.com.christoforakis.Filuma`, and Xcode reported **Upload succeeded**
      at 23:10 on 2026-08-23. App Store Connect then finished processing build
      6 and reports it **Ready to Submit**.
- [ ] **Google OAuth consent screen**: in Google Cloud Console, confirm the
      OAuth consent screen is **published** (not "Testing") and, if Google
      flags the `calendar.events` scope as sensitive, that verification is
      complete. In Testing mode only allow-listed accounts can sign in. Supply
      App Review with a working demo account or precise review instructions for
      the optional integration.
- [ ] **App Privacy label** (App Store Connect â App Privacy): answer
      accurately for the submitted binary and published policy. Local
      SwiftData, Apple framework processing, and transient OAuth requests do
      not by themselves require disclosure, but optional Google Calendar export
      writes task-derived work-block content to the user's Google account on an
      ongoing basis. Apple's current definition and optional-disclosure rules
      make **Other User Content â linked to the user â App Functionality â not
      tracking** the conservative answer. See
      `docs/app-store-privacy-disclosure.md`; do not attest âData Not
      Collected.â
- [ ] **Age rating questionnaire**: answer for the exact submitted product and
      marketing copy. Do not assume 4+ if the listing frames Filuma as ADHD or
      health/wellness support; use the rating App Store Connect derives from
      the truthful answers.
- [x] **Capture required screenshots**: build 6 iPhone screenshots plus the
      required **13-inch iPad** set because the app ships natively to iPad.
      The curated sets are preserved under `AppStoreAssets/1.3.0-build6` at
      1242Ã2688 and 2064Ã2752. The iPad compositions are native layouts rather
      than scaled phone captures.
- [ ] **Physical-device capability pass**: install an archive-signed build and
      verify the shared SwiftData store/App Group across the app and widget,
      widget refresh, Live Activity start/deep link/pause/resume/end from the
      Lock Screen and Dynamic Island, local notifications, speech, and Calendar
      permissions. Confirm App Group provisioning for both bundle identifiers.
- [ ] **Export compliance**: already answered in code
      (`ITSAppUsesNonExemptEncryption = NO`) â TestFlight should not ask.
      If Connect still asks, answer "standard encryption only / exempt."

## App Store Connect metadata

- [ ] Unique app name, subtitle, and description (name and subtitle are each
      limited to 30 characters). The README's feature list is a strong draft;
      avoid claiming anything not in the submitted build.
- [ ] Keywords, category (Productivity).
- [ ] **Support URL** (required) and marketing URL (optional); verify the
      deployed pages load without authentication.
- [ ] **Privacy policy URL** (required even with "Data Not Collected"), matching
      the in-app link and actual submitted behavior.
- [ ] Screenshots: 6.9" iPhone required; **iPad 13" also required because the
      app ships to iPad** (`TARGETED_DEVICE_FAMILY = 1,2`). Take iPad
      screenshots seriously â reviewers test on iPad (Guideline 2.4.1).
- [ ] Age rating questionnaire, using the derived rating from truthful answers
      rather than targeting a predetermined rating.

## App Review notes (paste into "Notes for Review")

```
Filuma is fully usable without an account or login. Sign-in required should remain OFF.

Google Calendar sync is optional and not required to review core features (tasks, scheduling, Focus, Weave, widgets). No demo account is needed for the main app. If you choose to test Google Calendar, use any Google account; Filuma requests calendar.events access only after the reviewer taps Connect Google Calendar in Settings.

How to reach Filuma Pro / the purchase UI:
1. Skip or complete onboarding with defaults.
2. Create three active tasks (Capture / +).
3. Attempt a fourth active task, or open Settings → Filuma Pro → Unlock Filuma Pro.
4. On the paywall, confirm monthly and annual title, length, and price; tap Privacy Policy and Terms of Use (EULA); Restore Purchases is available.

Filuma Pro is an auto-renewable subscription (monthly and annual). The paywall shows subscription title, length, and price before purchase, plus functional Privacy Policy and Terms of Use (EULA) links. Restore Purchases is available on the paywall and in Settings.

Privacy Policy: https://sparkbiscuit.me/privacy/
Terms of Use (Apple Standard EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

## Recommended device pass before TestFlight

- [ ] One VoiceOver walk-through of the Tasks tab + capture sheet.
- [ ] One run at the largest accessibility Dynamic Type size.
- [ ] One iPad session (portrait + landscape, plus narrow and short resizable
      windows) touching all four tabs.
- [ ] One physical-device App Group/widget/Live Activity pass, including pause
      and resume while the app is backgrounded and the screen is locked.
- [ ] Launch from a cold start â should now open on the dark Hearthlight
      background (no white flash).

## Deliberate decisions (documented so nobody "fixes" them)

- **No Sign in with Apple**: not required â Google OAuth is a data
  integration, not an account system (Guideline 4.8 does not apply).
- **Dark-only appearance**: locked via `.preferredColorScheme(.dark)`;
  consistent and HIG-acceptable as a deliberate design.
- **Optional onboarding**: the three-stage flow requests no permissions,
  existing users bypass it, and first-time users can choose âStart with
  defaultsâ without opening the schedule editors.

## Known issues after 1.4.0 (logged 2026-09-16)

Found in a read-only review on 2026-09-16; nothing here has been fixed yet.
Filuma is maintenance-only, so these are bug fixes for the next update, not new
features.

### High

- [ ] **Google Calendar import window never advances after the first sync.**
      `Filuma/GoogleCalendarService.swift:228` does a full fetch only when
      `googleSyncToken` is nil, and `fetchEvents` (`:1014-1025`) sends the
      30-day `timeMin`/`timeMax` window only on that full fetch. Later syncs
      send the token and get back only changed events. The token is cleared
      only on connect, import on/off, disconnect, Pro lapse, or an HTTP 410.
      Failure: an event that was more than 30 days out at connect time and is
      never edited is never imported, and with `singleEvents=true` that
      includes every instance of a weekly recurring event. About a month after
      connecting, Filuma schedules and exports work blocks on top of real
      commitments. Fix: force a full window fetch (token nil,
      `fullSync = true`) when the last full sync is more than about 24 hours
      old, keeping that timestamp in App Group `UserDefaults` to avoid a schema
      change; or always do the 30-day full fetch on foreground (1-3 pages, and
      `reconcileImport` already drops orphans on a full sync). Add a test that
      an event outside the first window is imported once the window moves
      forward. Effort: S.

### Medium

- [ ] **Busy-time import covers 30 days, but 1.4 spreads sessions across the
      whole deadline window.** `Filuma/CalendarImportService.swift:46` sets
      `horizonDays = 30` (Google shares it at
      `Filuma/GoogleCalendarService.swift:18`), export runs 60 days out
      (`Filuma/CalendarExportService.swift:36`), and `spread()` aims later
      sessions toward the Safe Zone finish
      (`Filuma/SchedulerService.swift:1081-1089`). Deadline pickers have no
      upper limit and the Siri intent allows 60 days
      (`Filuma/FilumaIntents.swift:21`). Failure: a task due in six weeks gets
      sessions in weeks 5-6, where Filuma has no calendar data. They land on
      real events, get exported, and are only repaired, by rescheduling the
      whole task, once those events enter the 30-day window. Fix: raise the
      import horizon to at least the export horizon (60 days), or to the latest
      active deadline capped at about 120 days. Alternative: when any import is
      on, clamp `targetFinish` to now plus the import horizon. Add a scheduler
      test with a busy event past day 30. Effort: S.
- [ ] **A full-plan rebuild moves every other task's spread sessions later.**
      `rebalance` (`Filuma/SchedulerService.swift:313-321`) deletes and
      recreates every active task's unlocked blocks, and `spread()`
      (`:1087-1089`) targets each session from `first`, the earliest free slot,
      which starts at now plus the start buffer (`:323-325`). Rebuilds run
      whenever any block ends unchecked (`catchUpMissedBlocks`), on every
      capture (`Filuma/PlanCoordinator.swift:359`), and on settings changes
      (`:1711`, `:1811`). Failure: one missed block shifts unrelated tasks'
      future sessions. In a simplified Python port of `spread()` (no busy time),
      a four-session task due in nine days moved by 1h45, 1h15, 45m and 15m
      when rebuilt two hours later, so a "Thursday 2:00" session keeps drifting
      and its notification and exported event are rebuilt each time. Not yet
      reproduced in the app. The only stability test
      (`FilumaTests/FilumaTests.swift:652`) covers the unchanged case. Fix:
      first add a failing test (task A has a missed block; after
      `catchUpMissedBlocks` runs later, task B's future start times are
      unchanged). Then either have `rebalance` hand each deleted block's old
      start to `spread()` and keep it when still free and on time, or compute
      `first` from a stable origin such as start of today instead of `now`.
      Effort: M.
- [ ] **Help & Support does not lead to Filuma help.** The in-app link
      (`Filuma/SettingsView.swift:1321`) and the App Store support URL both
      point to `https://sparkbiscuit.me/`, which has no Filuma help;
      `/filuma/support/` returns 404 and the homepage's only contact is a small
      email link. Failure: a Pro subscriber looking for help with the
      subscription, calendars, or export finds nothing about Filuma. Fix: the
      site-side support page is tracked in the sparkbiscuit.me notes. In the
      next update, move this link to a dedicated Filuma support URL once it is
      live, and switch the App Store Support URL in the same submission.
      Effort: S.

### Low

- [ ] **A Pro lapse switches off all four calendar integration settings for
      good.** `ProFeatureSuspension.reconcileFreeTier`
      (`Filuma/FilumaPro.swift:463-471`) sets Apple and Google import and
      export to false and clears the sync token whenever the entitlement
      becomes free (`Filuma/FilumaApp.swift:747`). Import and export are
      already gated on `FilumaProAccess.isPro` at runtime. Failure: a
      subscriber whose renewal fails and who later re-subscribes finds every
      integration off, with no notice, and has to re-enable each one. Stopping
      integrations on lapse is intentional (doc comment at `:441-445`); only
      the lost toggles are the problem. Fix: delete only the imported
      busy-event copies (and optionally the token), leave the four settings
      alone, and rely on the existing `isPro` checks. Add a Pro, free, Pro test
      that the settings survive. Effort: S.
- [ ] **Calendar import counts Free and declined events as busy.** Apple import
      drops all-day events but checks neither availability nor the user's
      response (`Filuma/CalendarImportService.swift:84`). Google's `GEvent`
      (`Filuma/GoogleCalendarService.swift:120-126`) doesn't decode
      transparency or attendees, and `reconcileImport` skips only cancelled,
      all-day, and Filuma-tagged events. Failure: any declined meeting, or any
      event marked Free, blocks scheduler time, so work is pushed off open time
      or reported as no longer fitting. Fix: for Apple, also skip
      `availability == .free` and events the current user declined; for Google,
      decode `transparency` and `attendees[].self`/`responseStatus` and skip
      transparent or self-declined events. Add a `reconcileImport` test for
      each. Effort: S.
- [ ] **Notification triggers carry no time zone.** Block-start and heads-up
      triggers (`Filuma/BlockNotificationService.swift:508-512`), digests
      (`:444-448`), and reminders (`Filuma/NotificationService.swift:51-55`)
      build `[.year, .month, .day, .hour, .minute]` without `.timeZone`, and
      nothing in the app observes time-zone changes. Failure: the triggers are
      floating wall-clock times, so a student who flies from Eastern to Central
      without opening Filuma gets the block-start alert an hour after the block
      began, until the next foreground rebuild. This follows from the API and
      has not been seen on a device. Fix: add `.timeZone` to the components for
      block starts and heads-ups (or use `UNTimeIntervalNotificationTrigger`),
      and optionally rebuild on
      `UIApplication.significantTimeChangeNotification`. Effort: S.
- [ ] **README doesn't mention Filuma Pro and describes an outdated Weave.**
      The case study's Source link points to the public repo. `README.md:47`
      says the Weave shows "your last two weeks", and the README never mentions
      Filuma Pro, the free tier, or the optional Google Calendar connection.
      Failure: readers get an inaccurate picture of 1.4, where calendar
      integrations, widgets, weekly repeats, and the Weave are Pro-only and the
      Weave offers Week, 2 Weeks, and Month (`Filuma/WeaveView.swift:148-152`).
      Fix: add a short Free and Pro paragraph that matches the sparkbiscuit.me
      copy (free for up to three active tasks, Pro for more), change the Weave
      line to "a week, two weeks, or a month", and mention Google Calendar.
      Effort: S.
- [ ] **Paywall copy undersells the Weave and implies a free partial one.**
      `Filuma/FilumaPro.swift:313` lists "Your full two-week Weave", and the
      `.weave` message at `:149` says "the last two weeks". The app offers
      Week, 2 Weeks, and Month, and `Filuma/FilumaApp.swift:578-584` locks the
      whole Weave tab for free users. Failure: the benefit list App Review
      reads leaves out the Month view, and "full" suggests free users get part
      of the Weave. Fix, in the same copy pass as the README with no layout
      change: make the benefit "The Weave: a week, two weeks, or a month" and
      start the `.weave` message with "See your recent weeks of". Effort: S.
- [ ] **Tests don't cover plan stability after a missed block, busy time past
      the import window, or DST, and they depend on the real clock.**
      `FilumaTests/FilumaTests.swift:9` uses `Calendar.current`, and the anchor
      at `:29-32` is 9:00 tomorrow from `Date()`, with deadlines added in
      hours. No test mentions time zones or DST, and the only distribution
      stability test (`:652`) covers the unchanged case. Google sync-token
      handling is otherwise well tested in
      `FilumaTests/GoogleCalendarTests.swift`; only window staleness is
      missing. Failure: a run in a DST week (next US change 2026-11-01) tests
      different wall-clock geometry, and the three scheduling and import bugs
      above have no regression coverage. Fix: give scheduler tests a fixed
      Gregorian calendar, time zone (e.g. `America/New_York`), and reference
      date. Add tests that a missed block leaves other tasks unchanged, that
      busy time past day 30 is respected, that a week crossing DST places
      blocks correctly, and that a stale Google window forces a full fetch.
      Most of this lands with the fixes above. Effort: M.
- [ ] **Task-plan preview force-unwraps its block list (needs a device
      check).** `TaskDistributionView` uses `blocks.first!` and `blocks.last!`
      inside a `GeometryReader` (`Filuma/ScheduleView.swift:1855-1856`) and
      again at `:1877`, while `blocks` re-reads `task.scheduledBlocks` on every
      access and the `!blocks.isEmpty` check is at `:1850`. Failure (not
      reproduced): if completing, deleting, or replanning the task removes its
      blocks between that check and a later layout pass, for example during a
      removal transition, the unwrap traps. SwiftUI normally re-evaluates the
      `if` first and `now` is fixed at init, so this may not be reachable. Fix:
      read `let blocks = self.blocks` once in `body` and use
      `guard let first = blocks.first, let last = blocks.last` instead of force
      unwraps. Effort: S.

## Follow-ups worth considering (not release-gating)

- Digest notifications (morning preview / evening wrap-up) default ON behind
  one permission grant; consider making them opt-in from Settings.
- Cap the deadline date picker (e.g. two years out) so pathological far-future
  deadlines can't slow the day-by-day slot search.
- Live Activity pause/resume via App Intents is implemented; keep its physical
  device and archive-signed verification as a release gate until it passes.
- Move Google export-ID cleanup onto a private SwiftData context with explicit
  best-effort failure handling. Export-off is already durable and re-enable
  self-heals stale IDs, so this is hardening rather than a release blocker.
- Add an on-disk pre-change SwiftData fixture that opens through the current
  schema, including the inline-default `planningRebuildPending` field. Current
  tests comprehensively exercise the live schema but do not yet prove an
  upgrade from a historical store file.
- Listen for `EKEventStoreChanged` so the Apple Calendar busy-time copy
  refreshes while the app stays open.
- Use SwiftUI's `manageSubscriptionsSheet` instead of opening the
  `apps.apple.com/account/subscriptions` URL from Settings.

## Frozen verification artifacts â 2026-08-23

- Units: `/tmp/Filuma-frozen-units.Oq8spL/FilumaUnits.xcresult`
- Phone UI: `/tmp/filuma-authoritative-phone.1YnuMz/Filuma-phone-ui.xcresult`
- iPad Capture: `/tmp/Filuma-frozen-ipad-capture.pYXKdT/CaptureIPad.xcresult`
- iPad navigation: `/tmp/Filuma-frozen-ipad-navigation.HXla2c/CoreNavigationIPad.xcresult`
- iPad onboarding: `/tmp/Filuma-frozen-ipad-onboarding.8Au8bb/OnboardingIPad.xcresult`
- Builds, analysis, and archive: `/tmp/FilumaFinalRelease626.P4VVhM`

These `/tmp` artifacts are local verification evidence and may be removed by
macOS. Preserve or regenerate them before relying on the paths as a permanent
release record.
