# conker-nx — notes for Claude

Nintendo Switch port of Conker: Live & Reloaded (original Xbox) by static recompilation.

Documentation lives in two places, kept in step: this repo's `docs/` (start with `docs/README.md`; living
log `docs/09-bringup-log.md`) and the separate guide repo `../nx-port-guide` (Conker material in
`platforms/xbox/conker/`, living log `conker-logbook.md`). The two need not match word for word or file name.

## Rules

- **Never add Claude as a co-author.** No `Co-Authored-By: Claude ...` trailer in commit messages, and no
  "Generated with Claude Code" line in pull request descriptions.
- Never commit game data (disc images, extracted files, `default.xbe`) or generated C (`gen/`).
- Every finding and log goes to **both** `docs/` here and `../nx-port-guide`, in an existing file whenever one
  fits; create a new file only if nothing fits. In the guide, game-specific content goes under the game's
  folder, and anything independent of the game (debug switches, techniques, platform behaviour) also goes
  into the matching shared or platform doc.
- Keep `docs/14-port-status.md` current as work progresses, using its existing format. Mirror/update the
  guide's status document only when a major milestone is reached; use the guide's existing Conker status or
  logbook file if it has no separate status file.
- When this file changes, copy its full contents to an existing Codex/Cortex equivalent instruction file,
  if one exists. Do not create a second instructions file solely for this copy.
