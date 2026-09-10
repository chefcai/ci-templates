# ci-templates

A reusable GitHub Actions CI pipeline (`test` / `security` / optional `a11y`
/ optional `docker`) that every repo under `chefcai` can adopt as a thin
wrapper, instead of rebuilding scanning and toolchain configuration by hand
each time. Everything here uses free tooling only.

Extracted from `chefcai/anya-qr`'s original inline `ci.yml`, which is the
proven reference implementation this generalizes. Currently **Go-only** —
see [6. Adding a new language](#6-adding-a-new-language) before onboarding a
non-Go repo.

## 0. Adopting this in a new repo (under 10 minutes)

From the root of the target repo:

```sh
curl -sSL https://raw.githubusercontent.com/chefcai/ci-templates/main/scripts/new-repo-init.sh -o /tmp/new-repo-init.sh
chmod +x /tmp/new-repo-init.sh
/tmp/new-repo-init.sh --language go [--dockerfile] [--a11y]
```

This drops in:
- `.github/dependabot.yml` — can't be centralized, must live in each repo
- `.github/workflows/ci.yml` — a thin wrapper that calls this repo's
  `standard-ci.yml` via `workflow_call`

If you passed `--a11y`, fill in the `TODO` a11y-`*`-cmd values it left in
`ci.yml` (see `examples/ci.yml.go-full.yml` for a worked example from
`anya-qr`). Commit, push, done.

## 1. Stages

### `test`

Native vet/lint + native test runner in strict/race mode, gating everything
except `security` (which runs in parallel for speed, matching `anya-qr`).

| Language | vet/lint | test |
|---|---|---|
| Go | `go vet ./...` | `go test -race ./...` |

An optional `build-cmd` input runs an extra build-verification step if the
repo needs one beyond what `security`/`a11y`/`docker` already exercise.

### 2. `security`

| Tool | Purpose | Blocking? | Gotcha encoded here |
|---|---|---|---|
| `govulncheck` | known-vuln scan of stdlib + deps | always | installed and run manually — **never** `golang/govulncheck-action`, whose internal `setup-go` silently overrides the pinned Go version and can mask real findings; the step also pins `GOTOOLCHAIN: auto` itself rather than trusting `actions/setup-go`'s current default |
| `gosec` | Go SAST | input `gosec-blocking` (default report-only) | — |
| `gitleaks` | secret scanning | input `gitleaks-blocking` (default report-only) | job carries `pull-requests: write` — without it, `gitleaks-action` 403s listing PR commits and, under `continue-on-error`, looks like a pass |
| Trivy `fs` | dependency + Dockerfile/IaC config scan | input `trivy-fs-blocking` (default report-only) | `scanners: vuln,config` set explicitly — the fs default is vuln-only and silently skips Dockerfile checks otherwise |
| Trivy `image` (if `has-dockerfile`) | vulnerabilities baked into the built image | input `trivy-image-blocking` (default report-only) | scans the image just built in the same job (`load: true, push: false`), before any push |
| Dependabot | automated dependency PRs | N/A | one entry per ecosystem, always including `github-actions` |

### 3. `a11y` (manual opt-in, web-facing repos only)

`pa11y` + Puppeteer against a locally built-and-seeded instance of the app —
not a static file. Both light and dark mode are covered by having your scan
command call Puppeteer's `page.emulateMediaFeatures()` before handing the
page to pa11y, rather than running the scanner twice. `anya-qr`'s
`tools/a11y/scan.js` is the reference implementation of that pattern.

Wire it up with these inputs (all just shell commands/URLs — the reusable
workflow doesn't know or care what your app is):

- `a11y-build-cmd` — builds the app under test
- `a11y-start-cmd` — starts it in the background (must return immediately,
  end it with `&`)
- `a11y-healthcheck-url` — polled until 2xx before scanning
- `a11y-seed-cmd` — optional, seeds data into the running app
- `a11y-install-cmd` — installs the scanner's own deps (default: `npm ci
  --prefix tools/a11y`)
- `a11y-scan-cmd` — runs the actual scan (default: `node tools/a11y/scan.js`)
- `a11y-base-url-env` / `a11y-base-url` — the env var name and value your
  scan command reads the app's URL from

`a11y-blocking` (default `false`) graduates it once the initial findings
backlog is fixed.

### 4. `docker` (conditional, `has-dockerfile: true`)

Never pushes an unscanned image:

1. `docker-setup` — turns the `platforms` input into a matrix and resolves
   the image name.
2. `docker-scan` — for **each** platform separately: `build-push-action`
   with `load: true, push: false`, then a Trivy image scan on that tag.
   (`buildx --load` cannot load a multi-platform manifest as one local
   image, so this can't be done as a single combined build.)
3. `docker-push` — one final `push: true` build with all platforms combined
   into a manifest list, run only after every per-platform scan has
   completed. Runs a report-image-size step after.

For a Go image, cross-compile via `FROM --platform=$BUILDPLATFORM ... ARG
TARGETOS TARGETARCH` in the Dockerfile instead of relying on QEMU emulation
— meaningfully faster since only the final `COPY`-only stage varies by
platform. See `anya-qr`'s `Dockerfile` for the pattern; this isn't something
the workflow itself can enforce, it's a Dockerfile-authoring convention.

## 5. Report-only → blocking graduation process

Every scanner except `govulncheck` (always blocking — it's call-graph-aware
and any Go finding is real) starts as **report-only**
(`continue-on-error: true` / Trivy `exit-code: "0"`) so the first pipeline
run on a new repo doesn't fail on a backlog of pre-existing findings.

To graduate a scanner to blocking:

1. Triage its current findings to zero, or explicitly accept-and-document
   any you're not going to fix (see "Accepting a finding" below).
2. Flip its `*-blocking` input to `true` in the consuming repo's `ci.yml`.
3. Track the graduation as its own commit/PR so there's a record of when
   and why (see `anya-qr` PR history, e.g. "Blocking as of #13" comments).

### Accepting a finding

Use Trivy's `trivy-skip-dirs` input to exclude a path with a **documented**,
no-fix-available finding — never to silently suppress something. `anya-qr`
excludes `tools/a11y` (a CI-only scanner dependency, not shipped in the app
or its image) for two HIGH CVEs in a transitive `extract-zip` dependency
with no upstream fix, tracked in that repo's issues #25/#27. Comment the
`ci.yml` input with the same rationale + issue link whenever you do this.

## 6. Adding a new language

Go is the only proven implementation. To add another language:

1. Add a branch to each Go-specific step in `.github/workflows/
   standard-ci.yml` guarded by `inputs.language == '<lang>'` (the `test` and
   `security` jobs' top-level `if` will need to become an `||` of every
   supported language, and `unsupported-language`'s `if` the inverse).
2. Substitute the same *role*, not the same tool:

   | Role | Go (proven) | Node/TypeScript | Python |
   |---|---|---|---|
   | Known-vuln scan | `govulncheck` | `npm audit` / `osv-scanner` | `pip-audit` |
   | SAST | `gosec` | `eslint` security plugin set / `semgrep` (free tier) | `bandit` |
   | Secret scan | `gitleaks` | `gitleaks` (unchanged) | `gitleaks` (unchanged) |
   | Dependency/config scan | Trivy `fs` | Trivy `fs` (unchanged) | Trivy `fs` (unchanged) |
   | Dependabot ecosystem | `gomod` | `npm` | `pip` |

   Trivy and gitleaks are already language-agnostic — don't touch those
   branches. Only the known-vuln scanner and SAST tool need a real
   per-language step.
3. Onboard exactly one real repo in that language before generalizing
   further — don't invent config for a language nothing here actually
   exercises yet. This table is meant to grow one proven row at a time.
4. Update `scripts/new-repo-init.sh`'s ecosystem-name `case` if the new
   language's Dependabot ecosystem name differs from its `--language` flag
   value.

## Repository layout

```
.github/workflows/standard-ci.yml   the reusable workflow (workflow_call)
examples/ci.yml.go-minimal.yml      thin wrapper: go, no docker, no a11y
examples/ci.yml.go-full.yml         thin wrapper: go + docker + a11y (anya-qr's shape)
examples/dependabot.yml.go-docker   dependabot.yml with gomod + docker + github-actions
scripts/new-repo-init.sh            bootstrap script, see section 0
```
