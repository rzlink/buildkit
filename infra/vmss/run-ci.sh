#!/usr/bin/env bash
#
# run-ci.sh — Automate VMSS scaling + CI workflow dispatch for ARM64 tests.
#
# Scales up Azure VMSS, waits for GitHub runners, dispatches the workflow,
# polls until completion, then scales VMSS back to 0. Signal traps guarantee
# scale-down even on Ctrl+C or errors.
#
# Prerequisites: az (logged in), gh (authenticated to rzlink/buildkit)
#
# Usage:
#   ./infra/vmss/run-ci.sh [options]
#
# Options:
#   --capacity N       VMSS instance count (default: 12)
#   --ref BRANCH       Git ref to test (default: current branch)
#   --arm64-only       Only run ARM64 tests (sets arm64_only=true)
#   --filter REGEX     ARM64 test name filter (e.g. "TestFoo|TestBar")
#   --no-scale-down    Skip scale-down after completion (for debugging)
#   --no-scale-up      Skip scale-up (assume VMSS already running)
#   --no-sync          Skip upstream sync and rebase
#   --poll-interval N  Seconds between status polls (default: 30)
#   --webhook URL      Send result to Teams webhook (Adaptive Card)
#   --no-notify        Skip all notifications
#   -h, --help         Show this help
#
# Teams webhook setup:
#   1. In Teams, go to a chat/channel → ⋯ → Workflows
#   2. Select "Send webhook alerts to chat"
#   3. Copy the webhook URL
#   4. Store it:
#      export TEAMS_WEBHOOK_URL="https://..."
#   Or put it in ~/.config/run-ci/teams.env (sourced automatically)
#   Or pass --webhook URL

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
RESOURCE_GROUP="buildkit-arm64-runner-rg"
VMSS_NAME="arm64-runner-ss"
REPO="rzlink/buildkit"
WORKFLOW="test-os.yml"
PRIMARY_SKU="Standard_D4plds_v6"
FALLBACK_SKUS=(Standard_D4pds_v6 Standard_D4ps_v6 Standard_D4pds_v5)

# ─── Defaults ────────────────────────────────────────────────────────────────
CAPACITY=12
REF=""
ARM64_ONLY="false"
TEST_FILTER=""
NO_SCALE_DOWN=false
NO_SCALE_UP=false
NO_SYNC=false
POLL_INTERVAL=30
SCALE_DOWN_DONE=false
WEBHOOK_URL=""
NO_NOTIFY=false
FEATURE_BRANCH="ci/windows-arm64-azure-testing"
ACTIVE_SKU="$PRIMARY_SKU"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Helper functions ────────────────────────────────────────────────────────
log()   { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC}  $*"; }
err()   { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC}  $*"; }

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    sed -n '/^# Options:/,/^[^#]/p' "$0" | sed 's/^# \?//' | head -n -1
    exit 0
}

# ─── Failure notification (called on early script failures) ──────────────────
notify_failure() {
    local title="$1"
    local detail="$2"
    if [[ -z "$WEBHOOK_URL" ]] || [[ "$NO_NOTIFY" == true ]]; then
        return 0
    fi
    local payload=$(cat <<ENDJSON
{
  "type": "message",
  "attachments": [{
    "contentType": "application/vnd.microsoft.card.adaptive",
    "content": {
      "type": "AdaptiveCard",
      "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
      "version": "1.4",
      "msteams": {"width": "Full"},
      "body": [
        {"type":"TextBlock","text":"⚠️ BuildKit ARM64 CI — ${title}","weight":"Bolder","size":"Medium","wrap":true},
        {"type":"TextBlock","text":"${detail}","wrap":true,"spacing":"Small"},
        {"type":"FactSet","facts":[
          {"title":"Ref","value":"${REF:-unknown}"},
          {"title":"Time","value":"$(date -u '+%Y-%m-%d %H:%M UTC')"}
        ]}
      ]
    }
  }]
}
ENDJSON
)
    curl -s -o /dev/null -w "" -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || true
    log "Failure notification sent to Teams"
}

# ─── Scale-down function (called from trap and normal exit) ──────────────────
scale_down() {
    if [[ "$NO_SCALE_DOWN" == true ]] || [[ "$SCALE_DOWN_DONE" == true ]]; then
        return 0
    fi
    SCALE_DOWN_DONE=true
    log "Scaling VMSS to 0 instances..."
    if az vmss scale -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --new-capacity 0 --no-wait -o none 2>/dev/null; then
        ok "VMSS scale-down initiated"
    else
        err "Failed to scale down VMSS — please run manually:"
        err "  az vmss scale -g $RESOURCE_GROUP -n $VMSS_NAME --new-capacity 0"
    fi
    # Restore primary SKU if a fallback was used
    if [[ "$ACTIVE_SKU" != "$PRIMARY_SKU" ]]; then
        log "Restoring VMSS to primary SKU ($PRIMARY_SKU)..."
        az vmss update -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --set "sku.name=$PRIMARY_SKU" -o none 2>/dev/null || true
    fi
}

# ─── Signal trap — guarantee scale-down ──────────────────────────────────────
cleanup() {
    echo ""
    warn "Interrupted — cleaning up..."
    scale_down
    exit 130
}
trap cleanup INT TERM

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --capacity)       CAPACITY="$2"; shift 2 ;;
        --ref)            REF="$2"; shift 2 ;;
        --arm64-only)     ARM64_ONLY="true"; shift ;;
        --filter)         TEST_FILTER="$2"; shift 2 ;;
        --no-scale-down)  NO_SCALE_DOWN=true; shift ;;
        --no-scale-up)    NO_SCALE_UP=true; shift ;;
        --no-sync)        NO_SYNC=true; shift ;;
        --poll-interval)  POLL_INTERVAL="$2"; shift 2 ;;
        --webhook)        WEBHOOK_URL="$2"; shift 2 ;;
        --no-notify)      NO_NOTIFY=true; shift ;;
        -h|--help)        usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

# Default ref to current branch
if [[ -z "$REF" ]]; then
    REF=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "ci/windows-arm64-azure-testing")
fi

# ─── Preflight checks ───────────────────────────────────────────────────────
log "Preflight checks..."
if ! command -v az &>/dev/null; then
    err "Azure CLI (az) not found. Please install: https://aka.ms/installaz"
    exit 1
fi
if ! command -v gh &>/dev/null; then
    err "GitHub CLI (gh) not found. Please install: https://cli.github.com"
    exit 1
fi
if ! az account show -o none 2>/dev/null; then
    err "Not logged in to Azure. Run: az login"
    exit 1
fi
if ! gh auth status &>/dev/null; then
    err "Not authenticated to GitHub. Run: gh auth login"
    exit 1
fi
# Load Teams webhook URL from config or environment if not set via --webhook
if [[ -z "$WEBHOOK_URL" ]]; then
    TEAMS_CONFIG="$HOME/.config/run-ci/teams.env"
    if [[ -f "$TEAMS_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$TEAMS_CONFIG"
    fi
    WEBHOOK_URL="${TEAMS_WEBHOOK_URL:-$WEBHOOK_URL}"
fi
if [[ -n "$WEBHOOK_URL" ]]; then
    ok "Teams webhook configured"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         ARM64 CI Run Configuration           ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Ref:" "$REF"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Capacity:" "$CAPACITY instances"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "ARM64 only:" "$ARM64_ONLY"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Test filter:" "${TEST_FILTER:-<none>}"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Scale down:" "$([[ $NO_SCALE_DOWN == true ]] && echo 'disabled' || echo 'auto')"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Sync/rebase:" "$([[ $NO_SYNC == true ]] && echo 'disabled' || echo 'enabled')"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Notify:" "$([[ $NO_NOTIFY == true ]] && echo 'disabled' || ([[ -n "$WEBHOOK_URL" ]] && echo 'Teams webhook' || echo '(none)'))"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

START_TIME=$(date +%s)
CI_START_DISPLAY=$(date -u '+%Y-%m-%d %H:%M UTC')

# ═══════════════════════════════════════════════════════════════════════════════
# Step 0: Sync upstream and rebase feature branch
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$NO_SYNC" == true ]]; then
    log "Skipping upstream sync (--no-sync)"
else
    log "Syncing fork with upstream..."

    # Ensure we're in a git repo
    if ! git rev-parse --git-dir &>/dev/null; then
        warn "Not in a git repo — skipping sync"
    else
        ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

        # Stash any uncommitted changes before switching branches
        STASHED=false
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            git stash push --quiet -m "run-ci auto-stash" 2>/dev/null && STASHED=true
        fi

        # Fetch upstream
        if ! git fetch upstream master --quiet 2>/dev/null; then
            warn "Failed to fetch upstream — skipping sync"
        else
            ok "Fetched upstream/master"

            # Sync master — force-reset to upstream (fork master should not have unique commits)
            git checkout master --quiet 2>/dev/null
            if git merge upstream/master --ff-only --quiet 2>/dev/null; then
                ok "Fast-forwarded master to upstream/master"
            else
                warn "Master diverged from upstream — resetting to upstream/master"
                git reset --hard upstream/master --quiet 2>/dev/null
            fi
            if git push origin master --force --quiet 2>/dev/null; then
                ok "Pushed synced master to origin"
            else
                warn "Failed to push master to origin"
            fi

            # Rebase feature branch
            git checkout "$FEATURE_BRANCH" --quiet 2>/dev/null
            log "Rebasing $FEATURE_BRANCH onto master..."
            if git rebase master --quiet 2>/dev/null; then
                ok "Rebase succeeded"
                if git push origin "$FEATURE_BRANCH" --force-with-lease --quiet 2>/dev/null; then
                    ok "Pushed rebased branch to origin"
                else
                    warn "Failed to push rebased branch"
                fi
            else
                warn "Rebase conflict detected — aborting rebase"
                git rebase --abort 2>/dev/null || true
                warn "Continuing with existing branch state"
            fi
        fi

        # Return to original branch if different
        if [[ -n "$ORIGINAL_BRANCH" ]] && [[ "$ORIGINAL_BRANCH" != "$FEATURE_BRANCH" ]]; then
            git checkout "$ORIGINAL_BRANCH" --quiet 2>/dev/null || true
        fi

        # Restore stashed changes
        if [[ "$STASHED" == true ]]; then
            git stash pop --quiet 2>/dev/null || warn "Failed to restore stashed changes"
        fi
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Clean up stale offline runners and scale up VMSS
# ═══════════════════════════════════════════════════════════════════════════════

# Remove stale offline runners to avoid pagination issues and name collisions
log "Cleaning up stale offline runners..."
STALE_IDS=$(gh api "repos/$REPO/actions/runners" --paginate \
    --jq '.runners[] | select(.status == "offline" and (.labels[]?.name == "windows-arm64-selfhosted")) | .id' 2>/dev/null) || STALE_IDS=""
STALE_COUNT=0
if [[ -n "$STALE_IDS" ]]; then
    STALE_COUNT=$(echo "$STALE_IDS" | grep -c '[0-9]' 2>/dev/null || true)
fi
if [[ "$STALE_COUNT" -gt 0 ]]; then
    echo "$STALE_IDS" | while read -r rid; do
        gh api -X DELETE "repos/$REPO/actions/runners/$rid" 2>/dev/null || true
    done
    ok "Removed $STALE_COUNT stale offline runners"
else
    ok "No stale runners to clean up"
fi

if [[ "$NO_SCALE_UP" == true ]]; then
    log "Skipping scale-up (--no-scale-up)"
else
    SCALE_MAX_RETRIES=3
    SCALE_RETRY_DELAY=300  # 5 minutes
    SCALE_SUCCESS=false

    # Try primary SKU first with retries, then fall back to alternative SKUs
    ALL_SKUS=("$PRIMARY_SKU" "${FALLBACK_SKUS[@]}")

    for sku_idx in "${!ALL_SKUS[@]}"; do
        SKU="${ALL_SKUS[$sku_idx]}"

        # Switch VMSS SKU if not the first attempt
        if [[ "$sku_idx" -gt 0 ]]; then
            log "Trying fallback SKU: $SKU"
            # Scale to 0 first — can't change SKU with existing instances
            az vmss scale -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --new-capacity 0 -o none 2>/dev/null || true
            if ! az vmss update -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --set "sku.name=$SKU" -o none 2>/dev/null; then
                warn "Failed to switch VMSS to $SKU — skipping"
                continue
            fi
            ok "VMSS SKU changed to $SKU"
        fi

        for attempt in $(seq 1 $SCALE_MAX_RETRIES); do
            log "Scaling VMSS to $CAPACITY instances ($SKU, attempt $attempt/$SCALE_MAX_RETRIES)..."
            SCALE_OUTPUT=$(az vmss scale -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --new-capacity "$CAPACITY" -o none 2>&1) && SCALE_RC=0 || SCALE_RC=$?

            # az vmss scale can return 0 even on SkuNotAvailable — check output too
            if [[ $SCALE_RC -eq 0 ]] && ! echo "$SCALE_OUTPUT" | grep -qi "SkuNotAvailable\|error"; then
                SCALE_SUCCESS=true
                ACTIVE_SKU="$SKU"
                ok "VMSS scaled to $CAPACITY instances (SKU: $SKU)"
                break 2
            fi

            echo "$SCALE_OUTPUT"
            if echo "$SCALE_OUTPUT" | grep -qi "VMExtensionProvisioningError\|CustomScriptExtension"; then
                # CSE failure on some instances — VMs are running, runners may still register
                warn "VM extension error on some instances (non-fatal, continuing)"
                SCALE_SUCCESS=true
                ACTIVE_SKU="$SKU"
                break 2
            elif echo "$SCALE_OUTPUT" | grep -qi "SkuNotAvailable"; then
                warn "SKU $SKU not available in this region — trying next SKU"
                break  # deterministic; retrying won't help
            elif echo "$SCALE_OUTPUT" | grep -qi "capacity\|quota\|throttl"; then
                if [[ $attempt -lt $SCALE_MAX_RETRIES ]]; then
                    warn "Transient capacity error, retrying in $(( SCALE_RETRY_DELAY / 60 ))m..."
                    sleep "$SCALE_RETRY_DELAY"
                else
                    warn "SKU $SKU exhausted after $SCALE_MAX_RETRIES attempts"
                    break  # try next SKU
                fi
            elif echo "$SCALE_OUTPUT" | grep -qi "OSProvisioningTimedOut\|ProvisioningTimeout"; then
                warn "Provisioning timed out on $SKU (too slow) — trying next SKU"
                break  # try next SKU
            else
                err "VMSS scale-up failed with non-retryable error"
                az vmss scale -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --new-capacity 0 -o none 2>/dev/null || true
                az vmss update -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --set "sku.name=$PRIMARY_SKU" -o none 2>/dev/null || true
                notify_failure "VMSS scale-up failed" "Non-retryable Azure error during scale-up"
                exit 1
            fi
        done
    done

    if [[ "$SCALE_SUCCESS" != true ]]; then
        err "VMSS scale-up failed — all SKUs exhausted: ${ALL_SKUS[*]}"
        notify_failure "VMSS scale-up failed" "All SKUs exhausted (tried: ${ALL_SKUS[*]})"
        # Clean up: scale to 0 and restore primary SKU for next run
        az vmss scale -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --new-capacity 0 -o none 2>/dev/null || true
        az vmss update -g "$RESOURCE_GROUP" -n "$VMSS_NAME" --set "sku.name=$PRIMARY_SKU" -o none 2>/dev/null || true
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Wait for runners to register on GitHub
# ═══════════════════════════════════════════════════════════════════════════════
log "Waiting for $CAPACITY runners to register on GitHub..."
RUNNER_WAIT_START=$(date +%s)
RUNNER_TIMEOUT=900  # 15 minutes

while true; do
    RUNNER_COUNT=$(gh api "repos/$REPO/actions/runners" --paginate --jq '[.runners[] | select(.status == "online" and (.labels[]?.name == "windows-arm64-selfhosted"))] | length' 2>/dev/null || echo 0)
    # --paginate returns one number per page; sum them
    RUNNER_COUNT=$(echo "$RUNNER_COUNT" | awk '{s+=$1} END {print s+0}')

    ELAPSED=$(( $(date +%s) - RUNNER_WAIT_START ))

    if [[ "$RUNNER_COUNT" -ge "$CAPACITY" ]]; then
        ok "$RUNNER_COUNT/$CAPACITY runners online (${ELAPSED}s)"
        break
    fi

    if [[ "$ELAPSED" -ge "$RUNNER_TIMEOUT" ]]; then
        warn "Timeout: only $RUNNER_COUNT/$CAPACITY runners after ${ELAPSED}s"
        if [[ "$RUNNER_COUNT" -eq 0 ]]; then
            err "No runners registered — aborting"
            notify_failure "Runner registration timeout" "0/$CAPACITY runners registered after ${ELAPSED}s"
            scale_down
            exit 1
        fi
        warn "Proceeding with $RUNNER_COUNT runners"
        break
    fi

    printf "\r  ${CYAN}⏳${NC} %d/%d runners online (%ds elapsed)..." "$RUNNER_COUNT" "$CAPACITY" "$ELAPSED"
    sleep 15
done

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Dispatch workflow
# ═══════════════════════════════════════════════════════════════════════════════
log "Dispatching workflow on ref: $REF"

DISPATCH_ARGS=("--ref" "$REF")
DISPATCH_ARGS+=("-f" "arm64_only=$ARM64_ONLY")
if [[ -n "$TEST_FILTER" ]]; then
    DISPATCH_ARGS+=("-f" "arm64_test_filter=$TEST_FILTER")
fi

if ! gh workflow run "$WORKFLOW" "${DISPATCH_ARGS[@]}" 2>&1; then
    err "Workflow dispatch failed"
    scale_down
    exit 1
fi
ok "Workflow dispatched"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Find the new run ID
# ═══════════════════════════════════════════════════════════════════════════════
log "Finding run ID..."
sleep 5

RUN_ID=""
for i in $(seq 1 20); do
    RUN_ID=$(gh run list --workflow="$WORKFLOW" --branch="$REF" --event=workflow_dispatch -L 1 --json databaseId,status --jq '.[0].databaseId' 2>/dev/null || echo "")

    if [[ -n "$RUN_ID" ]] && [[ "$RUN_ID" != "null" ]]; then
        ok "Run ID: $RUN_ID"
        echo -e "   ${CYAN}URL:${NC} https://github.com/$REPO/actions/runs/$RUN_ID"
        break
    fi
    sleep 3
done

if [[ -z "$RUN_ID" ]] || [[ "$RUN_ID" == "null" ]]; then
    err "Could not find run ID after 60s"
    scale_down
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Poll run status until completed
# ═══════════════════════════════════════════════════════════════════════════════
log "Monitoring run #$RUN_ID (polling every ${POLL_INTERVAL}s)..."
echo ""

LAST_COMPLETED=0
while true; do
    RUN_JSON=$(gh run view "$RUN_ID" --json status,conclusion,jobs 2>/dev/null || echo '{}')
    STATUS=$(echo "$RUN_JSON" | jq -r '.status // "unknown"')
    CONCLUSION=$(echo "$RUN_JSON" | jq -r '.conclusion // ""')
    JOBS_TOTAL=$(echo "$RUN_JSON" | jq '[.jobs // [] | length] | .[0]')
    JOBS_COMPLETED=$(echo "$RUN_JSON" | jq '[.jobs // [] | map(select(.status == "completed")) | length] | .[0]')
    JOBS_FAILED=$(echo "$RUN_JSON" | jq '[.jobs // [] | map(select(.conclusion == "failure")) | length] | .[0]')
    JOBS_RUNNING=$(echo "$RUN_JSON" | jq '[.jobs // [] | map(select(.status == "in_progress")) | length] | .[0]')

    RUN_ELAPSED=$(( $(date +%s) - START_TIME ))
    RUN_MIN=$(( RUN_ELAPSED / 60 ))
    RUN_SEC=$(( RUN_ELAPSED % 60 ))

    # Show progress when jobs complete
    if [[ "$JOBS_COMPLETED" -ne "$LAST_COMPLETED" ]] || [[ "$STATUS" == "completed" ]]; then
        FAIL_STR=""
        if [[ "$JOBS_FAILED" -gt 0 ]]; then
            FAIL_STR=" ${RED}(${JOBS_FAILED} failed)${NC}"
        fi
        printf "\r  ${CYAN}📊${NC} %d/%d jobs done, %d running%b  [%dm%02ds]\n" \
            "$JOBS_COMPLETED" "$JOBS_TOTAL" "$JOBS_RUNNING" "$FAIL_STR" "$RUN_MIN" "$RUN_SEC"
        LAST_COMPLETED="$JOBS_COMPLETED"
    fi

    if [[ "$STATUS" == "completed" ]]; then
        break
    fi

    sleep "$POLL_INTERVAL"
done

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6: Scale down
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
scale_down

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7: Collect test results from artifacts (per-platform)
# ═══════════════════════════════════════════════════════════════════════════════
RESULTS_DIR=$(mktemp -d)

# Per-platform variables
ARM64_PASSED=0; ARM64_FAILED=0; ARM64_SKIPPED=0; ARM64_FAILED_TESTS=""
AMD64_PASSED=0; AMD64_FAILED=0; AMD64_SKIPPED=0; AMD64_FAILED_TESTS=""
TOTAL_PASSED=0; TOTAL_FAILED=0; TOTAL_SKIPPED=0; FAILED_TESTS=""
HAS_AMD64=false; HAS_ARM64=false

log "Downloading test report artifacts..."
if gh run download "$RUN_ID" --dir "$RESULTS_DIR" --pattern "test-reports-*" 2>/dev/null; then
    ok "Artifacts downloaded to $RESULTS_DIR"

    # Function to parse test results from JSON files
    parse_test_results() {
        local files="$1"
        if [[ -z "$files" ]]; then
            echo "0|0|0"
            return
        fi
        echo "$files" | xargs cat | python3 -c "
import json, sys, re

passed = failed = skipped = 0
failed_tests = []

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue

    action = obj.get('Action', '')
    test_name = obj.get('Test', '')
    elapsed = obj.get('Elapsed', 0)

    if not test_name or action not in ('pass', 'fail', 'skip'):
        continue
    if test_name == 'TestIntegration':
        continue
    if re.match(r'^TestIntegration/slice=', test_name) and '/Test' not in test_name:
        continue
    if elapsed is None or elapsed == 0:
        continue

    if action == 'pass':
        passed += 1
    elif action == 'skip':
        skipped += 1
    elif action == 'fail':
        failed += 1
        parts = test_name.split('/')
        actual = ''
        qualifiers = []
        for p in parts:
            if p.startswith('Test') and p != 'TestIntegration':
                actual = p
            elif '=' in p:
                qualifiers.append(p)
        if actual:
            short = actual
            if qualifiers:
                short += ' (' + ', '.join(qualifiers) + ')'
        else:
            short = test_name[:80]
        failed_tests.append(f'  - {short} ({elapsed}s)')

print(f'{passed}|{failed}|{skipped}')
for ft in failed_tests:
    print(ft)
" 2>/dev/null
    }

    # Find ARM64 and AMD64 test report files
    ARM64_FILES=$(find "$RESULTS_DIR" -path "*arm64*" -name "go-test-report-*.json" -type f 2>/dev/null | tr '\n' ' ')
    AMD64_FILES=$(find "$RESULTS_DIR" -path "*amd64*" -name "go-test-report-*.json" -type f 2>/dev/null)
    # Also match windows-2022 pattern (amd64 default)
    if [[ -z "$AMD64_FILES" ]]; then
        AMD64_FILES=$(find "$RESULTS_DIR" -path "*windows-2022*" -name "go-test-report-*.json" -type f 2>/dev/null)
    fi
    if [[ -n "$AMD64_FILES" ]]; then
        AMD64_FILES=$(echo "$AMD64_FILES" | tr '\n' ' ')
    fi

    # Parse ARM64 results
    if [[ -n "$ARM64_FILES" ]]; then
        HAS_ARM64=true
        ARM64_PARSE=$(parse_test_results "$ARM64_FILES")
        ARM64_PASSED=$(echo "$ARM64_PARSE" | head -1 | cut -d'|' -f1)
        ARM64_FAILED=$(echo "$ARM64_PARSE" | head -1 | cut -d'|' -f2)
        ARM64_SKIPPED=$(echo "$ARM64_PARSE" | head -1 | cut -d'|' -f3)
        ARM64_FAILED_TESTS=$(echo "$ARM64_PARSE" | tail -n +2)
    fi

    # Parse AMD64 results
    if [[ -n "$AMD64_FILES" ]]; then
        HAS_AMD64=true
        AMD64_PARSE=$(parse_test_results "$AMD64_FILES")
        AMD64_PASSED=$(echo "$AMD64_PARSE" | head -1 | cut -d'|' -f1)
        AMD64_FAILED=$(echo "$AMD64_PARSE" | head -1 | cut -d'|' -f2)
        AMD64_SKIPPED=$(echo "$AMD64_PARSE" | head -1 | cut -d'|' -f3)
        AMD64_FAILED_TESTS=$(echo "$AMD64_PARSE" | tail -n +2)
    fi

    # Compute totals
    TOTAL_PASSED=$(( ARM64_PASSED + AMD64_PASSED ))
    TOTAL_FAILED=$(( ARM64_FAILED + AMD64_FAILED ))
    TOTAL_SKIPPED=$(( ARM64_SKIPPED + AMD64_SKIPPED ))
    FAILED_TESTS=""
    [[ -n "$AMD64_FAILED_TESTS" ]] && FAILED_TESTS="$AMD64_FAILED_TESTS"
    if [[ -n "$ARM64_FAILED_TESTS" ]]; then
        [[ -n "$FAILED_TESTS" ]] && FAILED_TESTS="${FAILED_TESTS}"$'\n'"${ARM64_FAILED_TESTS}" || FAILED_TESTS="$ARM64_FAILED_TESTS"
    fi

    RESULT_SUMMARY="✅ ${TOTAL_PASSED} passed, ❌ ${TOTAL_FAILED} failed, ⏭️ ${TOTAL_SKIPPED} skipped"
    ok "Test results: $RESULT_SUMMARY"
else
    warn "Failed to download artifacts — test details unavailable"
    RESULT_SUMMARY="(artifact download failed — check GitHub UI)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 8: Compute per-platform stats from jobs
# ═══════════════════════════════════════════════════════════════════════════════

# Split jobs by platform using jq (exclude skipped jobs)
ARM64_JOBS_TOTAL=$(echo "$RUN_JSON" | jq '[.jobs // [] | .[] | select(.name | startswith("test-windows-arm64")) | select(.conclusion != "skipped")] | length')
ARM64_JOBS_FAILED=$(echo "$RUN_JSON" | jq '[.jobs // [] | .[] | select(.name | startswith("test-windows-arm64")) | select(.conclusion == "failure")] | length')
if [[ "$ARM64_ONLY" != "true" ]]; then
    AMD64_JOBS_TOTAL=$(echo "$RUN_JSON" | jq '[.jobs // [] | .[] | select(.name | startswith("test-windows-amd64")) | select(.conclusion != "skipped")] | length')
    AMD64_JOBS_FAILED=$(echo "$RUN_JSON" | jq '[.jobs // [] | .[] | select(.name | startswith("test-windows-amd64")) | select(.conclusion == "failure")] | length')
fi

# Per-platform duration from job timestamps
compute_platform_duration() {
    local prefix="$1"
    local times
    times=$(echo "$RUN_JSON" | jq -r --arg p "$prefix" '
        [.jobs // [] | .[] | select(.name | startswith($p)) | select(.conclusion != null and .conclusion != "cancelled")] |
        if length == 0 then "||"
        else (map(.startedAt) | sort | first) + "|" + (map(.completedAt) | sort | last)
        end
    ' 2>/dev/null)
    local started=$(echo "$times" | cut -d'|' -f1)
    local finished=$(echo "$times" | cut -d'|' -f2)
    if [[ -n "$started" ]] && [[ -n "$finished" ]]; then
        local s_epoch=$(date -d "$started" +%s 2>/dev/null || echo "")
        local f_epoch=$(date -d "$finished" +%s 2>/dev/null || echo "")
        if [[ -n "$s_epoch" ]] && [[ -n "$f_epoch" ]]; then
            local elapsed=$(( f_epoch - s_epoch ))
            echo "$(( elapsed / 60 ))m $(( elapsed % 60 ))s"
            return
        fi
    fi
    echo "N/A"
}

ARM64_DURATION=$(compute_platform_duration "test-windows-arm64")
if [[ "$ARM64_ONLY" != "true" ]]; then
    AMD64_DURATION=$(compute_platform_duration "test-windows-amd64")
fi

# Determine effective pass/fail based on test results, not just GitHub conclusion.
# Test results are the primary signal — a job can fail due to infrastructure
# issues (e.g., "Upload test reports" step) while all tests actually passed.
EFFECTIVE_PASS=false
INFRA_ISSUE=false
if [[ "$CONCLUSION" == "success" ]]; then
    EFFECTIVE_PASS=true
elif [[ "$TOTAL_FAILED" -eq 0 ]]; then
    # All tests passed — failure is from infrastructure (upload step, etc.)
    EFFECTIVE_PASS=true
    if [[ "$CONCLUSION" != "success" ]]; then
        INFRA_ISSUE=true
    fi
fi

# Dynamic title
if [[ "$ARM64_ONLY" == "true" ]] || [[ "$HAS_AMD64" == false ]]; then
    CI_TITLE="BuildKit ARM64 CI"
else
    CI_TITLE="BuildKit CI"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 8b: Terminal summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"

if [[ "$EFFECTIVE_PASS" == true ]] && [[ "$INFRA_ISSUE" == false ]]; then
    echo -e "${BOLD}║${NC}  ${GREEN}${BOLD}✓ ${CI_TITLE} PASSED${NC}$(printf '%*s' $(( 34 - ${#CI_TITLE} )) '')${BOLD}║${NC}"
elif [[ "$EFFECTIVE_PASS" == true ]]; then
    echo -e "${BOLD}║${NC}  ${GREEN}${BOLD}✓ ${CI_TITLE} PASSED${NC} ${YELLOW}(⚠ infra)${NC}$(printf '%*s' $(( 20 - ${#CI_TITLE} )) '')${BOLD}║${NC}"
elif [[ "$CONCLUSION" == "failure" ]]; then
    echo -e "${BOLD}║${NC}  ${RED}${BOLD}✗ ${CI_TITLE} FAILED${NC}$(printf '%*s' $(( 34 - ${#CI_TITLE} )) '')${BOLD}║${NC}"
else
    echo -e "${BOLD}║${NC}  ${RED}${BOLD}✗ ${CI_TITLE} FAILED${NC} ${YELLOW}(${CONCLUSION})${NC}$(printf '%*s' $(( 20 - ${#CI_TITLE} )) '')${BOLD}║${NC}"
fi

echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Run:" "#$RUN_ID"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Ref:" "$REF"
printf  "${BOLD}║${NC} %-14s %-30s${BOLD}║${NC}\n" "Started:" "$CI_START_DISPLAY"

if [[ "$HAS_AMD64" == true ]]; then
    echo -e "${BOLD}║${NC}                                              ${BOLD}║${NC}"
    printf  "${BOLD}║${NC} ${CYAN}${BOLD}%-44s${NC}${BOLD}║${NC}\n" "AMD64"
    printf  "${BOLD}║${NC}   %-12s %-30s${BOLD}║${NC}\n" "Jobs:" "$AMD64_JOBS_TOTAL total, $AMD64_JOBS_FAILED failed"
    printf  "${BOLD}║${NC}   %-12s %-30s${BOLD}║${NC}\n" "Tests:" "${AMD64_PASSED} pass, ${AMD64_FAILED} fail, ${AMD64_SKIPPED} skip"
    printf  "${BOLD}║${NC}   %-12s %-30s${BOLD}║${NC}\n" "Duration:" "$AMD64_DURATION"
fi

if [[ "$HAS_ARM64" == true ]]; then
    echo -e "${BOLD}║${NC}                                              ${BOLD}║${NC}"
    printf  "${BOLD}║${NC} ${CYAN}${BOLD}%-44s${NC}${BOLD}║${NC}\n" "ARM64"
    printf  "${BOLD}║${NC}   %-12s %-30s${BOLD}║${NC}\n" "Jobs:" "$ARM64_JOBS_TOTAL total, $ARM64_JOBS_FAILED failed"
    printf  "${BOLD}║${NC}   %-12s %-30s${BOLD}║${NC}\n" "Tests:" "${ARM64_PASSED} pass, ${ARM64_FAILED} fail, ${ARM64_SKIPPED} skip"
    printf  "${BOLD}║${NC}   %-12s %-30s${BOLD}║${NC}\n" "Duration:" "$ARM64_DURATION"
    printf  "${BOLD}║${NC}   %-12s %-30s${BOLD}║${NC}\n" "VMSS:" "$CAPACITY instances ($ACTIVE_SKU)"
fi

echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
printf  "${BOLD}║${NC} %-44s${BOLD}║${NC}\n" "https://github.com/$REPO/actions/runs/$RUN_ID"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"

# Show failed jobs if any
if [[ "$JOBS_FAILED" -gt 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}Failed jobs:${NC}"
    echo "$RUN_JSON" | jq -r '.jobs[] | select(.conclusion == "failure") | "  ✗ " + .name' 2>/dev/null
fi

# Show failed tests if any
if [[ "$TOTAL_FAILED" -gt 0 ]] && [[ -n "$FAILED_TESTS" ]]; then
    echo ""
    echo -e "${RED}${BOLD}Failed tests:${NC}"
    echo "$FAILED_TESTS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 9: Send notifications
# ═══════════════════════════════════════════════════════════════════════════════

# --- Teams webhook notification ---
if [[ -n "$WEBHOOK_URL" ]] && [[ "$NO_NOTIFY" == false ]]; then
    log "Sending Teams notification..."

    if [[ "$EFFECTIVE_PASS" == true ]] && [[ "$INFRA_ISSUE" == false ]]; then
        STATUS_EMOJI="✅"
        STATUS_TEXT="PASSED"
        STATUS_COLOR="Good"
    elif [[ "$EFFECTIVE_PASS" == true ]]; then
        STATUS_EMOJI="✅"
        STATUS_TEXT="PASSED  ⚠️ infra issue"
        STATUS_COLOR="Good"
    else
        STATUS_EMOJI="❌"
        STATUS_TEXT="FAILED"
        STATUS_COLOR="Attention"
    fi

    # Build per-platform sections for the card
    PLATFORM_SECTIONS=""

    if [[ "$HAS_AMD64" == true ]]; then
        AMD64_FAILED_ITEMS=""
        if [[ "$AMD64_FAILED" -gt 0 ]] && [[ -n "$AMD64_FAILED_TESTS" ]]; then
            while IFS= read -r ft; do
                [[ -z "$ft" ]] && continue
                ft_clean=$(echo "$ft" | sed 's/^  - //')
                AMD64_FAILED_ITEMS="${AMD64_FAILED_ITEMS},{\"type\":\"TextBlock\",\"text\":\"❌ ${ft_clean}\",\"wrap\":true,\"spacing\":\"None\"}"
            done <<< "$AMD64_FAILED_TESTS"
        fi
        PLATFORM_SECTIONS="${PLATFORM_SECTIONS},{\"type\":\"TextBlock\",\"text\":\"AMD64\",\"weight\":\"Bolder\",\"spacing\":\"Medium\"},{\"type\":\"FactSet\",\"facts\":[{\"title\":\"Jobs\",\"value\":\"${AMD64_JOBS_TOTAL} total, ${AMD64_JOBS_FAILED} failed\"},{\"title\":\"Tests\",\"value\":\"${AMD64_PASSED} passed, ${AMD64_FAILED} failed, ${AMD64_SKIPPED} skipped\"},{\"title\":\"Duration\",\"value\":\"${AMD64_DURATION}\"}]}${AMD64_FAILED_ITEMS}"
    fi

    if [[ "$HAS_ARM64" == true ]]; then
        ARM64_FAILED_ITEMS=""
        if [[ "$ARM64_FAILED" -gt 0 ]] && [[ -n "$ARM64_FAILED_TESTS" ]]; then
            while IFS= read -r ft; do
                [[ -z "$ft" ]] && continue
                ft_clean=$(echo "$ft" | sed 's/^  - //')
                ARM64_FAILED_ITEMS="${ARM64_FAILED_ITEMS},{\"type\":\"TextBlock\",\"text\":\"❌ ${ft_clean}\",\"wrap\":true,\"spacing\":\"None\"}"
            done <<< "$ARM64_FAILED_TESTS"
        fi
        PLATFORM_SECTIONS="${PLATFORM_SECTIONS},{\"type\":\"TextBlock\",\"text\":\"ARM64\",\"weight\":\"Bolder\",\"spacing\":\"Medium\"},{\"type\":\"FactSet\",\"facts\":[{\"title\":\"Jobs\",\"value\":\"${ARM64_JOBS_TOTAL} total, ${ARM64_JOBS_FAILED} failed\"},{\"title\":\"Tests\",\"value\":\"${ARM64_PASSED} passed, ${ARM64_FAILED} failed, ${ARM64_SKIPPED} skipped\"},{\"title\":\"Duration\",\"value\":\"${ARM64_DURATION}\"},{\"title\":\"VMSS\",\"value\":\"${CAPACITY} instances (${ACTIVE_SKU})\"}]}${ARM64_FAILED_ITEMS}"
    fi

    CARD_JSON=$(cat <<CARDJSON
{
  "type": "message",
  "attachments": [
    {
      "contentType": "application/vnd.microsoft.card.adaptive",
      "contentUrl": null,
      "content": {
        "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": [
          {
            "type": "TextBlock",
            "size": "Medium",
            "weight": "Bolder",
            "text": "${STATUS_EMOJI} ${CI_TITLE} ${STATUS_TEXT}",
            "style": "heading",
            "color": "${STATUS_COLOR}"
          },
          {
            "type": "FactSet",
            "facts": [
              {"title": "Run", "value": "#${RUN_ID}"},
              {"title": "Ref", "value": "${REF}"},
              {"title": "Started", "value": "${CI_START_DISPLAY}"}
            ]
          }${PLATFORM_SECTIONS}
        ],
        "actions": [
          {
            "type": "Action.OpenUrl",
            "title": "View Run",
            "url": "https://github.com/${REPO}/actions/runs/${RUN_ID}"
          }
        ]
      }
    }
  ]
}
CARDJSON
)

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$CARD_JSON" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "202" ]]; then
        ok "Teams notification sent"
    else
        warn "Teams webhook returned HTTP $HTTP_CODE"
    fi
fi

# Clean up artifacts temp dir
rm -rf "$RESULTS_DIR" 2>/dev/null || true

# Exit with appropriate code
if [[ "$CONCLUSION" == "success" ]]; then
    exit 0
else
    exit 1
fi
