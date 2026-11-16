#!/bin/bash
#
# How much of a plan is used, in % (ADR-103, T19.2). The daemon asks the
# plan router's service, which runs Omarchy's own usage check as
# origaitv-builder, the user that owns the plan's sign-in, with the
# builder's home. A stand-in for omarchy-agent-usage-claude, where Omarchy
# keeps the real one, notes who ran it and whether it could read the
# sign-in, and prints what the real one would: the plan's windows and a
# good deal more, an account and a token mark included. Only the windows
# may reach the daemon, and the daemon's own user can't read the sign-in.
# The real check, on a real plan, is the NUC's (T19.3).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

MARK="origaitv-usage-$RANDOM$RANDOM"
HOME_DIR=/var/lib/origaitv/builder
CHECK=/usr/share/omarchy/bin/omarchy-agent-usage-claude
TV=http://127.0.0.1:3000
PHONE=http://127.0.0.1:3001

start_vm_from_base
wait_for_ssh 300 failure-T19.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true

# The plan's sign-in, as Claude Code keeps it in the builder's home.
ssh_guest "sudo -u origaitv-builder bash -c 'umask 077 && mkdir -p $HOME_DIR/.claude && cat >$HOME_DIR/.claude/.credentials.json'" <<<"{\"claudeAiOauth\": {\"accessToken\": \"sk-ant-oat01-$MARK\"}}"

# The stand-in check, in Omarchy's place.
ssh_guest "sudo tee $CHECK.stand-in >/dev/null" <<CHECK
#!/bin/bash
creds="\$CLAUDE_CONFIG_DIR/.credentials.json"
if [[ -r \$creds ]] && grep -q '$MARK' "\$creds"; then read=yes; else read=no; fi
echo "\$(id -un) \$HOME \$read \$*" >"\$HOME/usage-ran-as"
[[ -f \$HOME/usage-fails ]] && exit 1
printf '{"id":"claude","accountEmail":"$MARK@example.com","tierLabel":"Max","totalPrompts":4321,"token":"$MARK","limits":[{"label":"Session (5-hour)","percent":0.23,"resetsAt":"2030-01-01T10:00:00+00:00"},{"label":"Weekly (7-day)","percent":0.41,"resetsAt":"2030-01-04T10:00:00+00:00"},{"label":"Fable Weekly","title":"Fable Weekly","percent":0.9,"resetsAt":"2030-01-04T10:00:00+00:00"}]}\n'
CHECK
ssh_guest "sudo install -m 755 $CHECK.stand-in $CHECK && sudo rm $CHECK.stand-in"

tv_post() {
  ssh_guest "curl -sS --max-time 60 -X ${3:-POST} -H 'Content-Type: application/json' -d '$2' $TV$1"
}

# Claude's plan, with its terms accepted on a paired phone.
tv_post /api/ai '{"provider": "claude", "path": "plan"}' >"$RUN_DIR/picked.json" 2>&1 || true
phone_key=$(pair_phone 'image check' "$PHONE")
ssh_guest "ORIGAITV_PHONE_URL=$PHONE origaitv-phone-call --errors $phone_key POST /api/phone/terms '{\"provider\": \"claude\", \"path\": \"plan\"}'" >"$RUN_DIR/accepted.json" 2>&1 || true
check "Claude's plan is picked, with its terms accepted on the phone" jq -e '.ok == true' "$RUN_DIR/accepted.json"

ssh_guest "curl -sS --max-time 90 '$TV/api/ai/usage?fresh'" >"$RUN_DIR/usage.json" 2>&1 || true
ssh_guest "sudo cat $HOME_DIR/usage-ran-as" >"$RUN_DIR/ran-as.txt" 2>&1 || true

# The check can't answer: the TV is told nothing, and says it's using the plan.
ssh_guest "sudo -u origaitv-builder touch $HOME_DIR/usage-fails"
ssh_guest "curl -sS --max-time 90 '$TV/api/ai/usage?fresh'" >"$RUN_DIR/no-usage.json" 2>&1 || true
ssh_guest "sudo rm -f $HOME_DIR/usage-fails"

ssh_sudo "journalctl -b --no-pager -u origaitv-daemon -u origaitv-router -u origaitv-router-cli" >"$RUN_DIR/journal.log" 2>&1 || true

ran_as_builder() { [[ $(cut -d' ' -f1-3 "$RUN_DIR/ran-as.txt") == "origaitv-builder $HOME_DIR yes" ]]; }
only_numbers() { ! grep -q -e "$MARK" -e Max -e 4321 -e Fable "$RUN_DIR/usage.json"; }
daemon_cant_read() { ! ssh_guest "sudo -u origaitv-server cat $HOME_DIR/.claude/.credentials.json" >/dev/null 2>&1 && ! ssh_guest "sudo -u origaitv-server ls $HOME_DIR/.claude" >/dev/null 2>&1; }
not_logged() { ! grep -q -e "$MARK" -e 4321 "$RUN_DIR/journal.log"; }

check "T19.2 the daemon has the plan's 5 hours and week, in %, with when each starts over" jq -e '.plan == true and (.usage.windows == [{"window":"hours","hours":5,"percent":23,"resets":"2030-01-01T10:00:00.000Z"},{"window":"week","percent":41,"resets":"2030-01-04T10:00:00.000Z"}])' "$RUN_DIR/usage.json"
check "T19.2 the usage check ran as origaitv-builder, with its home, and read the plan's sign-in there" ran_as_builder
check "T19.2 only the numbers reached the daemon: no account, token, plan name or model's allowance" only_numbers
check "T19.2 the daemon's own user can't read the plan's sign-in" daemon_cant_read
check "a check that can't answer gives the TV nothing, and it says it's using the plan" jq -e '.plan == true and .usage == null' "$RUN_DIR/no-usage.json"
check "the journal has nothing of what the check printed but how many windows" not_logged

stop_vm
finish
