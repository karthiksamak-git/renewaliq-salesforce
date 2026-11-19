#!/usr/bin/env bash
#
# One-command RenewalIQ setup on macOS and Linux.
#
# Creates a scratch org from config/project-scratch-def.json, deploys the project,
# assigns every permission set, loads the synthetic demo book, scores it, schedules
# the nightly jobs and opens the org.
#
# Idempotent: an existing scratch org with the same alias is reused, the deploy is
# incremental, the seed script skips accounts that already exist, and the scheduler
# replaces its own jobs instead of adding duplicates. Safe to re-run.
#
#   ./scripts/setup.sh
#   ./scripts/setup.sh --alias riq-demo --duration-days 2 --no-browser
#
set -euo pipefail

ALIAS="renewaliq"
DURATION_DAYS="7"
DEV_HUB=""
OPEN_BROWSER="true"

usage() {
    cat <<'USAGE'
Usage: scripts/setup.sh [options]

  -a, --alias NAME           Scratch org alias (default: renewaliq)
  -d, --duration-days N      Scratch org lifetime in days (default: 7)
  -v, --dev-hub USERNAME     Dev Hub username or alias (default: the CLI's default Dev Hub)
  -n, --no-browser           Do not open the org at the end
  -h, --help                 Show this help
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a | --alias)
            ALIAS="$2"
            shift 2
            ;;
        -d | --duration-days)
            DURATION_DAYS="$2"
            shift 2
            ;;
        -v | --dev-hub)
            DEV_HUB="$2"
            shift 2
            ;;
        -n | --no-browser)
            OPEN_BROWSER="false"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

step() { printf '\n==> %s\n' "$1"; }
detail() { printf '    %s\n' "$1"; }
ok() { printf '    OK: %s\n' "$1"; }
caution() { printf '    WARNING: %s\n' "$1"; }
fail() {
    printf '\nFAILED: %s\n' "$1" >&2
    exit 1
}

# The script must run from the repository root, whatever directory the user started in.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
[ -f sfdx-project.json ] || fail "sfdx-project.json not found in $REPO_ROOT - run this script from inside the repository."

step "Checking prerequisites"

for tool in sf node git; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH. Install it and run this script again."
    ok "$tool found"
done

if command -v java >/dev/null 2>&1; then
    ok "java found"
else
    caution "java not found - setup does not need it, but Apex formatting and PMD do."
fi

step "Finding a Dev Hub"

if [ -z "$DEV_HUB" ]; then
    DEV_HUB="$(sf config get target-dev-hub --json 2>/dev/null | node -e '
        let raw = "";
        process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
            try {
                const value = JSON.parse(raw).result.value;
                if (value) process.stdout.write(value);
            } catch {
                /* no default dev hub configured */
            }
        });
    ')"
fi

if [ -z "$DEV_HUB" ]; then
    DEV_HUB="$(sf org list --json | node -e '
        let raw = "";
        process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
            try {
                const hubs = JSON.parse(raw).result.devHubs || [];
                if (hubs.length > 0) process.stdout.write(hubs[0].username);
            } catch {
                /* ignore */
            }
        });
    ')"
fi

if [ -z "$DEV_HUB" ]; then
    fail "No Dev Hub found. Enable it once in Setup -> Dev Hub -> Enable Dev Hub, then run:
  sf org login web --set-default-dev-hub --alias devhub
and run this script again."
fi

ok "Dev Hub: $DEV_HUB"

step "Scratch org '$ALIAS'"

# Reuse an existing org with this alias so a second run does not burn a scratch org.
ORG_EXISTS="$(sf org list --json | ALIAS="$ALIAS" node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
        const result = JSON.parse(raw).result;
        const orgs = [...(result.nonScratchOrgs || []), ...(result.scratchOrgs || [])];
        const match = orgs.find((org) => org.alias === process.env.ALIAS);
        process.stdout.write(match ? "yes" : "no");
    });
')"

if [ "$ORG_EXISTS" = "yes" ]; then
    ok "Already exists - reusing it."
else
    detail "Creating from config/project-scratch-def.json (about a minute)..."
    sf org create scratch \
        --target-dev-hub "$DEV_HUB" \
        --definition-file config/project-scratch-def.json \
        --alias "$ALIAS" \
        --duration-days "$DURATION_DAYS" \
        --wait 20 >/dev/null || fail "Scratch org creation failed."
    ok "Created $ALIAS."
fi

step "Deploying the project"
sf project deploy start --target-org "$ALIAS" --test-level NoTestRun --wait 45 >/dev/null ||
    fail "Deploy failed. Re-run with the deploy's own output to see which component failed."
ok "Source deployed."

step "Assigning permission sets"
for permission_set in RIQ_Admin RIQ_CSM RIQ_Read_Only RIQ_AI_Insight RIQ_Integration_User; do
    sf org assign permset --name "$permission_set" --target-org "$ALIAS" >/dev/null ||
        fail "Could not assign $permission_set."
    ok "$permission_set"
done

step "Configuring the platform event subscriber"

# A PlatformEventSubscriberConfig names a user, and a scratch org's admin username is
# generated, so it is rendered from the template with this org's username.
USERNAME="$(sf org display --target-org "$ALIAS" --json | node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
        process.stdout.write(JSON.parse(raw).result.username);
    });
')"

SUBSCRIBER_DIR="force-app/main/default/platformEventSubscriberConfigs"
SUBSCRIBER_FILE="$SUBSCRIBER_DIR/RIQ_HealthStatusChangeSubscriber.platformEventSubscriberConfig-meta.xml"
mkdir -p "$SUBSCRIBER_DIR"
sed "s|{{USERNAME}}|$USERNAME|g" \
    config/platform-event/RIQ_HealthStatusChangeSubscriber.platformEventSubscriberConfig-meta.xml.template \
    >"$SUBSCRIBER_FILE"

if sf project deploy start --source-dir "$SUBSCRIBER_DIR" --target-org "$ALIAS" --test-level NoTestRun --wait 10 >/dev/null; then
    ok "Events will run as $USERNAME."
else
    caution 'Not configured - the app works, but Tasks created by the event trigger show "Automated Process" as Created By.'
fi

# The generated file names this one org's user. Leaving it in the tree would make the
# next full deploy to any other org fail with "no User named ... found".
rm -f "$SUBSCRIBER_FILE"

step "Loading the synthetic demo book (50 invented Indian customers)"
sf apex run --file scripts/apex/seed-data.apex --target-org "$ALIAS" >/dev/null || fail "Seeding failed."
ok "Seeded and scored."

step "Running the nightly batch once"
sf apex run --file scripts/apex/run-nightly-batch.apex --target-org "$ALIAS" >/dev/null || fail "Batch did not start."
ok "Batch started (see Setup -> Apex Jobs)."

step "Scheduling the nightly jobs"
sf apex run --file scripts/apex/schedule-jobs.apex --target-org "$ALIAS" >/dev/null || fail "Scheduling failed."
ok "Nightly scoring (02:00) and log cleanup (03:00) scheduled."

if [ "$OPEN_BROWSER" = "true" ]; then
    step "Opening the org"
    sf org open --target-org "$ALIAS" >/dev/null 2>&1 || caution "Could not open a browser; open the org from Setup -> Installed Packages or reuse: sf org open --target-org $ALIAS"
fi

cat <<NEXT

RenewalIQ is ready.

What to click first:
  1. App Launcher (nine dots) -> RenewalIQ
  2. The Command Center opens on its own: KPI tiles, status donut, at-risk table
  3. Open any account -> the health card (gauge, churn %, drivers, trend)
  4. Log a signal on that account and watch the score change

Optional AI summaries:
  Off by default, and the app is complete without it. To turn it on, put a Groq API
  key in Setup -> Named Credentials -> External Credentials -> RIQ LLM API ->
  Principals -> RIQ LLM Principal -> add parameter apiKey, then tick Is Enabled on
  the RIQ AI Config custom metadata record. Never put the key in a file, in source,
  or in this repository.

Scratch org alias: $ALIAS
  delete it later with: sf org delete scratch --target-org $ALIAS --no-prompt
NEXT
