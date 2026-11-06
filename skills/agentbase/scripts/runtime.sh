#!/usr/bin/env bash
# GreenNode AgentBase — Agent Runtime Management
# Usage: bash .claude/skills/agentbase/scripts/runtime.sh <action> [options]

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/lib/config.sh"
source "$SCRIPTS_DIR/lib/common.sh"

BASE_URL="$AGENTBASE_RUNTIME_URL/agent-runtimes"
FLAVORS_URL="$AGENTBASE_RUNTIME_URL/flavors"

# --- Parse action + common flags ---
ACTION="${1:-help}"; shift 2>/dev/null || true
parse_flags "$@"
set -- ${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}

# --- Helpers ---

# Read env file and convert to JSON object {"KEY": "VALUE", ...}
read_env_file() {
  local env_file="$1"
  if [ ! -f "$env_file" ]; then
    echo "ERROR: Env file not found: $env_file" >&2
    return 1
  fi
  # Read non-empty, non-comment lines as KEY=VALUE pairs
  jq -Rn '[inputs | select(test("^\\s*#") | not) | select(length > 0) |
    capture("^(?<key>[^=]+)=(?<val>.*)$")] |
    map({(.key): .val}) | add // {}' < "$env_file"
}

# Parse common log flags and output JSON body
build_log_body() {
  local from="" limit="" query="" from_time="" to_time="" order=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --query) query="$2"; shift 2 ;;
      --from-time) from_time="$2"; shift 2 ;;
      --to-time) to_time="$2"; shift 2 ;;
      --order) order="$2"; shift 2 ;;
      *) echo "ERROR: Unknown log option: $1" >&2; return 1 ;;
    esac
  done

  jq -n \
    --arg from "$from" \
    --arg limit "$limit" \
    --arg query "$query" \
    --arg fromTimestamp "$from_time" \
    --arg toTimestamp "$to_time" \
    --arg order "$order" \
    '{} +
     (if $from != "" then {from: ($from | tonumber)} else {} end) +
     (if $limit != "" then {limit: ($limit | tonumber)} else {} end) +
     (if $query != "" then {query: $query} else {} end) +
     (if $fromTimestamp != "" then {fromTimestamp: $fromTimestamp} else {} end) +
     (if $toTimestamp != "" then {toTimestamp: $toTimestamp} else {} end) +
     (if $order != "" then {order: $order} else {} end)'
}

# Merge a networkConfig object into the request body.
# Args: BODY_JSON MODE VPC_ID SUBNET_ID ROUTE_CIDRS_CSV
# - MODE empty: leave body unchanged (server defaults to PUBLIC).
# - MODE=PUBLIC: emit {mode: "PUBLIC"} (vpc/subnet/routes ignored).
# - MODE=VPC: vpcId AND subnetId required; routeCidrs is a comma-separated list
#   of private CIDRs (RFC 1918), optional.
build_network_config() {
  local body="$1" mode="$2" vpc_id="$3" subnet_id="$4" route_cidrs_csv="$5"

  if [ -z "$mode" ]; then
    echo "$body"
    return 0
  fi

  # Normalize and validate mode
  local mode_upper
  mode_upper=$(echo "$mode" | tr '[:lower:]' '[:upper:]')
  if [ "$mode_upper" != "PUBLIC" ] && [ "$mode_upper" != "VPC" ]; then
    echo "ERROR: --network-mode must be PUBLIC or VPC (got: $mode)" >&2
    return 1
  fi

  if [ "$mode_upper" = "VPC" ]; then
    if [ -z "$vpc_id" ] || [ -z "$subnet_id" ]; then
      echo "ERROR: --vpc-id and --subnet-id are required when --network-mode=VPC" >&2
      return 1
    fi
  fi

  # Build routeCidrs as a JSON array (split CSV; trim whitespace per item)
  local route_cidrs_json="[]"
  if [ -n "$route_cidrs_csv" ]; then
    route_cidrs_json=$(echo "$route_cidrs_csv" | jq -Rn \
      '[inputs | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)]')
  fi

  local network_json
  network_json=$(jq -n \
    --arg mode "$mode_upper" \
    --arg vpcId "$vpc_id" \
    --arg subnetId "$subnet_id" \
    --argjson routeCidrs "$route_cidrs_json" \
    '{mode: $mode, routeCidrs: $routeCidrs} +
     (if $vpcId != "" then {vpcId: $vpcId} else {} end) +
     (if $subnetId != "" then {subnetId: $subnetId} else {} end)')

  echo "$body" | jq --argjson nc "$network_json" '. + {networkConfig: $nc}'
}

# Build the inboundAuth object for create/update.
# Args: MODE JWT_FILE NETWORK_MODE EXPLICIT(true|false)
# Prints the JSON object on stdout, or nothing when inboundAuth must be omitted.
# - MODE defaults to IAM (secure by default) when not passed explicitly.
# - inboundAuth is only supported in PUBLIC network mode: in VPC mode the
#   default is dropped silently; an explicit IAM/JWT is rejected.
# - JWT requires JWT_FILE: a JSON object with the `jwt` settings
#   (source, discoveryUrl|jwks, allowedAudiences, ...).
build_inbound_auth() {
  local mode="$1" jwt_file="$2" network_mode="$3" explicit="$4"

  mode=$(echo "${mode:-IAM}" | tr '[:lower:]' '[:upper:]')
  case "$mode" in
    NONE|IAM|JWT) ;;
    *) echo "ERROR: --inbound-auth must be NONE, IAM or JWT (got: $mode)" >&2; return 1 ;;
  esac

  if [ -n "$jwt_file" ] && [ "$mode" != "JWT" ]; then
    echo "ERROR: --inbound-auth-jwt-file is only valid with --inbound-auth JWT" >&2
    return 1
  fi

  local nm_upper
  nm_upper=$(echo "${network_mode:-}" | tr '[:lower:]' '[:upper:]')
  if [ "$nm_upper" = "VPC" ]; then
    if [ "$explicit" = true ] && [ "$mode" != "NONE" ]; then
      echo "ERROR: --inbound-auth $mode is only supported in PUBLIC network mode (got --network-mode VPC)" >&2
      return 1
    fi
    return 0
  fi

  if [ "$mode" = "JWT" ]; then
    if [ -z "$jwt_file" ]; then
      echo "ERROR: --inbound-auth JWT requires --inbound-auth-jwt-file PATH" >&2
      return 1
    fi
    if [ ! -f "$jwt_file" ]; then
      echo "ERROR: JWT settings file not found: $jwt_file" >&2
      return 1
    fi
    if ! jq -e 'type == "object" and (.source == "DISCOVERY" or .source == "JWKS")' "$jwt_file" >/dev/null 2>&1; then
      echo "ERROR: JWT settings file must be a JSON object with source DISCOVERY or JWKS" >&2
      return 1
    fi
    jq -c '{mode: "JWT", jwt: .}' "$jwt_file"
    return 0
  fi

  jq -nc --arg mode "$mode" '{mode: $mode}'
}

# Read the inboundAuth of the runtime's latest version, re-shaped as a request
# object. Prints nothing when the latest version has no inboundAuth (legacy).
# Returns non-zero when the versions cannot be read.
current_inbound_auth() {
  local id="$1" first last_page versions
  first=$(REDACT_FIELDS="password" api_call GET "${BASE_URL}/${id}/versions?page=1&size=100" 2>/dev/null) || return 1
  printf '%s' "$first" | jq -e '.listData' >/dev/null 2>&1 || return 1
  versions=$(printf '%s' "$first" | jq -c '.listData')
  last_page=$(printf '%s' "$first" | jq -r '.totalPage // 1')
  if [ "$last_page" -gt 1 ] 2>/dev/null; then
    local last
    last=$(REDACT_FIELDS="password" api_call GET "${BASE_URL}/${id}/versions?page=${last_page}&size=100" 2>/dev/null) || return 1
    versions=$(jq -nc --argjson a "$versions" --argjson b "$(printf '%s' "$last" | jq -c '.listData // []')" '$a + $b')
  fi
  printf '%s' "$versions" | jq -c '
    (max_by(.version) // {}) | .inboundAuth
    | if . == null or .mode == null then empty
      elif .mode == "JWT" then {mode: "JWT", jwt: ((.jwt // {}) | with_entries(select(.value != null)))}
      else {mode: .mode} end'
}

# --- Actions ---

do_list() {
  local page="$DEFAULT_FIRST_PAGE"
  local size="$DEFAULT_PAGE_SIZE"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --page) page="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      *) echo "ERROR: Unknown option for list: $1" >&2; return 1 ;;
    esac
  done

  local query
  query=$(build_query "page=$page" "size=$size")
  REDACT_FIELDS="password" api_call GET "${BASE_URL}${query}"
}

do_create() {
  local name="" description="" image_url="" flavor_id="" env_file=""
  local min_replicas="" max_replicas="" cpu_scale="" mem_scale=""
  local registry_credentials="" from_cr=false
  local network_mode="" vpc_id="" subnet_id="" route_cidrs=""
  local poc=""
  local inbound_auth="" inbound_auth_jwt_file="" inbound_auth_explicit=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --description) description="$2"; shift 2 ;;
      --image) image_url="$2"; shift 2 ;;
      --flavor) flavor_id="$2"; shift 2 ;;
      --env-file) env_file="$2"; shift 2 ;;
      --min-replicas) min_replicas="$2"; shift 2 ;;
      --max-replicas) max_replicas="$2"; shift 2 ;;
      --cpu-scale) cpu_scale="$2"; shift 2 ;;
      --mem-scale) mem_scale="$2"; shift 2 ;;
      --registry-credentials-file) registry_credentials="$2"; shift 2 ;;
      --from-cr) from_cr=true; shift ;;
      --network-mode) network_mode="$2"; shift 2 ;;
      --vpc-id) vpc_id="$2"; shift 2 ;;
      --subnet-id) subnet_id="$2"; shift 2 ;;
      --route-cidrs) route_cidrs="$2"; shift 2 ;;
      --poc) poc="$2"; shift 2 ;;
      --inbound-auth) inbound_auth="$2"; inbound_auth_explicit=true; shift 2 ;;
      --inbound-auth-jwt-file) inbound_auth_jwt_file="$2"; shift 2 ;;
      *) echo "ERROR: Unknown option for create: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$name" ]; then
    echo "ERROR: --name is required for create" >&2; return 1
  fi
  if [ -z "$image_url" ]; then
    echo "ERROR: --image is required for create" >&2; return 1
  fi
  if [ -z "$flavor_id" ]; then
    echo "ERROR: --flavor is required for create" >&2; return 1
  fi
  if [ -z "$description" ]; then
    description="$name"
  fi

  # Normalize poc wallet flag. poc=true => POC wallet (free credits);
  # poc=false => real wallet (customer-funded). Empty defaults to real wallet.
  case "${poc:-}" in
    true|"yes"|"1") poc="true" ;;
    false|"no"|"0"|"") poc="false" ;;
    *) echo "ERROR: --poc must be 'true' or 'false' (got: $poc)" >&2; return 1 ;;
  esac

  # Build environment variables JSON
  local env_json="{}"
  if [ -n "$env_file" ]; then
    env_json=$(read_env_file "$env_file") || return 1
  fi

  # Build autoscaling JSON (all sub-fields are required by the API — use sensible defaults)
  local autoscaling_json
  autoscaling_json=$(jq -n \
    --arg minReplicas "${min_replicas:-1}" \
    --arg maxReplicas "${max_replicas:-1}" \
    --arg cpuUtil "${cpu_scale:-50}" \
    --arg memUtil "${mem_scale:-50}" \
    '{minReplicas: ($minReplicas | tonumber),
      maxReplicas: ($maxReplicas | tonumber),
      cpuUtilization: ($cpuUtil | tonumber),
      memoryUtilization: ($memUtil | tonumber)}')

  # Build base payload
  local body
  body=$(jq -n \
    --arg name "$name" \
    --arg description "$description" \
    --arg imageUrl "$image_url" \
    --arg flavorId "$flavor_id" \
    --argjson environmentVariables "$env_json" \
    --argjson autoscaling "$autoscaling_json" \
    --argjson poc "$poc" \
    '{name: $name, description: $description, imageUrl: $imageUrl, flavorId: $flavorId,
      command: [], args: [],
      environmentVariables: $environmentVariables,
      autoscaling: $autoscaling,
      poc: $poc}')

  # Handle private registry imageAuth
  local reg_user="" reg_pass=""
  if [ "$from_cr" = true ]; then
    if [ -n "$registry_credentials" ]; then
      echo "ERROR: Pass either --from-cr or --registry-credentials-file, not both" >&2
      return 1
    fi
    local cred_json
    cred_json=$(NO_PERSIST=1 REDACT_FIELDS="" api_call GET "${AGENTBASE_CR_URL}/registry-credential" 3>&1 >/dev/null) || return 1
    reg_user=$(echo "$cred_json" | jq -r '.username // empty')
    reg_pass=$(echo "$cred_json" | jq -r '.secret // empty')
    if [ -z "$reg_user" ] || [ -z "$reg_pass" ]; then
      echo "ERROR: Could not read username/secret from CR credentials response" >&2
      return 1
    fi
  elif [ -n "$registry_credentials" ]; then
    if [ ! -f "$registry_credentials" ]; then
      echo "ERROR: Registry credentials file not found: $registry_credentials" >&2
      return 1
    fi
    reg_user=$(jq -r '.username // empty' "$registry_credentials" 2>/dev/null)
    reg_pass=$(jq -r '.password // empty' "$registry_credentials" 2>/dev/null)
    if [ -z "$reg_user" ] || [ -z "$reg_pass" ]; then
      echo "ERROR: Registry credentials file must contain 'username' and 'password' fields" >&2
      return 1
    fi
  fi

  if [ -n "$reg_user" ]; then
    body=$(echo "$body" | jq \
      --arg user "$reg_user" \
      --arg pass "$reg_pass" \
      '. + {imageAuth: {enabled: true, username: $user, password: $pass}}')
  fi

  # POC wallet eligibility backstop (fail-closed). Only the POC direction is
  # dangerous to get wrong, so we re-verify it server-side right before create.
  if [ "$poc" = "true" ]; then
    local elig
    if ! elig=$(runtime_can_use_poc); then
      echo "ERROR: Could not verify POC wallet eligibility. Refusing to create." >&2
      return 1
    fi
    if [ "$elig" != "true" ]; then
      echo "ERROR: Your account is not permitted to use the POC wallet for runtime resources." >&2
      echo "       Re-run with --poc false to charge the real wallet." >&2
      return 1
    fi
  fi

  # Handle optional networkConfig (PUBLIC by default; only emit when explicitly requested)
  body=$(build_network_config "$body" "$network_mode" "$vpc_id" "$subnet_id" "$route_cidrs") || return 1

  # inboundAuth: defaults to IAM (the server would otherwise default to NONE =
  # unauthenticated endpoints). Omitted in VPC mode, where it is unsupported.
  local inbound_json
  inbound_json=$(build_inbound_auth "$inbound_auth" "$inbound_auth_jwt_file" "$network_mode" "$inbound_auth_explicit") || return 1
  if [ -n "$inbound_json" ]; then
    body=$(echo "$body" | jq --argjson ia "$inbound_json" '. + {inboundAuth: $ia}')
  fi

  REDACT_FIELDS="password" api_call POST "$BASE_URL" "$body"
}

do_get() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "ERROR: Runtime ID is required for get" >&2; return 1
  fi
  REDACT_FIELDS="password" api_call GET "${BASE_URL}/${id}"
}

do_update() {
  local id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$id" ]; then
    echo "ERROR: Runtime ID is required for update" >&2; return 1
  fi

  local description="" image_url="" flavor_id="" env_file=""
  local min_replicas="" max_replicas="" cpu_scale="" mem_scale=""
  local registry_credentials="" from_cr=false
  local network_mode="" vpc_id="" subnet_id="" route_cidrs=""
  local inbound_auth="" inbound_auth_jwt_file="" inbound_auth_explicit=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --description) description="$2"; shift 2 ;;
      --image) image_url="$2"; shift 2 ;;
      --flavor) flavor_id="$2"; shift 2 ;;
      --env-file) env_file="$2"; shift 2 ;;
      --min-replicas) min_replicas="$2"; shift 2 ;;
      --max-replicas) max_replicas="$2"; shift 2 ;;
      --cpu-scale) cpu_scale="$2"; shift 2 ;;
      --mem-scale) mem_scale="$2"; shift 2 ;;
      --registry-credentials-file) registry_credentials="$2"; shift 2 ;;
      --from-cr) from_cr=true; shift ;;
      --network-mode) network_mode="$2"; shift 2 ;;
      --vpc-id) vpc_id="$2"; shift 2 ;;
      --subnet-id) subnet_id="$2"; shift 2 ;;
      --route-cidrs) route_cidrs="$2"; shift 2 ;;
      --inbound-auth) inbound_auth="$2"; inbound_auth_explicit=true; shift 2 ;;
      --inbound-auth-jwt-file) inbound_auth_jwt_file="$2"; shift 2 ;;
      *) echo "ERROR: Unknown option for update: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$image_url" ]; then
    echo "ERROR: --image is required for update" >&2; return 1
  fi
  if [ -z "$flavor_id" ]; then
    echo "ERROR: --flavor is required for update" >&2; return 1
  fi

  # Preserve the existing wallet: PATCH is a full-body update, so re-send the
  # current poc value to avoid silently flipping wallets. No --poc flag on update.
  local existing_poc="false" cur
  if ! cur=$(REDACT_FIELDS="password" api_call GET "${BASE_URL}/${id}" 2>/dev/null); then
    echo "ERROR: Could not read current runtime to preserve its wallet (poc). Aborting update." >&2
    return 1
  fi
  # Explicit boolean check (not `// false`, which would drop a legitimate `false`
  # wallet) — mirrors runtime_can_use_poc(). The case below is defense-in-depth.
  existing_poc=$(printf '%s' "$cur" | jq -r '.poc as $p | if ($p == true or $p == false) then $p else false end' 2>/dev/null || true)
  case "$existing_poc" in true|false) ;; *) existing_poc="false" ;; esac

  # Build environment variables JSON
  local env_json="{}"
  if [ -n "$env_file" ]; then
    env_json=$(read_env_file "$env_file") || return 1
  fi

  # Build autoscaling JSON (all sub-fields are required by the API — use sensible defaults)
  local autoscaling_json
  autoscaling_json=$(jq -n \
    --arg minReplicas "${min_replicas:-1}" \
    --arg maxReplicas "${max_replicas:-1}" \
    --arg cpuUtil "${cpu_scale:-50}" \
    --arg memUtil "${mem_scale:-50}" \
    '{minReplicas: ($minReplicas | tonumber),
      maxReplicas: ($maxReplicas | tonumber),
      cpuUtilization: ($cpuUtil | tonumber),
      memoryUtilization: ($memUtil | tonumber)}')

  # Build base payload (all fields required by PATCH API); poc carried over from GET
  local body
  body=$(jq -n \
    --arg imageUrl "$image_url" \
    --arg flavorId "$flavor_id" \
    --arg description "${description:-}" \
    --argjson environmentVariables "$env_json" \
    --argjson autoscaling "$autoscaling_json" \
    --argjson poc "$existing_poc" \
    '{imageUrl: $imageUrl, flavorId: $flavorId,
      description: $description, command: [], args: [],
      environmentVariables: $environmentVariables,
      autoscaling: $autoscaling,
      poc: $poc}')

  # Handle private registry imageAuth
  local reg_user="" reg_pass=""
  if [ "$from_cr" = true ]; then
    if [ -n "$registry_credentials" ]; then
      echo "ERROR: Pass either --from-cr or --registry-credentials-file, not both" >&2
      return 1
    fi
    local cred_json
    cred_json=$(NO_PERSIST=1 REDACT_FIELDS="" api_call GET "${AGENTBASE_CR_URL}/registry-credential" 3>&1 >/dev/null) || return 1
    reg_user=$(echo "$cred_json" | jq -r '.username // empty')
    reg_pass=$(echo "$cred_json" | jq -r '.secret // empty')
    if [ -z "$reg_user" ] || [ -z "$reg_pass" ]; then
      echo "ERROR: Could not read username/secret from CR credentials response" >&2
      return 1
    fi
  elif [ -n "$registry_credentials" ]; then
    if [ ! -f "$registry_credentials" ]; then
      echo "ERROR: Registry credentials file not found: $registry_credentials" >&2
      return 1
    fi
    reg_user=$(jq -r '.username // empty' "$registry_credentials" 2>/dev/null)
    reg_pass=$(jq -r '.password // empty' "$registry_credentials" 2>/dev/null)
    if [ -z "$reg_user" ] || [ -z "$reg_pass" ]; then
      echo "ERROR: Registry credentials file must contain 'username' and 'password' fields" >&2
      return 1
    fi
  fi

  if [ -n "$reg_user" ]; then
    body=$(echo "$body" | jq \
      --arg user "$reg_user" \
      --arg pass "$reg_pass" \
      '. + {imageAuth: {enabled: true, username: $user, password: $pass}}')
  fi

  # Handle optional networkConfig (PUBLIC by default; only emit when explicitly requested)
  body=$(build_network_config "$body" "$network_mode" "$vpc_id" "$subnet_id" "$route_cidrs") || return 1

  # inboundAuth: the update is a full-body write, so an omitted inboundAuth would
  # silently reset the endpoints to NONE. Explicit --inbound-auth wins; otherwise
  # carry over the latest version's inboundAuth (never flip an existing runtime).
  local inbound_json=""
  if [ "$inbound_auth_explicit" = true ] || [ -n "$inbound_auth_jwt_file" ]; then
    inbound_json=$(build_inbound_auth "$inbound_auth" "$inbound_auth_jwt_file" "$network_mode" "$inbound_auth_explicit") || return 1
  elif [ "$DRY_RUN" = true ]; then
    echo "NOTE: dry-run — inboundAuth would be carried over from the latest version (not fetched in dry-run)." >&2
  else
    if ! inbound_json=$(current_inbound_auth "$id"); then
      echo "ERROR: Could not read the latest version's inboundAuth to preserve it. Pass --inbound-auth explicitly or retry." >&2
      return 1
    fi
    if [ -n "$inbound_json" ] && [ "$(echo "${network_mode:-}" | tr '[:lower:]' '[:upper:]')" = "VPC" ]; then
      echo "NOTE: switching to VPC mode — inboundAuth is unsupported there and will be dropped." >&2
      inbound_json=""
    fi
  fi
  if [ -n "$inbound_json" ]; then
    body=$(echo "$body" | jq --argjson ia "$inbound_json" '. + {inboundAuth: $ia}')
  fi

  REDACT_FIELDS="password" api_call PATCH "${BASE_URL}/${id}" "$body"
}

do_delete() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "ERROR: Runtime ID is required for delete" >&2; return 1
  fi
  api_call DELETE "${BASE_URL}/${id}"
}

do_reset_service_account() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "ERROR: Runtime ID is required for reset-service-account" >&2; return 1
  fi
  REDACT_FIELDS="password,secretKey,key,secret" api_call PATCH "${BASE_URL}/${id}/reset-service-account"
}

do_logs() {
  local id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$id" ]; then
    echo "ERROR: Runtime ID is required for logs" >&2; return 1
  fi

  local body
  body=$(build_log_body "$@") || return 1
  api_call POST "${BASE_URL}/${id}/logs" "$body"
}

do_versions() {
  local id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$id" ]; then
    echo "ERROR: Runtime ID is required for versions" >&2; return 1
  fi

  local page="$DEFAULT_FIRST_PAGE"
  local size="$DEFAULT_PAGE_SIZE"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --page) page="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      *) echo "ERROR: Unknown option for versions: $1" >&2; return 1 ;;
    esac
  done

  local query
  query=$(build_query "page=$page" "size=$size")
  api_call GET "${BASE_URL}/${id}/versions${query}"
}

do_endpoints() {
  local sub_action="${1:-}"; shift 2>/dev/null || true

  case "$sub_action" in
    list)    do_endpoints_list "$@" ;;
    create)  do_endpoints_create "$@" ;;
    update)  do_endpoints_update "$@" ;;
    delete)  do_endpoints_delete "$@" ;;
    start)   do_endpoints_start "$@" ;;
    stop)    do_endpoints_stop "$@" ;;
    logs)    do_endpoints_logs "$@" ;;
    metrics) do_endpoints_metrics "$@" ;;
    events)  do_endpoints_events "$@" ;;
    *)       echo "ERROR: Unknown endpoints sub-action '$sub_action'. Expected: list, create, update, delete, start, stop, logs, metrics, events" >&2; return 1 ;;
  esac
}

do_endpoints_list() {
  local id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$id" ]; then
    echo "ERROR: Runtime ID is required for endpoints list" >&2; return 1
  fi

  local page="$DEFAULT_FIRST_PAGE"
  local size="$DEFAULT_PAGE_SIZE"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --page) page="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      *) echo "ERROR: Unknown option for endpoints list: $1" >&2; return 1 ;;
    esac
  done

  local query
  query=$(build_query "page=$page" "size=$size")
  api_call GET "${BASE_URL}/${id}/endpoints${query}"
}

do_endpoints_create() {
  local id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$id" ]; then
    echo "ERROR: Runtime ID is required for endpoints create" >&2; return 1
  fi

  local name="" version=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --version) version="$2"; shift 2 ;;
      *) echo "ERROR: Unknown option for endpoints create: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$name" ]; then
    echo "ERROR: --name is required for endpoints create" >&2; return 1
  fi

  local body
  body=$(jq -n \
    --arg name "$name" \
    --arg version "$version" \
    '{name: $name} +
     (if $version != "" then {version: ($version | tonumber)} else {} end)')

  api_call POST "${BASE_URL}/${id}/endpoints" "$body"
}

do_endpoints_update() {
  local id="${1:-}"; shift 2>/dev/null || true
  local endpoint_id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$id" ] || [ -z "$endpoint_id" ]; then
    echo "ERROR: Runtime ID and Endpoint ID are required for endpoints update" >&2; return 1
  fi

  local version=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      *) echo "ERROR: Unknown option for endpoints update: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$version" ]; then
    echo "ERROR: --version is required for endpoints update" >&2; return 1
  fi

  local query
  query=$(build_query "version=$version")
  api_call PATCH "${BASE_URL}/${id}/endpoints/${endpoint_id}${query}"
}

do_endpoints_delete() {
  local id="${1:-}"; shift 2>/dev/null || true
  local endpoint_id="${1:-}"
  if [ -z "$id" ] || [ -z "$endpoint_id" ]; then
    echo "ERROR: Runtime ID and Endpoint ID are required for endpoints delete" >&2; return 1
  fi
  api_call DELETE "${BASE_URL}/${id}/endpoints/${endpoint_id}"
}

do_endpoints_start() {
  local id="${1:-}"; shift 2>/dev/null || true
  local endpoint_id="${1:-}"
  if [ -z "$id" ] || [ -z "$endpoint_id" ]; then
    echo "ERROR: Runtime ID and Endpoint ID are required for endpoints start" >&2; return 1
  fi
  api_call POST "${BASE_URL}/${id}/endpoints/${endpoint_id}/start"
}

do_endpoints_stop() {
  local id="${1:-}"; shift 2>/dev/null || true
  local endpoint_id="${1:-}"
  if [ -z "$id" ] || [ -z "$endpoint_id" ]; then
    echo "ERROR: Runtime ID and Endpoint ID are required for endpoints stop" >&2; return 1
  fi
  api_call POST "${BASE_URL}/${id}/endpoints/${endpoint_id}/stop"
}

do_endpoints_events() {
  local id="${1:-}"; shift 2>/dev/null || true
  local endpoint_id="${1:-}"
  if [ -z "$id" ] || [ -z "$endpoint_id" ]; then
    echo "ERROR: Runtime ID and Endpoint ID are required for endpoints events" >&2; return 1
  fi
  api_call GET "${BASE_URL}/${id}/endpoints/${endpoint_id}/events"
}

do_endpoints_logs() {
  local id="${1:-}"; shift 2>/dev/null || true
  local endpoint_id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$id" ] || [ -z "$endpoint_id" ]; then
    echo "ERROR: Runtime ID and Endpoint ID are required for endpoints logs" >&2; return 1
  fi

  local body
  body=$(build_log_body "$@") || return 1
  api_call POST "${BASE_URL}/${id}/endpoints/${endpoint_id}/logs" "$body"
}

do_endpoints_metrics() {
  local id="${1:-}"; shift 2>/dev/null || true
  local endpoint_id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$id" ] || [ -z "$endpoint_id" ]; then
    echo "ERROR: Runtime ID and Endpoint ID are required for endpoints metrics" >&2; return 1
  fi

  local from_time="" to_time=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-time) from_time="$2"; shift 2 ;;
      --to-time) to_time="$2"; shift 2 ;;
      *) echo "ERROR: Unknown option for endpoints metrics: $1" >&2; return 1 ;;
    esac
  done

  local query
  query=$(build_query "fromTimestamp=$from_time" "toTimestamp=$to_time")
  api_call GET "${BASE_URL}/${id}/endpoints/${endpoint_id}/metrics${query}"
}

# Build a URL-encoded query string from repeated "key=value" pairs.
# Args: each positional is a raw "key=value" string. Values are %-encoded.
build_passthrough_query() {
  local query=""
  for pair in "$@"; do
    local key="${pair%%=*}"
    local val="${pair#*=}"
    [ "$pair" = "$key" ] && val=""   # no '=' present → empty value
    local enc_key enc_val
    enc_key=$(jq -rn --arg s "$key" '$s|@uri')
    enc_val=$(jq -rn --arg s "$val" '$s|@uri')
    [ -n "$query" ] && query+="&" || query="?"
    query+="${enc_key}=${enc_val}"
  done
  echo "$query"
}

# Distributed tracing — thin passthrough to the runtime tracing backend.
# The query parameters (other than traceId / tagKey) and the response body are
# defined by the tracing backend, NOT by the runtime API spec. Pass backend
# query params verbatim via repeated --param key=value. Response is the
# backend's raw JSON string.
do_traces() {
  local sub_action="${1:-}"; shift 2>/dev/null || true

  case "$sub_action" in
    search)     do_traces_search "$@" ;;
    get)        do_traces_get "$@" ;;
    tag-values) do_traces_tag_values "$@" ;;
    *)          echo "ERROR: Unknown traces sub-action '$sub_action'. Expected: search, get, tag-values" >&2; return 1 ;;
  esac
}

do_traces_search() {
  local params=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --param) params+=("$2"); shift 2 ;;
      *) echo "ERROR: Unknown option for traces search: $1 (use --param key=value)" >&2; return 1 ;;
    esac
  done
  local query
  query=$(build_passthrough_query ${params[@]+"${params[@]}"})
  api_call GET "${BASE_URL}:search-traces${query}"
}

do_traces_get() {
  local trace_id="${1:-}"; shift 2>/dev/null || true
  if [ -z "$trace_id" ]; then
    echo "ERROR: Trace ID is required for traces get" >&2; return 1
  fi
  local params=("traceId=$trace_id")
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --param) params+=("$2"); shift 2 ;;
      *) echo "ERROR: Unknown option for traces get: $1 (use --param key=value)" >&2; return 1 ;;
    esac
  done
  local query
  query=$(build_passthrough_query ${params[@]+"${params[@]}"})
  api_call GET "${BASE_URL}:get-trace${query}"
}

do_traces_tag_values() {
  local tag_key="${1:-}"; shift 2>/dev/null || true
  if [ -z "$tag_key" ]; then
    echo "ERROR: Tag key is required for traces tag-values" >&2; return 1
  fi
  local params=("tagKey=$tag_key")
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --param) params+=("$2"); shift 2 ;;
      *) echo "ERROR: Unknown option for traces tag-values: $1 (use --param key=value)" >&2; return 1 ;;
    esac
  done
  local query
  query=$(build_passthrough_query ${params[@]+"${params[@]}"})
  api_call GET "${BASE_URL}:trace-search-tag-values${query}"
}

do_flavors() {
  api_call GET "$FLAVORS_URL"
}

do_help() {
  show_help ".claude/skills/agentbase/scripts/runtime.sh" \
    "Manage GreenNode AgentBase Agent Runtimes." \
    "  list   [--page N] [--size N]                          List runtimes
  create --name NAME --image URL --flavor ID [--description DESC]
         [--env-file PATH] [--min-replicas N] [--max-replicas N]
         [--cpu-scale N] [--mem-scale N]
         [--from-cr | --registry-credentials-file PATH]
         [--network-mode PUBLIC|VPC] [--vpc-id ID] [--subnet-id ID]
         [--route-cidrs CIDR1,CIDR2,...]
         [--poc true|false]
         [--inbound-auth NONE|IAM|JWT] [--inbound-auth-jwt-file PATH]
                                                           Create a new Custom Agent runtime
                                                           (--from-cr pulls AgentBase CR credentials inline; no file needed)
                                                           (--network-mode VPC requires --vpc-id and --subnet-id;
                                                            flavor must support agent-runtime-vpc resource type)
                                                           (--inbound-auth defaults to IAM; PUBLIC mode only —
                                                            omitted in VPC mode. JWT needs --inbound-auth-jwt-file)
  get    ID                                                Get runtime by ID
  update ID --image URL --flavor ID [--description DESC]
         [--env-file PATH] [--min-replicas N] [--max-replicas N]
         [--cpu-scale N] [--mem-scale N]
         [--from-cr | --registry-credentials-file PATH]
         [--network-mode PUBLIC|VPC] [--vpc-id ID] [--subnet-id ID]
         [--route-cidrs CIDR1,CIDR2,...]
         [--inbound-auth NONE|IAM|JWT] [--inbound-auth-jwt-file PATH]
                                                           Update a Custom Agent runtime
                                                           (--from-cr pulls AgentBase CR credentials inline; no file needed)
                                                           (changing network-mode triggers endpoint recreation)
                                                           (without --inbound-auth, the latest version's inboundAuth is kept)
  delete ID                                                Delete a runtime
  reset-service-account ID                                 Reset service account
  logs   ID [--from N] [--limit N] [--query TEXT]
         [--from-time ISO] [--to-time ISO] [--order asc|desc]
                                                           Get runtime logs
  versions ID [--page N] [--size N]                        List runtime versions
  endpoints list ID [--page N] [--size N]                  List endpoints
  endpoints create ID --name NAME [--version N]            Create endpoint
  endpoints update ID ENDPOINT_ID --version N              Update endpoint
  endpoints delete ID ENDPOINT_ID                          Delete endpoint
  endpoints start ID ENDPOINT_ID                           Start (resume) an endpoint
  endpoints stop ID ENDPOINT_ID                            Stop an endpoint
  endpoints logs ID ENDPOINT_ID [log flags]                Get endpoint logs
  endpoints metrics ID ENDPOINT_ID [--from-time ISO] [--to-time ISO]
                                                           Get endpoint metrics
  endpoints events ID ENDPOINT_ID                          Get infrastructure events for an endpoint
  traces search [--param key=value ...]                    Search distributed traces
  traces get TRACE_ID [--param key=value ...]              Get a single trace by ID
  traces tag-values TAG_KEY [--param key=value ...]        List values for a trace tag key
                                                           (trace --param keys/values and the response are
                                                            defined by the tracing backend, not this API)
  flavors                                                  List available flavors
  help                                                     Show this help message"
}

# --- Dispatch ---
case "$ACTION" in
  list)                  do_list "$@" ;;
  create)                do_create "$@" ;;
  get)                   do_get "$@" ;;
  update)                do_update "$@" ;;
  delete)                do_delete "$@" ;;
  reset-service-account) do_reset_service_account "$@" ;;
  logs)                  do_logs "$@" ;;
  versions)              do_versions "$@" ;;
  endpoints)             do_endpoints "$@" ;;
  traces)                do_traces "$@" ;;
  flavors)               do_flavors ;;
  help)                  do_help ;;
  *)                     echo "ERROR: Unknown action '$ACTION'. Run with 'help' for usage." >&2; exit 1 ;;
esac
