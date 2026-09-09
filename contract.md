<!-- Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V5 -->

# Filuma design contract

## Product character

Filuma is a calm planning companion for people who can feel friction before
they begin. Its job is to reduce a crowded day to one believable next action.
The interface should feel warm, capable, and quietly alive—not clinical,
gamified, or euphoric about productivity.

- Genre: atmospheric utility.
- Tone: intimate, luminous, assured, never cute.
- Palette anchor: the user-selected Hearth accent against near-black graphite.
- Structural fingerprint: one bright thread or focal object, then a restrained
  working surface around it.

## Visual hierarchy

1. Every screen gets one unmistakable purpose and at most one dominant action.
2. The current commitment is visually stronger than the backlog. On Tasks,
   that means Focus first, then Up Next, then the quieter Library.
3. Cards exist to group decisions, not to decorate every sentence. Prefer
   spacing, dividers, and type hierarchy for secondary information.
4. Glow marks attention, continuity, or a meaningful state change. It is not a
   generic shadow. A screen should have one primary glow field.
5. The Hearth thread is a narrative device: use it for beginnings, continuity,
   and completion. Do not turn every list row into a separate illustration.

## System primitives

- Colors come from the semantic tokens in `Filuma/AppTheme.swift`:
  `filumaBackground`, `filumaSurface*`, `filumaText`, `filumaSubtle`,
  `filumaFaint`, `filumaBorder`, `brand*`, and context colors. Screens do not
  invent local hex colors when an existing role fits.
- Type comes from `AppFont`. Native serif display titles carry warmth; SF
  body styles provide optical sizing and Dynamic Type. Monospaced digits are
  reserved for time and quantities.
- Corners come from `FilumaRadius`; readable widths come from `FilumaLayout`.
  Repetition should produce rhythm, not a wall of identical floating capsules.
- Standard screen atmosphere comes from `HearthScreenBackground`/`hearthScreen`.
  Particle density stays low enough that content remains the event.

## Motion and feedback

- Motion explains cause and effect: a thread connects, a plan moves, a task
  seals, or a control settles into state.
- Ordinary changes use `HearthMotion.control` or `.selection`; one-shot reveals
  use `.reveal`. Overshoot belongs only to momentum or celebration.
- Keep animations interruptible and local. Never delay durable data mutations
  to wait for presentation; commit first, then animate the receipt.
- Haptics land on the visible state change, not at animation start.
- Reduce Motion replaces travel, particles, and repeated breathing with a short
  opacity/state transition. Essential status must never depend on animation.

## Interaction and language

- Primary actions use direct verbs: Add first task, Start, Save progress, Done.
  Secondary copy may be warm but must remain truthful about what was persisted.
- Completion celebrates closure without judgment. Missed or overdue work is a
  planning fact, never a moral failure.
- Destructive and discard actions are explicit; failed saves keep the draft or
  retry identity intact and explain exactly what is safe.
- Every actionable semantic target is at least 44×44 points. Fixed action bars
  stay above the custom navigation dock and keyboard.
- Dynamic Type, VoiceOver, Reduce Motion, iPhone, and iPad landscape are design
  inputs, not cleanup modes. At accessibility sizes, horizontal control groups
  may stack but their order and meaning must stay intact.

## Screen signatures

- Tasks empty: one luminous first-thread tableau and one invitation to begin.
- Today populated: landscape → current session → connected upcoming sessions
  → Library. The session itself leads, without a duplicate Focus heading.
- Schedule: time is spatial and truthful, including overnight continuity.
- Work Session: the timer is the quiet center; controls remain fixed, reachable,
  and recoverable after persistence failures.
- Capture and Edit: progressive disclosure, capped readable forms, one fixed
  commit surface, validation adjacent to the relevant field.
- Completion: a deterministic knot/seal ritual built from native shapes, with
  Done and Undo always available.
- Weave: one adjustable tapestry surface with context-colored strands and knots
  sized by recorded effort. Horizontal position represents date; vertical travel
  expresses weaving, not a value axis. The selected period controls its totals.

## Forbidden defaults

- No glass-on-glass card soup, arbitrary gradients, neon borders everywhere,
  decorative SF Symbols, fake metrics, or confetti as a substitute for meaning.
- No giant empty title stacks, repeated ALL-CAPS section labels, or identical
  rounded cards for unrelated hierarchy levels.
- No infinite ambient motion, bounce on routine controls, hidden save failure,
  or UI state that claims success before durable persistence.
- No subscription surface until the product IDs, pricing, trial, entitlement
  boundary, restore path, existing-user treatment, and Terms URL are real.

## Release bar

A slice is complete only when it builds, preserves durable data semantics,
passes its focused unit/UI journeys, survives Accessibility 5 and iPad
landscape where applicable, honors Reduce Motion, and passes the Hallmark
slop test without weakening a failing accessibility gate.


## Distributed work update

The user's September 2026 concept board updates the earlier type direction.
Keep the ember, warm landscape, native interactions, and visible continuity.
Light appearance follows the system and uses darker semantic foregrounds.

Reserve achievable capacity before improving spacing. Prefer distinct days and
separated sessions before the Safe Zone, then use the actual deadline window.
Safe Zone is a preference, not a hard cutoff. Existing saved buffers remain;
new users start with one day. An explicit task override of zero means None.
Completed work, valid locks, active timers, availability, daily limits, and
user-selected earliest starts remain constraints. Unchanged automatic refreshes
must preserve session identities and dates.

Plan copy comes from actual reservations. Do not claim an early finish when
some remaining effort lacks coverage. Connect sessions belonging to the same
task in the preview; context color alone never implies shared task identity.
