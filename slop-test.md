<!-- Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V5 -->

# Filuma Hallmark slop test

Final native-iOS audit for the Hearthlight polish pass. Hallmark's web-specific
language is translated to the equivalent SwiftUI, Human Interface Guidelines,
Dynamic Type, VoiceOver, and Reduce Motion behavior. A gate marked **N/A** is a
browser-only construction that is not present in this app; it still receives a
definitive “no” answer.

## Result

**58 / 58 gates pass. No known Hallmark release blocker remains.**

The product position is deliberately specific: Filuma is an atmospheric
utility whose visual hierarchy reduces a crowded day to one believable next
action. Hearth glow and thread imagery carry continuity or closure; they are
not generic decoration. The complete design contract lives in `contract.md`.

## Six-axis critique

| Axis | Score | Evidence |
| --- | ---: | --- |
| Philosophy | 5 | Calm, honest planning is a clear product position rather than a decorative skin. |
| Hierarchy | 5 | Focus → continuity → Library, single-purpose secondary flows, and one dominant commit action per screen. |
| Execution | 5 | Semantic tokens, contrast calculations, 44-point gates, Reduce Motion, Dynamic Type, iPad, persistence receipts, and simulator journeys are implemented and verified. |
| Specificity | 5 | Hearth thread, completion seal, overnight schedule continuity, Work Session timer, and tactile Weave are specific to Filuma. |
| Restraint | 5 | Card soup, fake metrics, ambient spectacle, title gradients, decorative badges, and redundant labels were removed. |
| Variety | 5 | Empty Tasks, populated Tasks, Schedule, Work Session, Capture/Edit, completion, and Weave each have a distinct structural signature inside one system. |

## Gate sweep

| # | Result | Native audit |
| ---: | :---: | --- |
| 1 | Pass | Nunito is the warm display/body family; JetBrains Mono is reserved for time and compact quantities. No generic system display default. |
| 2 | Pass | No gradient text and no purple-to-blue/cyan-to-magenta treatment. The restrained Hearth fill stays within one selected accent family. |
| 3 | Pass | No equal three-column icon-card feature grid. |
| 4 | Pass | Revised flows use continuous surfaces, spacing, and dividers instead of cards nested in cards. |
| 5 | Pass | No thick colored side-stripe cards. |
| 6 | Pass | The empty Tasks tableau is an allowed atmospheric canvas with one invitation; other screens are purpose-led rather than centered hero stacks. |
| 7 | Pass | Near-black graphite and warm semantic ink replace pure black/white bases. |
| 8 | Pass | Each core flow has a product-specific structure; there is no hero/features/CTA template. |
| 9 | Pass | Thread connectors, rules, grouped surfaces, timeline geometry, and type hierarchy create varied section rhythm. |
| 10 | N/A | SwiftUI has no CSS `transition-all`; animations are named through `HearthMotion`. |
| 11 | N/A | No web hover-scale convention. Press feedback is local, subtle, and semantic. |
| 12 | Pass | Routine state changes do not bounce. Spring character is reserved for physical or completion moments. |
| 13 | N/A | No stacked web hover-effects. |
| 14 | Pass | Decorative progress and reveal motion uses transform/opacity; durable mutations are not delayed for layout animation. |
| 15 | N/A | Native focus indication is not animated into existence. |
| 16 | Pass | Completion has a meaningful deterministic seal and Undo; routine visible saves do not trigger celebratory toast noise. |
| 17 | N/A | No hover/focus tooltip system. |
| 18 | N/A | No auto-rotating carousel, banner, or statistic. |
| 19 | Pass | No placeholder people, companies, or startup-cliché content. |
| 20 | Pass | Native adaptation: `contract.md` begins with the Hallmark critique stamp and `AppTheme.swift` is the durable system artifact. |
| 21 | Pass | No specimen/editorial fall-through. Filuma stays an atmospheric utility. |
| 22 | Pass | Graphite surfaces carry a subtle warm/cool tint rather than flat pure-grey page bands. |
| 23 | Pass | Accent is limited to focus, state, continuity, and one restrained atmospheric field. |
| 24 | Pass | Structural rhythm is on `FilumaSpacing`; retained optical/system-control insets are intentional native metrics rather than arbitrary page rhythm. |
| 25 | Pass | Capped readable widths keep prose and forms within comfortable measure on iPhone and iPad. |
| 26 | Pass | Native Buttons, Toggles, Steppers, and DatePickers preserve pressed/focus/disabled semantics; task-specific loading/error/success states remain explicit. |
| 27 | Pass | Spatial/decorative motion has a Reduce Motion path; essential state never depends on animation. |
| 28 | N/A | No autoplay hero video. |
| 29 | Pass | Background atmosphere uses a restrained, fixed same-family glow; no animated mesh or multicolor aurora. |
| 30 | Pass | One native icon language—SF Symbols—plus purpose-built Hearth shapes; no emoji feature icons. |
| 31 | Pass | No Lottie dependency or canned animation asset. |
| 32 | N/A | No repeated Hallmark marketing-page archetype to diversify. |
| 33 | Pass | Decorative native shapes are hidden or absorbed into meaningful parent semantics; interactive surfaces own the accessible label. |
| 34 | Pass | Capped layouts, shared Schedule scrolling, and phone/iPad UI journeys show no unintended horizontal overflow. |
| 35 | N/A | No web highlighter-band or decorative text-stroke treatment. |
| 36 | Pass | Mixed action rows and fixed commit bars are explicitly aligned and remain above the keyboard/navigation dock. |
| 37 | Pass | Two font families total: Nunito and JetBrains Mono. |
| 38 | Pass | Mono is a functional register for times/quantities/status, never a competing display surface. |
| 38a | Pass | Headings and display type are upright; there are no italic headline fragments. |
| 39 | Pass | Capture/Edit/Blocked Time reserve adjacent helper/error space, preserve drafts on failure, and use native disabled semantics without border-width shifts. |
| 40 | Pass | Body/control pairs meet 4.5:1; large text, icons, and focus/state marks meet 3:1. Accent-fill contrast was calculated across Ember, Indigo, Sage, and Violet. |
| 41 | Pass | `filumaControlInk` is the explicit accent/context-fill ink. Dark surfaces consistently inherit light semantic text. |
| 42 | N/A | Filuma uses its compact native-style bottom dock, not a marketing-site link bar. |
| 43 | N/A | No website footer. |
| 44 | Pass | Empty-state purpose, invitation, and focal thread fit the initial viewport; fixed controls remain visible at Accessibility 5. |
| 45 | Pass | The Hearth thread communicates beginning, continuity, focus, or closure; unrelated ornament was removed. |
| 46 | Pass | No fabricated social proof or performance metric. Weave language reflects derived user data and labels estimates honestly. |
| 47 | Pass | No fake browser, phone, terminal, or IDE chrome. |
| 48 | Pass | Raw color construction is confined to semantic tokens in `AppTheme.swift`; screens consume named roles. |
| 49 | Pass | Primary actions use short direct verbs and remain independently reachable at Accessibility 5. |
| 50 | N/A | No CSS image-bearing grid tracks. |
| 51 | Pass | SwiftUI text reflows inside capped, zero-minimum-width adaptive layouts without clipping display headings. |
| 52 | N/A | No CSS theme-specific section-head grid. |
| 53 | N/A | No CSS radio-tab pattern. |
| 54 | Pass | Repeated all-caps eyebrow labels were removed; headings remain vertical, ordinary, and sentence case. |
| 55 | Pass | No all-caps display heading with collision-prone leading. |
| 56 | Pass | Native safe areas and explicit action-bar layering prevent fixed surfaces from bleeding into the navigation dock. |
| 57 | N/A | No studied-DNA handoff occurred in this project. |

## Native release evidence

- Frozen compiled-input fingerprint:
  `62608e6481ef259eacb3496a0968e1e530eb4e6bfd4395f0b024ff5163398b3f`.
- Static parse and whitespace validation pass for app, unit-test, and UI-test
  sources.
- Unit matrix: **210 passed, 0 failed, 0 skipped** (178 app tests and 32 Google
  Calendar tests).
- Once-only phone UI matrix: **26 applicable journeys passed, 0 failed**; the
  three iPad-only methods skipped as designed.
- Authored 13-inch iPad landscape matrix: **3 passed, 0 failed**.
- The UI matrix covers Accessibility 5, native switch semantics, fixed commit
  actions, task completion/undo, overnight and far-future Schedule handoff,
  dirty-draft confirmation, Weave selection, Capture, Bulk entry, Work Session,
  onboarding, and iPad landscape.
- Xcode 26.6 Debug simulator build, development-signed Release device build,
  Release analysis, and unsigned archive all pass with zero diagnostics using
  the iOS 26.5 SDK. Archive structure, dSYMs, privacy manifests, and device
  families validate; the separately development-signed Release build confirms
  matching app-group entitlements. Distribution signing/export and App Store
  upload remain human release gates.
- Exact artifact paths and remaining external gates are tracked in
  `docs/release-checklist.md`.
