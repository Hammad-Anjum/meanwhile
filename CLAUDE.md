# Meanwhile

See `README.md` for build commands and `docs/README.md` for the design.

## Visual tracking

`docs/progress.html` tracks the project visually:
- **Overall architecture:** all phases combined, the runtime pieces and data flow.
- **Code structure:** targets, files, and calls.
- **Phase diagrams:** one per phase, showing what that phase builds.
- Task status, open questions, and a change log.

After every major change (a task from `docs/mvp-plan.md` finished, a new target or component, or a change in how components connect):
1. Move the current overall and code-structure diagrams into a collapsed `<details>` block under "Earlier snapshots", labelled with the date.
2. Update the overall and code-structure diagrams and the current phase's diagram to match the code. Solid boxes are built; dashed (`:::planned`) boxes are planned. Start each new phase with a new phase diagram.
3. Update the task status pills, the counters at the top, open questions, and "Last updated".
4. Add a line to the change log.

Also mark the task done in `docs/mvp-plan.md` so the two stay in sync.
