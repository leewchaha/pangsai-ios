# Highlights Posters / Randomized Story Export Audit

## Implemented
- Added a **poster-style conclusion page** as the last slide in Highlights.
- Added a **profile poster** entry point from the Me tab.
- Both poster types use **curated random templates** rather than arbitrary element-level randomness.
- Added **Shuffle**, **Share**, and **Save Image** actions.
- Story export is rendered in **9:16** format for Instagram-story-style sharing.
- Profile poster includes the user's equipped **poop cosmetic** and **pin shine**.

## Points economy note
- Confirmed there is **no daily tap cap** in the current project.
- The per-session cap remains unchanged in this pass.
- Cosmetic and shine prices were not rebalanced in this pass because the user asked to proceed with the poster work first.

## QA focus
- Verify the final Highlights page appears after the regular cards.
- Verify poster style stays stable until the user taps **Shuffle**.
- Verify saved images land in Photos and shared files export correctly.
- Verify long usernames do not overflow the profile poster.
- Verify cached 3D poop render appears in exported posters rather than a placeholder spinner.

## Risk / limitation
- Source parsing passes, but actual poster export and Photos saving still require iPhone verification.
