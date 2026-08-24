# Filuma — TestFlight / App Store submission checklist

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
- [x] Onboarding is a three-stage welcome → day → block setup with a one-tap
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

## Blockers — do before submitting

- [ ] **App name: “Filuma” chosen 2026-07-18** (the original name, “Loom,” was
      not available). The full rename shipped the same day — bundle IDs
      (`com.christoforakis.Filuma` / `.FilumaWidgets`), App Group, keychain
      service, `filuma://` URL scheme, notification category IDs, store
      filename, and all user-facing copy. Remaining human steps:
      - Reserve the name “Filuma” in App Store Connect and run a trademark
        search to confirm availability.
      - **Google OAuth client**: build 6 reaches Google's branded “Sign in to
        continue to Filuma” page and Google displays Filuma's Privacy Policy and
        Terms of Service links, proving the current client ID and redirect enter
        a valid Filuma OAuth flow. Google Cloud Console must still confirm that
        the iOS client's registered bundle ID is
        `com.christoforakis.Filuma` and that production publishing/verification
        is complete.
      - **Apple Developer portal**: register the new bundle IDs and App Group
        `group.com.christoforakis.Filuma` (automatic signing will offer this on
        the next signed build; confirm provisioning for both targets).
      - Dev devices only: pre-rename installs used the old identifiers, so the
        old “Loom” Apple calendar and Google events tagged `private.loom=1`
        will not be recognized by the renamed app. No public users exist, so
        no migration shim is needed — delete the old install and calendar.
- [x] **Support and Privacy Policy URLs are live.** On 2026-08-23,
      `https://sparkbiscuit.me/` and `https://sparkbiscuit.me/privacy/` both
      returned HTTP 200 over HTTPS. Enter and re-check these exact URLs in App
      Store Connect before submission.
- [x] **Tighten two privacy-policy absolutes before submission.** The policy
      now names the exact portable export categories and exclusions, explains
      direct optional Calendar transmission, and accurately describes local,
      Keychain, backup, and exported-calendar deletion behavior. The corrected
      page was deployed and returned HTTP 200 on 2026-08-23.
- [x] **Add the Privacy Policy link inside the app.** Settings → About now
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
- [ ] **App Privacy label** (App Store Connect → App Privacy): answer
      accurately for the submitted binary and published policy. Local
      SwiftData, Apple framework processing, and transient OAuth requests do
      not by themselves require disclosure, but optional Google Calendar export
      writes task-derived work-block content to the user's Google account on an
      ongoing basis. Apple's current definition and optional-disclosure rules
      make **Other User Content — linked to the user — App Functionality — not
      tracking** the conservative answer. See
      `docs/app-store-privacy-disclosure.md`; do not attest “Data Not
      Collected.”
- [ ] **Age rating questionnaire**: answer for the exact submitted product and
      marketing copy. Do not assume 4+ if the listing frames Filuma as ADHD or
      health/wellness support; use the rating App Store Connect derives from
      the truthful answers.
- [x] **Capture required screenshots**: build 6 iPhone screenshots plus the
      required **13-inch iPad** set because the app ships natively to iPad.
      The curated sets are preserved under `AppStoreAssets/1.3.0-build6` at
      1242×2688 and 2064×2752. The iPad compositions are native layouts rather
      than scaled phone captures.
- [ ] **Physical-device capability pass**: install an archive-signed build and
      verify the shared SwiftData store/App Group across the app and widget,
      widget refresh, Live Activity start/deep link/pause/resume/end from the
      Lock Screen and Dynamic Island, local notifications, speech, and Calendar
      permissions. Confirm App Group provisioning for both bundle identifiers.
- [ ] **Export compliance**: already answered in code
      (`ITSAppUsesNonExemptEncryption = NO`) — TestFlight should not ask.
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
      screenshots seriously — reviewers test on iPad (Guideline 2.4.1).
- [ ] Age rating questionnaire, using the derived rating from truthful answers
      rather than targeting a predetermined rating.

## App Review notes (paste into "Notes for Review")

- Google Calendar sync is optional; the app is fully usable without it.
  If review needs a Google account to test sync, provide a demo account
  (Guideline 2.1 — demo credentials for any feature behind a login).
- Microphone/speech is used only for dictating a task in the capture sheet.
- The Live Activity's inline pause/resume control intentionally changes only
  the current work-session timer and does not open the app.

## Recommended device pass before TestFlight

- [ ] One VoiceOver walk-through of the Tasks tab + capture sheet.
- [ ] One run at the largest accessibility Dynamic Type size.
- [ ] One iPad session (portrait + landscape, plus narrow and short resizable
      windows) touching all four tabs.
- [ ] One physical-device App Group/widget/Live Activity pass, including pause
      and resume while the app is backgrounded and the screen is locked.
- [ ] Launch from a cold start — should now open on the dark Hearthlight
      background (no white flash).

## Deliberate decisions (documented so nobody "fixes" them)

- **No Sign in with Apple**: not required — Google OAuth is a data
  integration, not an account system (Guideline 4.8 does not apply).
- **Dark-only appearance**: locked via `.preferredColorScheme(.dark)`;
  consistent and HIG-acceptable as a deliberate design.
- **Optional onboarding**: the three-stage flow requests no permissions,
  existing users bypass it, and first-time users can choose “Start with
  defaults” without opening the schedule editors.

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

## Frozen verification artifacts — 2026-08-23

- Units: `/tmp/Filuma-frozen-units.Oq8spL/FilumaUnits.xcresult`
- Phone UI: `/tmp/filuma-authoritative-phone.1YnuMz/Filuma-phone-ui.xcresult`
- iPad Capture: `/tmp/Filuma-frozen-ipad-capture.pYXKdT/CaptureIPad.xcresult`
- iPad navigation: `/tmp/Filuma-frozen-ipad-navigation.HXla2c/CoreNavigationIPad.xcresult`
- iPad onboarding: `/tmp/Filuma-frozen-ipad-onboarding.8Au8bb/OnboardingIPad.xcresult`
- Builds, analysis, and archive: `/tmp/FilumaFinalRelease626.P4VVhM`

These `/tmp` artifacts are local verification evidence and may be removed by
macOS. Preserve or regenerate them before relying on the paths as a permanent
release record.
