# conker-nx — notes for Claude

Nintendo Switch port of Conker: Live & Reloaded (original Xbox) by static recompilation.

Documentation lives in the separate repo `../nx-port-guide` (start with its `README.md`; Conker material in
`platforms/xbox/conker/`, living log `conker-logbook.md`). This repo has no `docs/` folder.

## Rules

- **Never add Claude as a co-author.** No `Co-Authored-By: Claude ...` trailer in commit messages, and no
  "Generated with Claude Code" line in pull request descriptions.
- Never commit game data (disc images, extracted files, `default.xbe`) or generated C (`gen/`).
- Every finding and log goes to `../nx-port-guide`, in an existing file whenever one fits; create a new file
  there only if nothing fits. Game-specific content goes under the game's folder; anything independent of the
  game (debug switches, techniques, platform behaviour) goes into the matching shared or platform doc too.
