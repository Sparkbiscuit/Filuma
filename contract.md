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
- Type comes from `AppFont`. Nunito carries warmth and hierarchy;
  JetBrains Mono is reserved for time, quantities, and compact status—not body
  copy or decorative technical flavor.
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
- Tasks populated: Focus → thread continuity → Library; no duplicate priority
  labels competing with the hero.
- Schedule: time is spatial and truthful, including overnight continuity.
- Work Session: the timer is the quiet center; controls remain fixed, reachable,
  and recoverable after persistence failures.
- Capture and Edit: progressive disclosure, capped readable forms, one fixed
  commit surface, validation adjacent to the relevant field.
- Completion: a deterministic knot/seal ritual built from native shapes, with
  Done and Undo always available.
- Weave: a single tactile tapestry surface for reflection—not fourteen tiny
  pseudo-controls or a dashboard of invented metrics.

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
