#!/bin/bash
#
# How much of a plan is used, from Omarchy's real usage checks (ADR-103,
# T19.2). t19.2-plan-usage puts a stand-in in the check's place. This one
# runs the real omarchy-agent-usage-claude and -codex, as the box has them,
# inside the plan router's service (origaitv-router-cli), as
# origaitv-builder, with the builder's home. Nothing here needs the network:
# each case is a sign-in the check judges by itself.
#
# - Claude, its token lapsed, with the last numbers kept in its cache: the
#   check prints them, marked stale ("Limits paused"). The TV gets them with
#   when they were read, to show "As of 2 hours ago" under the bars.
# - Claude, its sign-in run out: the TV is told to sign in again.
# - Codex, never signed in: no numbers.
#
# Each run loads Omarchy's own collectors.py and writes the check's own
# cache where the service lets it, in the builder's home. A real plan's
# numbers are the NUC's (T19.3).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

HOME_DIR=/var/lib/origaitv/builder
OMARCHY=/usr/share/omarchy
CACHE=$HOME_DIR/.cache/omarchy/agent-usage
TV=http://127.0.0.1:3000
PHONE=http://127.0.0.1:3001

start_vm_from_base
wait_for_ssh 300 failure-T19.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true

tv_post() {
  ssh_guest "curl -sS --max-time 60 -X POST -H 'Content-Type: application/json' -d '$2' $TV$1"
}

# A plan, picked, with its terms accepted on a paired phone.
phone_key=$(pair_phone 'image check' "$PHONE")
use_plan() {
  tv_post /api/ai "{\"provider\": \"$1\", \"path\": \"plan\"}" >"$RUN_DIR/picked-$1.json" 2>&1 || true
  ssh_guest "ORIGAITV_PHONE_URL=$PHONE origaitv-phone-call --errors $phone_key POST /api/phone/terms '{\"provider\": \"$1\", \"path\": \"plan\"}'" >"$RUN_DIR/accepted-$1.json" 2>&1 || true
}

# Claude Code's sign-in in the builder's home, its token lapsed an hour ago,
# and the sign-in itself good for a day more, or run out a minute ago.
claude_sign_in() {
  local now refresh
  now=$(ssh_guest "date +%s%3N")
  refresh=$(( now + $1 ))
  ssh_guest "sudo -u origaitv-builder bash -c 'umask 077 && mkdir -p $HOME_DIR/.claude && cat >$HOME_DIR/.claude/.credentials.json'" <<<"{\"claudeAiOauth\": {\"accessToken\": \"sk-ant-oat01-stand-in\", \"expiresAt\": $(( now - 3600000 )), \"refreshTokenExpiresAt\": $refresh, \"subscriptionType\": \"max\"}}"
  # The last numbers the check kept, two hours old.
  ssh_guest "sudo -u origaitv-builder bash -c 'umask 077 && mkdir -p $CACHE && cat >$CACHE/claude-limits.json'" <<<"{\"fetchedAtMs\": $(( now - 7200000 )), \"limits\": [{\"label\": \"Session (5-hour)\", \"percent\": 0.23, \"resetsAt\": \"2030-01-01T10:00:00+00:00\"}, {\"label\": \"Weekly (7-day)\", \"percent\": 0.41, \"resetsAt\": \"2030-01-04T10:00:00+00:00\"}]}"
}

usage() {
  ssh_guest "curl -sS --max-time 90 '$TV/api/ai/usage?fresh'"
}

journal() {
  ssh_sudo "journalctl -b --no-pager -u origaitv-router-cli" >"$RUN_DIR/journal.log" 2>&1 || true
}

ssh_guest "ls -l $OMARCHY/bin/omarchy-agent-usage-claude $OMARCHY/bin/omarchy-agent-usage-codex $OMARCHY/shell/plugins/agents/collectors.py" >"$RUN_DIR/checks.txt" 2>&1 || true
check "Omarchy's own usage checks, and their collectors, are where the plan's service runs them" \
  ssh_guest "test -x $OMARCHY/bin/omarchy-agent-usage-claude && test -x $OMARCHY/bin/omarchy-agent-usage-codex && test -f $OMARCHY/shell/plugins/agents/collectors.py"

use_plan claude
check "Claude's plan is picked, with its terms accepted on the phone" jq -e '.ok == true' "$RUN_DIR/accepted-claude.json"

# The token lapsed, the sign-in still good: the kept numbers, with when they
# were read.
claude_sign_in 86400000
usage >"$RUN_DIR/paused.json" 2>&1 || true
journal
ssh_guest "sudo find $CACHE -maxdepth 1 -name 'claude-scan-*.json' -user origaitv-builder -newer $HOME_DIR/.claude/.credentials.json" >"$RUN_DIR/scan-cache.txt" 2>&1 || true

check "T19.2 the real Claude check ran in the plan's service and said its limits are paused, with the numbers it kept" grep -q "usage claude: kept numbers, limits paused" "$RUN_DIR/journal.log"
# By the box's own clock, which the kept numbers were stamped by.
read_two_hours_ago() { jq -e --argjson now "$(ssh_guest 'date +%s')" '(.usage.asOf | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at | ($now - $at) > 6600 and ($now - $at) < 8400' "$RUN_DIR/paused.json"; }
check "T19.2 the TV gets the kept 5 hours and week, and when they were read" jq -e '.plan == true and ([.usage.windows[] | [.window, .percent]] == [["hours", 23], ["week", 41]])' "$RUN_DIR/paused.json"
check "read two hours ago, when the check kept them" read_two_hours_ago
check "T19.2 the check loaded Omarchy's collectors and wrote its own cache in the builder's home, where the service lets it" test -s "$RUN_DIR/scan-cache.txt"

# The sign-in ran out: the TV is told to sign in again, with no numbers.
claude_sign_in -60000
usage >"$RUN_DIR/expired.json" 2>&1 || true
journal
check "T19.2 a Claude sign-in that ran out comes to the TV as that, with no numbers" jq -e '.plan == true and .usage.signIn == "expired" and .usage.windows == []' "$RUN_DIR/expired.json"
check "and the plan's service says so in its log" grep -q "usage claude: sign-in expired" "$RUN_DIR/journal.log"

# Codex, never signed in on this box: no numbers.
use_plan chatgpt
check "ChatGPT's plan is picked, with its terms accepted on the phone" jq -e '.ok == true' "$RUN_DIR/accepted-chatgpt.json"
usage >"$RUN_DIR/codex.json" 2>&1 || true
journal
check "T19.2 the real Codex check ran in the plan's service, and with no sign-in the TV gets no numbers" jq -e '.plan == true and (.usage == null or (.usage.windows == [] and .usage.signIn != null))' "$RUN_DIR/codex.json"
check "and the plan's service logged what kind of answer it was, not that the check failed" grep -E -q "usage chatgpt: (no windows|old numbers|no numbers|not signed in)" "$RUN_DIR/journal.log"

not_logged() { ! grep -q -F -e "sk-ant-oat01" -e "Session (5-hour)" -e "Weekly (7-day)" "$RUN_DIR/journal.log"; }
check "the journal has nothing of what the checks printed, and no token" not_logged

stop_vm
finish
