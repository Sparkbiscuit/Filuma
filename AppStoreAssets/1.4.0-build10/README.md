# Filuma 1.4.0 (10) images

Captured September 9, 2026 from the actual updated app using synthetic demonstration data. No personal tasks or calendar events are included.

- `iphone-6.9/`: native 1320 × 2868 PNG screenshots.
- `ipad-13/`: native 2064 × 2752 PNG screenshots.
- `promo/filuma-landscape-wide.png`: generated 1672 × 941 website/campaign artwork.
- `promo/filuma-landscape-square.png`: generated 1254 × 1254 social/mobile artwork.

## Screenshot order

1. Today: one next action and upcoming work.
2. Distributed plan: saved sessions across multiple days.
3. Focus: the live work-session timer.
4. Schedule: a week of reserved work and task distribution summaries.
5. Weave: recorded effort across contexts.
6. Capture: a task, first step, deadline, and effort.
7. First task: an empty Today screen, included for existing website image replacements.

Each view has dark and light variants. For App Store upload, use 01–06 dark as one coherent sequence and choose selected light variants if desired (up to ten total per display-size/language set). The seventh view is primarily for like-for-like website updates.

Screenshots are unretouched. The screenshot UI-test class is `FilumaMarketingScreenshots`; launch fixtures never open the personal production store. Their clock/date content is illustrative and time-dependent. Regeneration instructions live in that test class.

## Campaign art provenance

Created with the built-in image-generation tool. The brief requested a restrained Filuma mountain/lake sunset, a fine glowing ember thread with four nodes, generous dark space, and the exact text “Filuma” / “Work, with room to breathe.” The square variant was recomposed from the wide artwork. These are brand illustrations, not app interface mockups; the app screenshots stay separate.

## Website mappings

- Christoforakis.com: `filuma-focus` → Today; `filuma-first-task` → empty Today; `filuma-session` → running Focus timer. Shared assets serve Nicholas’s profile and the Filuma project page.
- Sparkbiscuit.me: homepage Filuma card and `focus` → Today; `capture` → Capture; `tasks` → empty Today; `session` → running Focus timer; `weave` → Weave. Filuma’s hero uses wide artwork on desktop and square artwork on mobile.

See [submission instructions](../../docs/1.4.0-update-submission.md).
