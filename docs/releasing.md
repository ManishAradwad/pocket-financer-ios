# Releasing Pocket Financer for iOS

Pocket Financer uses protected pull requests and Release Please as a controlled release gate. Development can continue through short-lived branches while the repository owner chooses if and when to merge the automated release pull request. TestFlight and App Store publication are deliberately outside automatic GitHub release preparation.

Executable workflow files are the final authority. Update this guide in the same pull request whenever CI or release behavior changes.

## Pull-request CI

`.github/workflows/ci.yml` runs on pull requests targeting `main`, pushes to `main`, and manual dispatches. The required job is named **Format, build, and test** and performs:

- Xcode and simulator toolchain reporting.
- Xcode project and privacy-manifest validation.
- Rejection of remote Swift packages, app networking/cloud APIs, raw SMS corpora, and signing artifacts.
- `swift-format` lint.
- An unsigned Release simulator build.
- Serial unit and UI smoke tests with coverage.
- Fourteen-day retention of the `.xcresult` bundle and JSON coverage report.

CI uses one iPhone 17 Pro simulator and disables parallel test destinations to reduce memory pressure and nondeterminism. Superseded runs for the same pull request/ref are cancelled.

## Version and release preparation

`version.txt`, `Config/Version.xcconfig`, `CHANGELOG.md`, `.release-please-manifest.json`, `release-please-config.json`, and `.github/workflows/release.yml` define the normal release flow.

- `fix:` requests a patch version.
- `feat:` requests a minor version.
- `feat!:` or a `BREAKING CHANGE:` footer requests a major version.
- Documentation, test, refactor, build, CI, and chore commits do not request a release by themselves.
- Release Please maintains one draft release pull request.
- Merging that release pull request creates a draft GitHub Release and immutable `v<version>` tag.
- The draft remains unpublished until the owner reviews and publishes it explicitly.
- GitHub does not build, sign, upload, or distribute an `.ipa`; TestFlight/App Store delivery requires a separately reviewed Apple distribution workflow.

The Release workflow uses a non-cancelling `stable-release` concurrency group. If `RELEASE_PLEASE_TOKEN` is absent, it uses the repository-scoped `GITHUB_TOKEN` and explicitly dispatches both `ci.yml` and `pr-title.yml` for the updated release-PR head, because GitHub suppresses recursive workflow events created by its built-in token.

`scripts/test.sh` defaults local coverage collection to `NO` to reduce memory and disk pressure. CI explicitly sets `ENABLE_CODE_COVERAGE=YES` before calling the same script.

## Reproducible repository controls

`.github/rulesets/main.json` is the version-controlled definition for the active `main` branch ruleset. Repository bootstrap will apply this file through the GitHub API after the named workflow checks exist, and later policy changes must update the file and the live ruleset together. Do not configure an undocumented, UI-only substitute.

The ruleset requires:

- Changes required through a pull request.
- The **Format, build, and test** and **Conventional Commit title** checks required against the latest `main`.
- Review conversations resolved before merge.
- Linear history required.
- Force pushes and branch deletion blocked.
- No routine administrator bypass.
- Zero mandatory approvals while this is a single-owner repository; required checks and resolved conversations remain the merge gate. Raise this in the versioned ruleset when a second trusted reviewer is available.

Enable squash merge and automatic deletion of merged branches. Disable merge commits and rebase merges so the Conventional Commit pull-request title remains the authoritative commit on `main`.

Set the default Actions token permission to read-only and allow Actions to create pull requests so Release Please can operate. No workflow approves its own pull request.

## Optional release token

The built-in token is supported. If repository policy later requires a dedicated identity, create a fine-grained token restricted to this repository with only the contents, issues, and pull-request access Release Please needs, then store it as `RELEASE_PLEASE_TOKEN`. Rotate it before expiry. Never print or retrieve its value while troubleshooting.

## Routine development and release

1. Create a `codex/*` branch from current `origin/main`.
2. Implement and verify a focused change.
3. Open a Conventional Commit pull request targeting `main`.
4. Wait for required CI and review, then squash-merge.
5. Release Please creates or updates its draft release pull request.
6. Continue merging other verified work while that release pull request remains open if desired.
7. When the owner wants a release, inspect its version, changelog, checks, migration impact, and physical-device validation.
8. Merge the release pull request only after explicit publication approval.
9. Verify the immutable tag and draft GitHub Release. Publish the draft manually only when its notes are correct.

Do not manually edit version/changelog files in ordinary feature branches, manufacture a replacement release pull request, create or move a `v*` tag, or upload an unreviewed binary.

## Apple signing and distribution

Personal Team development signing is local-only and unsuitable for App Store distribution. Production distribution will require an Apple Developer Program team, a stable production bundle identifier, App Store Connect application record, signing/certificate strategy, privacy disclosures, export-compliance review, and a separately designed archive/upload workflow.

Do not store certificates, `.p12` files, provisioning profiles, App Store Connect private keys, issuer IDs, key IDs, passwords, or base64-encoded signing material in the repository, Markdown, issues, logs, or chat. Before automating TestFlight, document key custody, least-privilege secret names, environment protection, exact archive/export validation, artifact retention, recovery, and revocation.

## Hotfix and bad release handling

Never patch `main`, an existing tag, or a published release in place.

For an urgent correction:

1. Create `codex/fix-<slug>` from current `origin/main`.
2. Add the smallest safe fix and regression test.
3. Open a `fix:` pull request and require normal CI.
4. Squash-merge after review.
5. Verify Release Please proposes the expected patch version.
6. Explicitly merge the release pull request only when ready to publish.

For a bad published release, preserve its tag and audit history, warn users in its release notes, and issue a higher fix-forward version. Never retarget a published tag to different bytes.

## Troubleshooting

- **No release PR:** verify a release-relevant Conventional Commit reached `main`, inspect the Release workflow, and confirm Actions may create pull requests.
- **Release PR checks do not start:** confirm the dispatch job retains `actions: write`, both required workflows accept `workflow_dispatch`, and the built-in-token fallback targets the exact release-PR head SHA/ref. If a dedicated token is present, verify only that it remains configured and valid.
- **Wrong version:** inspect squash titles and Release Please configuration. Fix the cause; do not create or move a tag manually.
- **Device-only behavior unverified:** do not present automatic ingestion or model parsing as release-ready. Complete `docs/device-validation.md` on the target iOS build first.
- **Signing or App Store setup incomplete:** a GitHub source release may remain draft. Do not improvise a distribution credential or upload path.
