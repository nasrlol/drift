# Instructions for agents and new contributors

Read these three files before you change anything:

- rules.txt: how we write code. Every rule applies to you.
- notes.txt: what is already built and how it works.
- todo.txt: the plan, split per person.

## Workflow

1. Always pull main first: `git checkout main && git pull origin main`. Others change World and shared
   files often, so start from the latest main, never from an old local copy.
2. Pick one unclaimed item in todo.txt. Claim it: `[~] yourname: task`. Work on that item only.
3. Work on a branch made from that fresh main: `yourname/short-topic`. Never commit to main.
4. Keep the change small. One todo item per pull request.
5. Before committing: `./format.sh`, `./check.sh`, `./compile.sh debug`. The pre-commit hook runs them too.
6. Never skip the hook (`--no-verify`). If a check fails, fix the code, not the check.
7. Before pushing or opening the pull request, pull main again: `git fetch origin && git merge origin/main`.
   Fix any conflicts on your branch, rebuild and rerun the tests, then push.
8. When done: tick the item in todo.txt, describe what was built in notes.txt.

## Do not change without a human owner's approval

rules.txt, AGENTS.md, .github/, .githooks/, compile.sh, check.sh, format.sh,
benchmark budgets, expected test results in test/.
If a test or budget fails, report it. Do not update the expected values to make it pass.

## Missing something? Ask, never guess

Hard rule. It overrides every deadline.

If a dependency, API, data source, file, access right, constant, unit or design decision you need
is missing, unclear or contradicts notes.txt or the spec:

1. Open a question issue for nasr (GitHub nasrlol, owner of every question). Your human runs it,
   or you run it if you have gh. Use .github/ISSUE_TEMPLATE/question.md. nasr only sees the text,
   so write it for a person who has not seen your branch:
   - Title: the question itself, in plain words, ending with "?".
   - Context: one or two sentences on what you are building and why you need this.
   - One question per issue, answerable in one line: a value, yes / no, or a letter.
   - Options A / B, with your pick and why. Implement none of them before the answer.
   - Code: paste the lines that matter in the issue itself, as a short ```odin block (max about ten
     lines) with file:line above it, so nasr can answer from the text alone. Do this for the
     BLOCKED marker, the code that needs the answer, and the spec or notes.txt line if any. Put a
     permalink under each block. Push your branch first, then build it:
     `echo "https://github.com/nasrlol/drift/blob/$(git rev-parse HEAD)/<file>#L<from>-L<to>"`
   - Short: about ten lines plus links. No logs, no long code, no tool or agent names.

       gh issue create --repo nasrlol/drift --label question --assignee nasrlol \
         --title "Question: <what is missing>" --body-file <file>

   Where gh has no GraphQL (some cloud agent sessions), use the REST call:

       gh api repos/nasrlol/drift/issues -f title="Question: <what is missing>" \
         -F body=@<file> -f 'labels[]=question' -f 'assignees[]=nasrlol'

2. Mark the spot in the code: `// BLOCKED: #NN <one line>`. Leave it open (a failing test or a
   compile error), never filled with a guess. CI fails while a BLOCKED marker exists, so it cannot
   reach main.
3. Note it on the todo item: `[~] yourname: task (waiting: #NN)`.
4. Keep building everything that does not depend on the missing piece.
5. nasr answers in the issue. That answer is the only source: not a chat, not a guess.

Before you work in a file, look for open questions: `git grep -n 'BLOCKED: #' -- '*.odin'`.
For each marker, read its issue:

    gh issue view NN --repo nasrlol/drift --comments
    gh api repos/nasrlol/drift/issues/NN/comments --jq '.[] | .user.login + ": " + .body'

No answer from nasr yet: leave the marker and work around it as in step 4. An answer from nasr:

1. Write it into notes.txt or a constant in the owning file, never only in the issue.
2. Fill the spot from there, remove the marker, run the tests.
3. Close the issue with a comment that names the commit.

Never, to get around a missing piece:
- hardcode values (coordinates, sizes, speeds, keys, paths) that belong to another system or come
  from outside
- copy a constant from another file instead of importing or deriving it
- write a stub or fake data that is not fixture data from test/data
- guess a signature, unit or file format that someone else owns

Building on an unmerged branch or pull request is fine. Write "Built on #NN" in your pull request,
merge the base again whenever it changes, and fix review feedback on the base before you add more
on top.

A shared value has one home. Use it from there or derive it, with `#assert` when it must match
another value.

Every pull request fills in the "Assumptions" section of the template: each value or decision that
does not come from the code, notes.txt or the spec. "None" is a valid answer, an empty section is
not.

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

- Odin only. Allowed imports: core:*, base:*, vendor:raylib (and its rlgl module, vendor:raylib/rlgl), vendor:curl,
  our own packages.
- Simulation code (terrain, weather, route, ship, nav) never imports raylib.
- No map iteration, no wall-clock time, no threads, no unseeded randomness in simulation code.
- No new files named utils, helpers, common, types or misc. No test files outside test/.
- No allocation outside the arenas in World. No globals in the game package.
- Plain ASCII. No comments that restate the code.
