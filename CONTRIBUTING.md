# Contributing to Pocket Financer

Pocket Financer handles unusually sensitive local data. Start with the invariants in `AGENTS.md` and keep every change auditable. `main` is a protected, releasable development branch; implementation belongs on a short-lived branch and pull request.

1. Update from `origin/main` and create `codex/<type>-<short-description>`, such as `codex/feat-model-transparency` or `codex/fix-duplicate-import`.
2. Run `scripts/format.sh --lint`, an unsigned Release build with `scripts/build.sh`, and `scripts/test.sh`.
3. Push the branch and open a pull request targeting `main`. Use a Conventional Commit title because the squash title becomes the commit on `main`.
4. For ingestion or persistence changes, describe crash recovery, duplicate handling, raw-evidence retention, and model-unavailable behavior.
5. For UI changes, verify Dynamic Type, VoiceOver labels, dark mode, and Reduce Motion on at least one iPhone simulator.

Never include a real transaction alert in a bug report. Replace names, identifiers, references, and amounts with synthetic data.

Use squash merge and delete the short-lived branch after merge. Do not bypass required checks or directly push feature, fix, refactor, documentation, dependency, or CI commits to `main`.

Release Please owns routine version, changelog, tag, and draft-release changes. Merging a normal pull request does not authorize publication. See `docs/releasing.md`.
