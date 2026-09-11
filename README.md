# ci-templates

Reusable GitHub Actions CI layers that every repo under `chefcai` can
compose into its own thin `ci.yml`, instead of rebuilding scanning and
toolchain configuration by hand each time. Everything here uses free
tooling only.

Extracted from `chefcai/anya-qr`'s original inline `ci.yml`, which is the
proven reference implementation this generalizes.

## Architecture: layers, not one workflow

Each concern is its own reusable workflow file. A consuming repo's `ci.yml`
is a list of jobs, each `uses:`-ing whichever layers apply to it — not one
job calling one workflow with a `language` input.

```
.github/workflows/baseline.yml        always: gitleaks + Trivy fs/config. No language input, ever.
.github/workflows/docker.yml          conditional: build -> scan -> push. No language input.
.github/workflows/a11y.yml            opt-in: pa11y/Puppeteer. Caller supplies commands, not this file.
.github/workflows/go.yml              language layer: test (vet+race) + security (govulncheck+gosec)
.github/workflows/php.yml             language layer: phpunit + composer audit + psalm
.github/workflows/kotlin.yml          language layer: gradle test/build + detekt
.github/workflows/bash.yml            language layer: shellcheck (+ optional test-cmd)
.github/workflows/iac.yml             IaC layer: checkov (Terraform/CloudFormation/Ansible/OpenAPI/Helm/K8s/...) + terraform fmt/validate + cfn-lint
```

A Dockerfile-only repo (nothing but a Dockerfile, no application source)
needs **no language layer at all** — `baseline.yml` + `docker.yml` already
cover everything there is to scan.

Why split it this way rather than one file with more `language ==` branches:
a change to the Python layer (once it exists) cannot break the Go layer,
because they're not the same file and share no conditional logic. Each
layer is independently readable — `baseline.yml` has zero language noise in
it and never will.

Cross-layer *values* (not just pass/fail gating, an actual output one layer
hands to another) aren't solved by this split automatically — see
[#6](https://github.com/chefcai/ci-templates/issues/6) if a layer ever needs
to pass a value to another rather than just gating on `needs:`.

## 0. Adopting this in a new repo

A consuming repo's `ci.yml` composes the layers it needs. Example for a Go
repo with a Dockerfile and a web UI (this is `anya-qr`'s shape):

```yaml
name: ci
on:
  push: { branches: [main], tags: ["v*"] }
  pull_request: { branches: [main] }

jobs:
  baseline:
    permissions: { contents: read, pull-requests: write }
    uses: chefcai/ci-templates/.github/workflows/baseline.yml@main
    with:
      trivy-skip-dirs: tools/a11y

  go:
    uses: chefcai/ci-templates/.github/workflows/go.yml@main
    with:
      go-version-file: go.mod

  docker:
    needs: [baseline, go]
    permissions: { contents: read, packages: write }
    uses: chefcai/ci-templates/.github/workflows/docker.yml@main
    with:
      platforms: linux/amd64,linux/arm64

  a11y:
    needs: [go]
    uses: chefcai/ci-templates/.github/workflows/a11y.yml@main
    with:
      language: go
      a11y-build-cmd: "go build -o app ./cmd/app"
      a11y-start-cmd: "PORT=8090 ./app &"
      a11y-healthcheck-url: "http://127.0.0.1:8090/healthz"
      a11y-base-url: "http://127.0.0.1:8090"
```

A Dockerfile-only repo's whole `ci.yml` is just the `baseline` and `docker`
jobs above — no language job at all.

`scripts/new-repo-init.sh` generates the `dependabot.yml` half of adoption
(can't be centralized — Dependabot config must live in each repo); it does
not yet generate the `ci.yml` job list above, since which layers apply is a
per-repo judgment call (see the script's own `--help`).

## 1. `baseline.yml` — always on, no language input

| Tool | Purpose | Blocking? | Gotcha encoded here |
|---|---|---|---|
| `gitleaks` | secret scanning | input `gitleaks-blocking` (default report-only) | job carries `pull-requests: write` — without it, `gitleaks-action` 403s listing PR commits and, under `continue-on-error`, looks like a pass |
| Trivy `fs` | dependency + Dockerfile/Terraform/CloudFormation config scan | input `trivy-fs-blocking` (default report-only) | `scanners: vuln,config` set explicitly — the fs default is vuln-only and silently skips misconfiguration checks otherwise |

This file will never gain a `language` input. If a change to it ever seems
to need one, that change belongs in a language layer instead.

## 2. Language layers — `test` + language-specific `security`

Each layer runs its own `test` job (build/vet/test — inherently
language-specific, no way around this) and, where the language has one, a
`security` job for tools that are genuinely language-specific. Anything
`baseline.yml` already covers (secrets, dependency/config scanning) is
never duplicated in a language layer.

| Language | Status | `test` | Language-specific `security` |
|---|---|---|---|
| Go | proven (`anya-qr`) | `go vet` + `go test -race` | `govulncheck` (always blocking — call-graph aware, installed manually, never `golang/govulncheck-action`, see gotcha below) + `gosec` (input-gated blocking) |
| PHP | written for `anamanta-kythings`, unvalidated | caller-supplied `test-cmd` (default `composer test`) | `composer audit` (known-vuln, free, built into Composer) + `psalm --taint-analysis` (SAST, built into Psalm, no separate plugin needed) |
| Kotlin/JVM | written for `launcher`, unvalidated | `./gradlew test` + `./gradlew build` (Android SDK setup is opt-in via `is-android`) | `detekt` covers both lint and SAST — no second tool needed the way Go needs gosec alongside `go vet` |
| Bash | written ahead of need, unvalidated | `shellcheck` (ships preinstalled on GitHub-hosted runners) + optional caller `test-cmd` | none — no known-vuln-scanner equivalent exists for shell scripts; `baseline.yml`'s gitleaks/Trivy already cover secrets and any embedded Dockerfile |
| Dockerfile-only (no app source) | proven pattern, no file needed | n/a | n/a — `baseline.yml` + `docker.yml` alone are the whole pipeline |

`iac.yml` isn't in this table because it isn't gated by a `language` input the way the rows above are — it auto-detects what's present and applies to any repo with infrastructure-as-code files, alongside whichever application-language row also applies. See "3. `iac.yml`" below.

**Known gotcha every language layer must respect:** `actions/setup-go@v7`
(and presumably future major bumps of other language setup actions)
changed toolchain-resolution defaults in a way that broke a live `go
install` step mid-pipeline. Any step that installs a tool at runtime
(`go install ...@latest`, `pip install ...`, `composer require --dev ...`,
etc.) should pin its own toolchain-resolution behavior explicitly rather
than trusting the setup action's current default — `go.yml`'s
`govulncheck` step does this with `GOTOOLCHAIN: auto`.

**"Unvalidated" means literally that**: these files were written from the
role each tool should fill and, where verifiable, checked against the real
tool's actual behavior (e.g. `cfn-lint`'s Resources-key requirement was
confirmed by running it, not assumed) — but none has run against the real
repo it was written for yet. Treat every unvalidated layer as a draft to
fix once it actually runs, not a finished implementation.

## 3. `iac.yml` — infrastructure-as-code, auto-detected

Unlike the language layers above, this file takes no `language` input and
isn't opted into per-repo — it composes into `ci.yml` alongside whichever
application-language layer applies (or on its own, for an infra-only repo),
and each of its jobs detects for itself whether there's anything to do.

| Job | Covers | Blocking? | Notes |
|---|---|---|---|
| `checkov` | Terraform, CloudFormation, Ansible, OpenAPI/Serverless, Helm, Kubernetes, Dockerfiles, and everything else checkov supports | input `checkov-blocking` (default report-only) | One unscoped scan (`directory: .`) — checkov auto-detects every framework it understands in a single pass, so this isn't duplicated per language the way it briefly was when `terraform.yml` and `cloudformation.yml` were separate files. This is on top of, not instead of, baseline.yml's Trivy `config` scan — checkov's policy set is broader/IaC-specific. |
| `terraform-fmt-validate` | Terraform correctness | always blocking (fmt/validate are correctness, not security) | Auto-detects `.tf` files under `terraform-dir` (default `.`) and skips cleanly if there are none — safe to include in a repo with no Terraform at all. |
| `cfn-lint` | CloudFormation correctness | input `cfn-lint-blocking` (default report-only) | Auto-detects template files by checking for a top-level `Resources:`/`"Resources"` key across `**/*.yaml`, `**/*.yml`, `**/*.json` — the same structural check CloudFormation and checkov themselves use to recognize a template. Verified directly (not assumed) that `cfn-lint` errors loudly on any yaml/json lacking that key, so this can't safely default to scanning "everything" the way Trivy can; an optional `cfn-lint-glob` input overrides auto-detection for edge cases. Checkov's own JSON/SARIF output was tested and rejected as a source for this file list — both formats only list files that triggered at least one check result, so a valid CFN file using only resource types checkov has no check for would silently vanish from it. |

Written ahead of need — no repo in this account is primarily
infrastructure-as-code today. Unvalidated in the same sense as the other
ahead-of-need layers (see below): checked against real tool behavior where
verifiable, but not yet run against a real consuming repo.

## 4. `a11y.yml` — opt-in, web-facing repos only

`pa11y` + Puppeteer against a locally built-and-seeded instance of the app
— not a static file. Both light and dark mode are covered by having your
scan command call Puppeteer's `page.emulateMediaFeatures()` before handing
the page to pa11y, rather than running the scanner twice. `anya-qr`'s
`tools/a11y/scan.js` is the reference implementation of that pattern.

Wire it up with these inputs (all just shell commands/URLs — the layer
doesn't know or care what your app is, except for one toolchain-setup step
that still needs to know what to install):

- `language` — which toolchain to install before building (only `go` today)
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

## 5. `docker.yml` — conditional, no language input

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
`docker.yml` itself can enforce, it's a Dockerfile-authoring convention.

## 6. Report-only → blocking graduation process

Every scanner except `govulncheck` (always blocking — it's call-graph-aware
and any Go finding is real) starts as **report-only**
(`continue-on-error: true` / Trivy `exit-code: "0"`) so the first pipeline
run on a new repo doesn't fail on a backlog of pre-existing findings.

To graduate a scanner to blocking:

1. Triage its current findings to zero, or explicitly accept-and-document
   any you're not going to fix (see "Accepting a finding" below).
2. Flip its `*-blocking` input to `true` in the consuming repo's `ci.yml`.
3. Track the graduation as its own commit/PR so there's a record of when
   and why (see `anya-qr` PR history, e.g. "Blocking as of #13" comments,
   and issue #40/#43 for a real gosec triage-then-graduate example).

### Accepting a finding

Use Trivy's `trivy-skip-dirs` input (on `baseline.yml`) to exclude a path
with a **documented**, no-fix-available finding — never to silently
suppress something. `anya-qr` excludes `tools/a11y` (a CI-only scanner
dependency, not shipped in the app or its image) for two HIGH CVEs in a
transitive `extract-zip` dependency with no upstream fix, tracked in that
repo's issues #25/#27. Comment the `ci.yml` input with the same rationale +
issue link whenever you do this. `gosec`'s `#nosec` comments (see
`anya-qr`#43) are the equivalent pattern for a single line rather than a
whole path.

## 7. Adding a new language

1. Add a new `.github/workflows/<language>.yml` reusable workflow with its
   own `test` job and, if the language has genuinely language-specific
   security tooling, its own `security` job. Do not touch `baseline.yml`,
   `docker.yml`, or `a11y.yml` — none of them take a `language` input and
   none of them should.
2. Substitute the same *role*, not the same tool, and check what
   `baseline.yml`'s Trivy `fs` scan already covers before reaching for a
   new tool — it reads lockfiles across several ecosystems already, so
   known-vuln scanning in particular may need nothing new.
3. Onboard exactly one real repo before trusting the layer — every
   language layer in this repo that predates a real repo running it is
   marked "unvalidated" in the table above; flip that once it's proven.
4. If the language needs a Dependabot ecosystem entry, add it to
   `scripts/new-repo-init.sh`'s ecosystem-name mapping.

## Repository layout

```
.github/workflows/baseline.yml        gitleaks + Trivy fs/config (always, no language input)
.github/workflows/docker.yml          docker-setup/docker-scan/docker-push (conditional, no language input)
.github/workflows/a11y.yml            pa11y/Puppeteer (opt-in)
.github/workflows/go.yml              Go language layer
.github/workflows/php.yml             PHP language layer (unvalidated)
.github/workflows/kotlin.yml          Kotlin/JVM language layer (unvalidated)
.github/workflows/bash.yml            Bash language layer (unvalidated)
.github/workflows/iac.yml             IaC layer: checkov + terraform fmt/validate + cfn-lint, auto-detected (unvalidated)
examples/ci.yml.go-minimal.yml        thin wrapper: go, no docker, no a11y
examples/ci.yml.go-full.yml           thin wrapper: go + docker + a11y (anya-qr's shape)
examples/dependabot.yml.go-docker     dependabot.yml with gomod + docker + github-actions
scripts/new-repo-init.sh              bootstrap script for dependabot.yml
```
