#!/usr/bin/env bash
# Configure GitHub branch rulesets for zigmark.
#
# Creates (or updates) a ruleset named "main-branch-protection" that requires
# all four CI checks to pass before merging into main or zig-* branches.
#
# Prerequisites:
#   - gh CLI authenticated with a token that has repo administration write access
#   - jq installed
#
# Usage:
#   ./scripts/setup-branch-rules.sh
#   GH_TOKEN=ghp_... ./scripts/setup-branch-rules.sh

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-sc2in/zigmark}"
RULESET_NAME="regression-protection"

# ── Required check contexts ──────────────────────────────────────────────────
# Format: "workflow_display_name / job_name"  (as shown in the GitHub UI)
# The workflow display name comes from `name:` in .github/workflows/ci.yml.
CHECKS=(
  "CI / build (x86_64-linux)"
  "CI / build (aarch64-linux)"
  "CI / wasm"
  "CI / bench-regression"
)

# Build required_status_checks JSON array
REQUIRED_CHECKS_JSON=$(printf '%s\n' "${CHECKS[@]}" \
  | jq -Rn '[inputs | {"context": .}]')

RULESET_JSON=$(jq -n \
  --arg  name   "$RULESET_NAME" \
  --argjson checks "$REQUIRED_CHECKS_JSON" \
  '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: {
      ref_name: {
        include: ["~ALL"],
        exclude: []
      }
    },
    rules: [
      {
        type: "deletion"
      },
      {
        type: "required_status_checks",
        parameters: {
          required_status_checks: $checks,
          strict_required_status_checks_policy: false,
          do_not_enforce_on_create: true
        }
      }
    ]
  }')

# ── Create or update ─────────────────────────────────────────────────────────
RULESETS_OUTPUT=$(gh api "/repos/$REPO/rulesets" \
  --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")

if [ -n "$RULESETS_OUTPUT" ] && ! printf '%s' "$RULESETS_OUTPUT" | grep -Eq '^[0-9]+$'; then
  echo "✗ Failed to look up rulesets for $REPO." >&2
  echo "  gh returned unexpected output instead of a numeric ruleset ID." >&2
  echo "  This usually means the token selected by gh lacks repository administration permission, or a different gh account is active for this shell." >&2
  printf '%s\n' "$RULESETS_OUTPUT" >&2
  exit 1
fi

EXISTING_ID="$RULESETS_OUTPUT"

if [ -n "$EXISTING_ID" ]; then
  echo "▸ Updating existing ruleset (ID $EXISTING_ID)…"
  gh api "/repos/$REPO/rulesets/$EXISTING_ID" \
    --method PUT \
    --input <(echo "$RULESET_JSON") \
    --silent
  echo "✓ Ruleset updated: $RULESET_NAME"
else
  echo "▸ Creating ruleset: $RULESET_NAME…"
  gh api "/repos/$REPO/rulesets" \
    --method POST \
    --input <(echo "$RULESET_JSON") \
    --silent
  echo "✓ Ruleset created: $RULESET_NAME"
fi

echo ""
echo "Required checks:"
printf '  • %s\n' "${CHECKS[@]}"
