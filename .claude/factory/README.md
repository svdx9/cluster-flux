# Factory run artifacts

`/factory` (see `.claude/commands/factory.md`) writes each pipeline run's
planning artifacts here, under a slug derived from the feature request:

```
.claude/factory/<feature-slug>/
  research.md          # codebase-researcher's report
  stories.md            # story-writer's user stories
  spec.md               # spec-writer's technical spec
  backend-report.md     # backend-builder's final report (if applicable)
  frontend-report.md    # frontend-builder's final report (if applicable)
  test-report.md        # test-verifier's pass/fail report
  validation.md          # implementation-validator's approve/send-back report
```

This is the paper trail for what each agent decided and why, kept next to
the code change it produced. It's ordinary version-controlled markdown --
review it, diff it, or delete a run's directory once its PR has merged.
