#!/usr/bin/env bash
# GreenNode AgentBase — Billing helpers (POC wallet eligibility).
# Usage: bash .claude/skills/agentbase/scripts/billing.sh <action> [options]

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/lib/config.sh"
source "$SCRIPTS_DIR/lib/common.sh"

ACTION="${1:-help}"; shift 2>/dev/null || true
ARGS=()
while IFS= read -r line; do ARGS+=("$line"); done < <(parse_flags "$@")
if [ ${#ARGS[@]} -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

can_use_poc() {
  local elig
  if ! elig=$(runtime_can_use_poc); then
    echo "ERROR: could not determine POC wallet eligibility (see message above)." >&2
    exit 1
  fi
  # Normalised shape so callers can jq '.canUseRuntimePoc' regardless of API envelope.
  jq -nc --argjson v "$elig" '{canUseRuntimePoc: $v}'
}

do_help() {
  show_help ".claude/skills/agentbase/scripts/billing.sh" \
    "GreenNode AgentBase billing helpers (POC wallet eligibility for runtime/openclaw)." \
    "  can-use-poc   Check whether the current user may bill runtime/openclaw resources
                 against the POC wallet. Prints {\"canUseRuntimePoc\": true|false}.
                 Exit 1 if the eligibility check itself fails."
}

case "$ACTION" in
  can-use-poc) can_use_poc ;;
  help)        do_help ;;
  *)           echo "ERROR: Unknown action '$ACTION'. Run with 'help' for usage." >&2; exit 1 ;;
esac
