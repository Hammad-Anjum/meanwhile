# Meanwhile

See `README.md` for build commands and `docs/README.md` for the design.

## Visual tracking

`docs/progress.html` tracks the project visually: a high-level diagram (runtime pieces and data flow), a low-level diagram (targets, files, and calls), task status, open questions, and a change log.

After every major change (a task from `docs/mvp-plan.md` finished, a new target or component, or a change in how components connect):
1. Move the current two diagrams into a collapsed `<details>` block under "Earlier snapshots", labelled with the date.
2. Update both Mermaid diagrams to match the code. Solid boxes are built; dashed (`:::planned`) boxes are planned.
3. Update the task status pills, the counters at the top, open questions, and "Last updated".
4. Add a line to the change log.

Also mark the task done in `docs/mvp-plan.md` so the two stay in sync.
