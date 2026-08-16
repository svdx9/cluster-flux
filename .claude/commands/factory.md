---
description: Run the full 7-agent software factory pipeline for a feature request, end to end.
argument-hint: <feature description>
---

You are orchestrating the software factory pipeline for this feature
request:

> $ARGUMENTS

Run the seven stages below **in order**, using the Task tool to invoke
each named subagent. Do not skip a stage and do not let a builder agent
start before the spec is written. This command is the only place file
persistence for planning artifacts happens -- the read-only agents
(codebase-researcher, story-writer, spec-writer, test-verifier,
implementation-validator) return text; you are responsible for writing
that text to disk yourself with the Write tool.

## 0. Set up the workspace

Derive a short kebab-case slug from the feature request (e.g. "Add CSV
export to the reports page" -> `csv-export-reports`). Create
`.claude/factory/<slug>/` and write every stage's output there as you go,
so the pipeline's paper trail survives even if a later stage fails.

## 1. codebase-researcher (haiku, read-only)

Invoke the `codebase-researcher` subagent with the feature request. Save
its full report to `.claude/factory/<slug>/research.md`.

## 2. story-writer (sonnet, read-only)

Invoke the `story-writer` subagent with the feature request and the
research report. Save its output to `.claude/factory/<slug>/stories.md`.

If story-writer flagged open questions that block writing acceptance
criteria, stop here and ask the user rather than guessing.

## 3. spec-writer (sonnet, read-only)

Invoke the `spec-writer` subagent with the stories and the research
report. Save its output to `.claude/factory/<slug>/spec.md`.

## 4. backend-builder and frontend-builder (sonnet, full write access)

Invoke both subagents, each with the full spec. They can run in parallel
since the spec is the shared contract between them -- invoke them in the
same message with two Task calls if the request has both a backend and a
frontend component. If it's backend-only or frontend-only per the spec's
file plan, invoke only the relevant one.

Save each builder's final report to `.claude/factory/<slug>/backend-report.md`
and/or `.claude/factory/<slug>/frontend-report.md`.

If either builder reports something blocked or a deviation from spec that
matters, surface it to the user before continuing -- don't paper over it
by proceeding to verification anyway.

## 5. test-verifier (sonnet, Bash for running tests, no Edit)

Invoke the `test-verifier` subagent, pointing it at the spec's test plan
and the stories' acceptance criteria. Save its report to
`.claude/factory/<slug>/test-report.md`.

If the verdict is FAIL: report the failures to the user. Do not
automatically loop builder -> verifier more than twice without checking in
-- a persistent failure after two fix attempts usually means the spec
itself needs revisiting, not another blind implementation attempt.

## 6. implementation-validator (sonnet, Bash for inspection, no Edit)

Only run this once test-verifier's verdict is PASS. Invoke the
`implementation-validator` subagent with the stories, spec, and both
builder reports. Save its report to `.claude/factory/<slug>/validation.md`.

If the verdict is SEND BACK: report exactly what implementation-validator
flagged and which builder owns it, and re-invoke that builder with the
specific feedback. Re-run test-verifier and implementation-validator after
the fix.

## 7. Summarize

Once implementation-validator returns APPROVE, give the user a short
summary: what was built, which files changed, and a reminder that nothing
has been committed -- committing is a manual `git commit`, which the
`pre-commit-secrets-scan.sh` hook will screen for accidentally staged
secrets before it goes through.
