#!/usr/bin/env bash
# Apply the repository hardening baseline to one GitHub repository. Safe to re-run.
#
# Usage: harden-repo.sh OWNER/REPO [options]
#   --checks "A,B"        Required status check names (job names as the workflow reports them).
#                         Without it the PR ruleset requires no checks, because a name that no
#                         workflow reports blocks every merge.
#   --no-actions-policy   Skip the allowed-actions list and SHA pinning (repo has unpinned workflows).
#   --no-token-policy     Skip the read-only default token (workflows rely on a write token).
#   --no-rulesets         Skip the three rulesets.
#   --allow PATTERN       Extra allowed action pattern, repeatable (for example 'astral-sh/setup-uv@*').
#
# Needs gh (authenticated, admin on the repo) and jq. A control that GitHub refuses for the plan or the
# repository visibility is reported as UNAVAILABLE, and one that is accepted but does not stick as
# NO-EFFECT. Both are read back from the API, because a PATCH that returns 200 can still change nothing.
# Exit status is 1 if any control FAILED.
set -euo pipefail

repo=${1:-}
[[ $repo == */* ]] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift

checks="" actions_policy=1 token_policy=1 rulesets=1 allow=()
while (($#)); do
  case $1 in
    --checks) checks=$2; shift 2 ;;
    --no-actions-policy) actions_policy=0; shift ;;
    --no-token-policy) token_policy=0; shift ;;
    --no-rulesets) rulesets=0; shift ;;
    --allow) allow+=("$2"); shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

failed=0
say() { printf '%-40s %-12s %s\n' "$1" "$2" "${3:-}"; }
msg_of() { grep -oE '"message":"[^"]*"' <<<"$1" | head -1 | cut -d'"' -f4 || true; }

# try NAME CMD...: run a gh call and classify the outcome.
try() {
  local name=$1 out
  shift
  if out=$("$@" 2>&1); then
    say "$name" OK
  elif grep -qiE 'Upgrade to GitHub Pro|not available for this repository|is not enabled for this repository' <<<"$out"; then
    say "$name" UNAVAILABLE "$(msg_of "$out" | cut -c1-80)"
  else
    say "$name" FAILED "$(msg_of "$out" | cut -c1-80)"
    failed=1
  fi
}

# expect NAME ENDPOINT JQ-FILTER WANT: read the setting back and compare.
expect() {
  local name=$1 endpoint=$2 filter=$3 want=$4 got attempt
  # GitHub sometimes applies a setting a few seconds late, so retry before calling it NO-EFFECT.
  for attempt in 1 2 3; do
    got=$(gh api "$endpoint" --jq "$filter" 2>/dev/null || echo "unreadable")
    [[ $got == "$want" ]] && break
    ((attempt < 3)) && sleep 2
  done
  if [[ $got == "$want" ]]; then say "  read back: $name" VERIFIED; else say "  read back: $name" NO-EFFECT "wanted $want, got $got"; fi
}

private=$(gh api "repos/$repo" --jq .private)
echo "== $repo ($([[ $private == true ]] && echo private || echo public)) =="

# --- Repository settings ---
try "merge methods and messages" gh api -X PATCH "repos/$repo" \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true -F allow_update_branch=true -F web_commit_signoff_required=true
expect "squash only" "repos/$repo" '[.allow_squash_merge,.allow_merge_commit,.allow_rebase_merge]|join(",")' "true,false,false"
expect "PR title and body" "repos/$repo" '[.squash_merge_commit_title,.squash_merge_commit_message]|join(",")' "PR_TITLE,PR_BODY"
expect "branch hygiene and sign-off" "repos/$repo" '[.delete_branch_on_merge,.allow_update_branch,.web_commit_signoff_required]|join(",")' "true,true,true"
try "auto-merge" gh api -X PATCH "repos/$repo" -F allow_auto_merge=true
expect "auto-merge" "repos/$repo" .allow_auto_merge true
try "immutable releases" gh api -X PUT "repos/$repo/immutable-releases"
expect "immutable releases" "repos/$repo/immutable-releases" .enabled true

# --- Dependency and secret protections ---
try "dependabot alerts" gh api -X PUT "repos/$repo/vulnerability-alerts"
try "dependabot security updates" gh api -X PUT "repos/$repo/automated-security-fixes"
expect "dependabot security updates" "repos/$repo/automated-security-fixes" .enabled true
try "secret scanning" gh api -X PATCH "repos/$repo" --input - \
  <<<'{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}'
try "secret scanning push protection" gh api -X PATCH "repos/$repo" --input - \
  <<<'{"security_and_analysis":{"secret_scanning_push_protection":{"status":"enabled"}}}'
expect "secret scanning" "repos/$repo" '.security_and_analysis.secret_scanning.status // "none"' enabled
expect "push protection" "repos/$repo" '.security_and_analysis.secret_scanning_push_protection.status // "none"' enabled
if [[ $private == false ]]; then
  try "private vulnerability reporting" gh api -X PUT "repos/$repo/private-vulnerability-reporting"
fi

# --- Actions ---
if ((actions_policy)); then
  try "actions: selected, SHA pinning" gh api -X PUT "repos/$repo/actions/permissions" \
    -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
  patterns=$(printf '%s\n' "${allow[@]+"${allow[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')
  try "actions: allowed creators" gh api -X PUT "repos/$repo/actions/permissions/selected-actions" --input - \
    <<<"{\"github_owned_allowed\":true,\"verified_allowed\":true,\"patterns_allowed\":$patterns}"
  expect "actions policy" "repos/$repo/actions/permissions" '[.allowed_actions,.sha_pinning_required]|join(",")' "selected,true"
fi
if ((token_policy)); then
  try "token: read-only, no PR approval" gh api -X PUT "repos/$repo/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  expect "token" "repos/$repo/actions/permissions/workflow" '[.default_workflow_permissions,.can_approve_pull_request_reviews]|join(",")' "read,false"
fi

# --- Rulesets (create or update by name) ---
upsert_ruleset() {
  local name=$1 json=$2 id="" list
  # The list call is refused on plans without rulesets; then there is nothing to update.
  if list=$(gh api "repos/$repo/rulesets" 2>/dev/null); then
    id=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' <<<"$list")
  fi
  if [[ -n $id ]]; then
    try "ruleset: $name (update)" gh api -X PUT "repos/$repo/rulesets/$id" --input - <<<"$json"
  else
    try "ruleset: $name" gh api -X POST "repos/$repo/rulesets" --input - <<<"$json"
  fi
}

if ((rulesets)); then
  # Admins pass this ruleset only through a pull request.
  status_rule='[]'
  if [[ -n $checks ]]; then
    status_rule=$(jq -n --arg c "$checks" '[{type:"required_status_checks",parameters:{
      strict_required_status_checks_policy:true, do_not_enforce_on_create:false,
      required_status_checks:($c|split(",")|map({context:., integration_id:15368}))}}]')
  fi
  pr_json=$(jq -n --argjson status "$status_rule" '{
    name:"main: PR and checks", target:"branch", enforcement:"active",
    conditions:{ref_name:{include:["~DEFAULT_BRANCH"],exclude:[]}},
    bypass_actors:[{actor_id:5,actor_type:"RepositoryRole",bypass_mode:"pull_request"}],
    rules:([{type:"pull_request",parameters:{required_approving_review_count:1,
      dismiss_stale_reviews_on_push:true,require_code_owner_review:false,
      require_last_push_approval:false,required_review_thread_resolution:true,
      allowed_merge_methods:["squash"]}}] + $status)}')
  # No bypass actors: signing and history rules apply to everyone.
  history_json='{"name":"main: history integrity","target":"branch","enforcement":"active",
    "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],
    "rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_linear_history"},{"type":"required_signatures"}]}'
  # No "creation" rule, so a release workflow can still create tags.
  tags_json='{"name":"tags: immutable releases","target":"tag","enforcement":"active",
    "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"bypass_actors":[],
    "rules":[{"type":"deletion"},{"type":"update"},{"type":"non_fast_forward"}]}'
  upsert_ruleset "main: PR and checks" "$pr_json"
  upsert_ruleset "main: history integrity" "$history_json"
  upsert_ruleset "tags: immutable releases" "$tags_json"
fi

exit "$failed"
