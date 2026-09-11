#!/usr/bin/env bash
# Bootstrap a new repo's Dependabot config for chefcai/ci-templates.
# Run from the root of the target repo (where .git lives).
#
# Usage:
#   new-repo-init.sh --language go [--dockerfile]
#
# Drops in:
#   .github/dependabot.yml   (cannot be centralized - must live in each repo)
#
# This script does NOT generate .github/workflows/ci.yml. Which layers
# (baseline/docker/a11y/<language>) apply is a per-repo judgment call -
# see README.md "0. Adopting this in a new repo" and examples/ for worked
# ci.yml examples to copy and adjust instead.
set -euo pipefail

LANGUAGE="go"
HAS_DOCKERFILE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --language) LANGUAGE="$2"; shift 2 ;;
    --dockerfile) HAS_DOCKERFILE=true; shift ;;
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

mkdir -p .github

# Dependabot ecosystem per language. Empty means "no package-manager
# ecosystem for this language" (e.g. bash/CloudFormation have no lockfile
# concept) - only the always-present docker/github-actions entries apply.
case "$LANGUAGE" in
  go) ECOSYSTEM="gomod" ;;
  node|typescript|javascript) ECOSYSTEM="npm" ;;
  python) ECOSYSTEM="pip" ;;
  php) ECOSYSTEM="composer" ;;
  kotlin|java) ECOSYSTEM="gradle" ;;
  terraform) ECOSYSTEM="terraform" ;;
  bash|cloudformation) ECOSYSTEM="" ;;
  *) ECOSYSTEM="$LANGUAGE" ;;
esac

{
  echo "version: 2"
  echo "updates:"
  if [[ -n "$ECOSYSTEM" ]]; then
    echo "  - package-ecosystem: \"$ECOSYSTEM\""
    echo "    directory: \"/\""
    echo "    schedule:"
    echo "      interval: \"weekly\""
    echo "    open-pull-requests-limit: 10"
    echo "    labels:"
    echo "      - \"dependencies\""
    echo "      - \"security\""
    echo
  fi
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

echo "Wrote .github/dependabot.yml"
echo
echo "Next: write .github/workflows/ci.yml by hand, composing the layers this"
echo "repo needs (baseline always; docker if it ships a container; a11y if"
echo "it's web-facing; a language layer if one exists for '$LANGUAGE') -"
echo "see README.md '0. Adopting this in a new repo' and examples/ for"
echo "worked examples to copy and adjust. Then:"
echo "  git add .github && git commit -m 'ci: adopt chefcai/ci-templates' && git push"
