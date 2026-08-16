# Software factory: unattended 7-agent build pipeline

This repo ships a Claude Code configuration (`.claude/`) that implements
the "software factory" pattern described in
[freeCodeCamp's "How to Build a Software Factory with Claude Code"](https://www.freecodecamp.org/news/how-to-build-software-factory-with-claude-code/):
a fixed pipeline of scoped subagents, each with the minimum tool
permissions its job requires, wired together with hooks so the whole
thing can run without a human clicking "allow" on every tool call.

It's a portable dev-tooling layer, not GitOps config -- point `/factory`
at any application code you're building (e.g. under `apps/`) and it walks
the request through research, planning, implementation, and validation.

## Why permissions live in files, not in your head

The common failure mode with agent pipelines is that they either need a
human babysitting every permission prompt, or someone reaches for
`--dangerously-skip-permissions` and gets an agent with unrestricted
Bash/Edit access. Neither scales to an unattended multi-agent pipeline.

The fix used here, straight from the
[permissions](https://code.claude.com/docs/en/permissions) and
[hooks](https://code.claude.com/docs/en/hooks) docs: every permission
decision is either **allow**, **deny**, or **ask**, declared in
version-controlled `.claude/settings.json`, plus a small number of hooks
that enforce policy the static permission list can't express (e.g. "block
this commit if it stages an `.env` file", which depends on runtime state,
not just the tool name).

## The seven agents

Each agent is a separate file in `.claude/agents/`. The frontmatter's
`tools:` list is enforced by Claude Code's permission system -- an agent
without `Edit` in its frontmatter cannot use Edit no matter what its
prompt says or what the conversation asks of it.

| # | Agent | Model | Tools | Role |
|---|---|---|---|---|
| 1 | `codebase-researcher` | haiku | `Read, Grep, Glob` | Read-only recon: what exists already, what conventions to follow |
| 2 | `story-writer` | sonnet | `Read, Grep, Glob` | Turns the request + research into user stories with acceptance criteria |
| 3 | `spec-writer` | sonnet | `Read, Grep, Glob` | Turns stories into an implementation-ready spec: data model, API contract, file plan, test plan |
| 4 | `backend-builder` | sonnet | `Read, Write, Edit, Bash, Grep, Glob` | Implements the backend half of the spec |
| 5 | `frontend-builder` | sonnet | `Read, Write, Edit, Bash, Grep, Glob` | Implements the frontend half of the spec |
| 6 | `test-verifier` | sonnet | `Read, Bash, Grep, Glob` | Runs the real test suite, reports pass/fail with evidence -- cannot edit code |
| 7 | `implementation-validator` | sonnet | `Read, Bash, Grep, Glob` | Final gate: diffs the change against the spec, checks for scope drift/security/quality -- cannot edit code |

Three agents (`codebase-researcher`, `story-writer`, `spec-writer`) are
strictly read-only planners: `Read, Grep, Glob` and nothing else, no
`Bash`. They think and report; they never touch the filesystem or a shell.
Two agents (`test-verifier`, `implementation-validator`) get `Bash` back
because running tests/typecheck/lint requires executing commands, but
they still don't get `Edit`/`Write` -- their job is to report problems,
not silently fix them, so a human (or the builder agent) stays in the
loop on every change. Only the two builders get the full
`Read, Write, Edit, Bash, Grep, Glob` set, and even then they're scoped by
prompt to their half of the file plan (backend vs. frontend) so they
don't collide.

`codebase-researcher` runs on Haiku because recon is high-volume and
low-judgment -- cheap and fast matters more than depth. Every other stage
runs on Sonnet, where the judgment calls (what's in scope, does this
satisfy the acceptance criteria, is this a security problem) actually
need a stronger model.

## Running it

```
/factory Add CSV export to the reports page
```

See `.claude/commands/factory.md` for the exact orchestration: it derives
a slug, creates `.claude/factory/<slug>/`, and walks research -> stories
-> spec -> (backend + frontend in parallel) -> test-verifier ->
implementation-validator, persisting every stage's output as it goes (see
`.claude/factory/README.md`). Nothing is committed automatically --
committing is a deliberate `git commit` by you or the orchestrating
session, which is exactly the moment the pre-commit hook below checks.

You can also invoke any single agent directly (`Use the spec-writer
subagent to draft a spec for ...`) if you don't want the full pipeline.

## The three hooks

All three live in `.claude/hooks/` and are wired up in
`.claude/settings.json`. See the
[hooks reference](https://code.claude.com/docs/en/hooks) for the full
event/JSON contract; the short version each script relies on:

- **PreToolUse** hooks run before a tool executes and can block it
  (exit code `2`, with the reason on stderr fed back to Claude).
- **PostToolUse** hooks run after a tool succeeds and are for side
  effects, not gating (exit `0` regardless of what they do).
- **Stop** hooks run when Claude is about to end its turn and can force
  it to keep going, guarded by the `stop_hook_active` flag in the hook's
  input so it can't loop forever.

### `pre-commit-secrets-scan.sh` -- PreToolUse, matcher `Bash`

Fires before every Bash call. When the command looks like `git commit`,
it lists staged files (`git diff --cached --name-only`) and checks their
*names* against a blocklist pattern (`.env`, `.env.*`, `*.pem`,
`secrets.json`, `*.p12`, `*.pfx`, `id_rsa`, `id_ed25519`, `.npmrc`). A
match exits `2`, which blocks the commit and shows Claude why. This repo's
`*.sops.yaml` convention (see `AGENTS.md`) is deliberately excluded --
those files are meant to be committed, encrypted.

This is a backstop, not a secret scanner -- it doesn't inspect file
contents for leaked credentials. It exists to catch the mundane case: an
agent (or a human) runs `git add .` and a stray `.env` goes along for the
ride.

### `format-after-edit.sh` -- PostToolUse, matcher `Edit|Write`

Fires after every file edit. Looks at the touched file's extension and
runs the matching formatter if it's installed (`gofmt`, `black`/`ruff
format`, `rustfmt`, `shfmt`, or `prettier` for JS/TS/JSON/MD/CSS/HTML/YAML).
Always exits `0` -- a missing or failing formatter must never block an
agent's turn, it just means that file stays unformatted for a human to
notice in review.

### `block-stop-until-checks-pass.sh` -- Stop

Fires when Claude is about to finish. Detects the project's own
verification commands (`package.json` scripts named `typecheck`/`lint`/
`test`, `Makefile` targets, `go vet`/`go test`, `ruff`/`pytest`) and runs
whichever exist. Any failure exits `2` with the trimmed output, which
blocks the stop and hands Claude the failure to fix. If nothing in the
project defines these checks, it's a silent no-op (exit `0`) -- it never
invents a check that doesn't exist.

## `settings.json`: allow / ask / deny

`.claude/settings.json` declares the default policy so the pipeline
doesn't need a human approving each tool call:

- **allow**: read-only git inspection, running the project's own
  build/test/lint scripts, safe file listing -- the bread-and-butter
  commands every stage needs constantly.
- **ask**: anything that changes shared state -- `git commit`, `git
  push`, opening/merging a PR, `kubectl apply/delete`, `flux *`, `sops *`.
  These are exactly the actions where a human should be in the loop even
  in an otherwise-unattended pipeline.
- **deny**: destructive or irreversible commands (`rm -rf /`, force
  push, `git reset --hard`, pipe-to-shell installs) and reading
  credential material directly (`.env`, `*.pem`, SSH keys, `~/.aws`,
  `~/.ssh`) regardless of which agent asks -- a scoped `tools:` allowlist
  on an agent doesn't help if the underlying Read permission itself
  hands back a private key.

Combined with the per-agent `tools:` frontmatter, this is defense in
depth: even if a prompt somehow talked a builder agent into doing
something it shouldn't, the deny list and the hooks are enforced by the
harness, not by the model choosing to comply.

## Extending this

- Add a stage: drop a new `.claude/agents/<name>.md` with scoped
  `tools:`/`model:` frontmatter, and add it to the sequence in
  `.claude/commands/factory.md`.
- Tighten policy: add patterns to `permissions.deny` /
  `permissions.ask` in `.claude/settings.json` -- no code changes needed.
- Change what "done" means: edit `block-stop-until-checks-pass.sh`'s
  detection logic if your stack's check commands aren't already covered.

## Sources

- [Configure permissions -- Claude Code Docs](https://code.claude.com/docs/en/permissions)
- [Hooks reference -- Claude Code Docs](https://code.claude.com/docs/en/hooks)
- [Automate actions with hooks -- Claude Code Docs](https://code.claude.com/docs/en/hooks-guide)
- [How to Build a Software Factory with Claude Code -- freeCodeCamp](https://www.freecodecamp.org/news/how-to-build-software-factory-with-claude-code/)
- [GitHub - aaddrick/claude-pipeline](https://github.com/aaddrick/claude-pipeline)
- [The Software Factory Playbook (gist)](https://gist.github.com/Maciejdziuba/88890d7e0eeefa5a8738bbe9fd5e20b8)
