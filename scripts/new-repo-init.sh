#!/usr/bin/env bash
# Bootstrap a new repo onto chefcai/ci-templates' standard CI pipeline.
# Run from the root of the target repo (where .git lives).
#
# Usage:
#   new-repo-init.sh --language go [--dockerfile] [--a11y] [--ref main]
#
# Drops in:
#   .github/dependabot.yml   (cannot be centralized - must live in each repo)
#   .github/workflows/ci.yml (thin wrapper calling the reusable workflow)
#
# Takes well under 10 minutes: run this, fill in the two a11y-*-cmd TODOs
# if --a11y was passed, commit, push.
set -euo pipefail

LANGUAGE="go"
HAS_DOCKERFILE=false
A11Y=false
REF="main"
TEMPLATES_REPO="chefcai/ci-templates"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --language) LANGUAGE="$2"; shift 2 ;;
    --dockerfile) HAS_DOCKERFILE=true; shift ;;
    --a11y) A11Y=true; shift ;;
    --ref) REF="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d .git ]]; then
  echo "error: run this from the root of the target repo (no .git found here)" >&2
  exit 1
fi

if [[ "$LANGUAGE" != "go" ]]; then
  echo "warning: language '$LANGUAGE' is not implemented in $TEMPLATES_REPO yet." >&2
  echo "         The generated ci.yml will fail until you add it - see README.md section 6." >&2
fi

mkdir -p .github/workflows

# --- dependabot.yml ---------------------------------------------------
case "$LANGUAGE" in
  go) ECOSYSTEM="gomod" ;;
  node|typescript|javascript) ECOSYSTEM="npm" ;;
  python) ECOSYSTEM="pip" ;;
  *) ECOSYSTEM="$LANGUAGE" ;;
esac

{
  echo "version: 2"
  echo "updates:"
  echo "  - package-ecosystem: \"$ECOSYSTEM\""
  echo "    directory: \"/\""
  echo "    schedule:"
  echo "      interval: \"weekly\""
  echo "    open-pull-requests-limit: 10"
  echo "    labels:"
  echo "      - \"dependencies\""
  echo "      - \"security\""
  echo
  if [[ "$HAS_DOCKERFILE" == "true" ]]; then
    echo "  - package-ecosystem: \"docker\""
    echo "    directory: \"/\""
    echo "    schedule:"
    echo "      interval: \"weekly\""
    echo "    labels:"
    echo "      - \"dependencies\""
    echo "      - \"security\""
    echo
  fi
  echo "  - package-ecosystem: \"github-actions\""
  echo "    directory: \"/\""
  echo "    schedule:"
  echo "      interval: \"weekly\""
  echo "    labels:"
  echo "      - \"dependencies\""
  echo "      - \"security\""
} > .github/dependabot.yml

# --- ci.yml wrapper -----------------------------------------------------
{
  echo "name: ci"
  echo
  echo "on:"
  echo "  push:"
  echo "    branches: [main]"
  echo "    tags: [\"v*\"]"
  echo "  pull_request:"
  echo "    branches: [main]"
  echo
  echo "jobs:"
  echo "  ci:"
  echo "    permissions:"
  echo "      contents: read"
  echo "      pull-requests: write"
  if [[ "$HAS_DOCKERFILE" == "true" ]]; then
    echo "      packages: write"
  fi
  echo "    uses: $TEMPLATES_REPO/.github/workflows/standard-ci.yml@$REF"
  echo "    with:"
  echo "      language: $LANGUAGE"
  if [[ "$LANGUAGE" == "go" ]]; then
    echo "      go-version-file: go.mod"
  fi
  if [[ "$HAS_DOCKERFILE" == "true" ]]; then
    echo "      has-dockerfile: true"
    echo "      platforms: linux/amd64,linux/arm64"
  fi
  if [[ "$A11Y" == "true" ]]; then
    cat <<'A11YEOF'
      a11y: true
      a11y-build-cmd: "TODO: command that builds the app under test"
      a11y-start-cmd: "TODO: command that starts it in the background, e.g. PORT=8090 ./app &"
      a11y-healthcheck-url: "TODO: e.g. http://127.0.0.1:8090/healthz"
      a11y-seed-cmd: ""
      a11y-install-cmd: "npm ci --prefix tools/a11y"
      a11y-scan-cmd: "node tools/a11y/scan.js"
      a11y-base-url-env: "A11Y_BASE_URL"
      a11y-base-url: "TODO: e.g. http://127.0.0.1:8090"
      a11y-blocking: false
A11YEOF
  fi
} > .github/workflows/ci.yml

echo "Wrote .github/dependabot.yml and .github/workflows/ci.yml"
echo
if [[ "$A11Y" == "true" ]]; then
  echo "Next: fill in the TODO a11y-*-cmd values in .github/workflows/ci.yml"
  echo "(see $TEMPLATES_REPO's README.md '3. a11y' and examples/ci.yml.go-full.yml for a worked example),"
  echo "then:"
else
  echo "Next:"
fi
echo "  git add .github && git commit -m 'ci: adopt chefcai/ci-templates standard-ci workflow' && git push"
