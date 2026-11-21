# Instructions for agents and new contributors

Read these three files before you change anything:

- rules.txt: how we write code. Every rule applies to you.
- notes.txt: what is already built and how it works.
- todo.txt: the plan, split per person.

## Workflow

1. Pick one unclaimed item in todo.txt. Claim it: `[~] yourname: task`. Work on that item only.
2. Work on a branch: `yourname/short-topic`. Never commit to main.
3. Keep the change small (under 400 changed lines outside assets/). One todo item per pull request.
4. Before committing: `./format.sh`, `./check.sh`, `./compile.sh debug`. The pre-commit hook runs them too.
5. Never skip the hook (`--no-verify`). If a check fails, fix the code, not the check.
6. When done: tick the item in todo.txt, describe what was built in notes.txt.

## Do not change without a human owner's approval

rules.txt, AGENTS.md, .github/, .githooks/, compile.sh, check.sh, format.sh,
benchmark budgets, expected test results in test/.
If a test or budget fails, report it. Do not update the expected values to make it pass.

## Build and run

- Odin version: dev-2026-11a. Other versions are not supported.
- `./compile.sh debug` builds build/drift (host) and build/game.so (hot reloaded).
  Run `./build/drift` from the repo root, rebuild while it runs, the game reloads.
- `./compile.sh release` builds one static executable.
- Windows: `compile.bat`, `format.bat`, `check.bat` (same arguments). Needs Visual Studio Build Tools
  for Odin and Git for Windows (its sh runs the hook and the checks).
- Units: horizontal km (map space, y down), altitude m, speed m/s, energy kWh. Shared signatures in notes.txt.
- The Odin standard library source is in `$(odin root)/core`. Check real signatures there,
  do not guess APIs. Odin changes often.

## Hard limits

- Odin only. Allowed imports: core:*, base:*, vendor:raylib, vendor:curl, our own packages.
- Simulation code (terrain, weather, route, ship, nav) never imports raylib.
- No map iteration, no wall-clock time, no threads, no unseeded randomness in simulation code.
- No new files named utils, helpers, common, types or misc. No test files outside test/.
- No allocation outside the arenas in World. No globals in the game package.
- Plain ASCII. No comments that restate the code.
