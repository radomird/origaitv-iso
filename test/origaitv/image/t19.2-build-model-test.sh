#!/bin/bash
#
# A build runs on the model picked for it (ADR-103, T19.2). The daemon's
# start, as "Make X?" leaves it, names a model; root's hand-over checks it
# against the provider's list and starts the build in its sandbox. A
# stand-in for Claude Code, in the builder's home where the real one would
# be, keeps the command line it was given and says which model it started
# on, as the real one's first line does. A start that names a model off the
# list is refused before anything runs. The real CLI, on a real plan, is
# the NUC's (T19.3).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

HOME_DIR=/var/lib/origaitv/builder
DROP=/var/lib/origaitv/daemon/build-drop
RUN=/run/origaitv-build
BUILD=/var/lib/origaitv/build/local.model-check/1.0.0

start_vm_from_base
wait_for_ssh 300 failure-T19.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true

# The stand-in CLI, as origaitv-builder put it there: signed in to a plan,
# and for a step, its command line kept and a first line naming its model.
ssh_guest "sudo -u origaitv-builder tee $HOME_DIR/stand-in-claude >/dev/null" <<'CLI'
#!/bin/bash
if [[ $1 == auth && $2 == status ]]; then
  echo '{"loggedIn": true, "authMethod": "claude.ai"}'
  exit 0
fi
printf '%s\n' "$@" >"$HOME/model-check-argv"
model=default
while (( $# )); do
  [[ $1 == --model ]] && model=$2
  shift
done
printf '{"type":"system","subtype":"init","tools":[],"model":"%s"}\n' "$model"
printf '{"type":"result","subtype":"success","is_error":false,"result":"done","num_turns":1}\n'
CLI
ssh_guest "sudo -u origaitv-builder bash -c 'mkdir -p $HOME_DIR/.local/bin && install -m 755 $HOME_DIR/stand-in-claude $HOME_DIR/.local/bin/claude && rm $HOME_DIR/stand-in-claude'"

# The daemon's start, on a plan, for the understanding step, with a model.
start() {
  ssh_guest "sudo install -d -m 700 $DROP && printf '%s' '$1' | sudo tee $DROP/start.json >/dev/null"
}
answered() {
  ssh_guest "sudo jq -e --arg build '$1' '.action == \"start\" and .build == \$build' $RUN/answer.json" >/dev/null 2>&1
}
start '{"build":"b19","id":"local.model-check","version":"1.0.0","sentence":"a clock for the kitchen","phase":"understand","recipe":null,"provider":"claude","path":"plan","model":"claude-haiku-5-5","safeguards":true}'
started=$SECONDS
while (( SECONDS - started < 120 )) && ! answered b19; do sleep 2; done
ssh_guest "sudo cat $RUN/answer.json" >"$RUN_DIR/answer.json" 2>&1 || true
while (( SECONDS - started < 240 )) && ! ssh_guest "sudo test -e $HOME_DIR/model-check-argv && ! systemctl list-units --state=active --no-legend 'origaitv-builder@*' | grep -q ." 2>/dev/null; do sleep 2; done
ssh_guest "sudo cat $HOME_DIR/model-check-argv" >"$RUN_DIR/argv.txt" 2>&1 || true
ssh_guest "sudo cat $BUILD/log.jsonl" >"$RUN_DIR/log.jsonl" 2>&1 || true
ssh_guest "sudo cat $BUILD/status.json" >"$RUN_DIR/status.json" 2>&1 || true

# A model that isn't on Claude's list.
start '{"build":"b20","id":"local.model-check","version":"1.0.0","sentence":"a clock for the kitchen","phase":"understand","recipe":null,"provider":"claude","path":"plan","model":"claude-opus-9","safeguards":true}'
started=$SECONDS
while (( SECONDS - started < 120 )) && ! answered b20; do sleep 2; done
ssh_guest "sudo cat $RUN/answer.json" >"$RUN_DIR/refused.json" 2>&1 || true
ssh_guest "sudo journalctl -b -u origaitv-build.service -u 'origaitv-builder@*' --no-pager" >"$RUN_DIR/build.log" 2>&1 || true

model_flag() { grep -qxF -- --model "$RUN_DIR/argv.txt" && [[ $(grep -xA1 -- --model "$RUN_DIR/argv.txt" | tail -n 1) == claude-haiku-5-5 ]]; }

check "root's hand-over took the start with its model" jq -e '.action == "start" and .build == "b19" and .started == true' "$RUN_DIR/answer.json"
check "T19.2 the CLI was started with the build's model on its command line" model_flag
check "T19.2 the build's log says the step ran on that model, as the CLI said" jq -se 'any(.[]; .started == true and .model == "claude-haiku-5-5") and any(.[]; .cliModel == "claude-haiku-5-5")' "$RUN_DIR/log.jsonl"
check "T19.2 root refuses a model that isn't on the provider's list, before anything runs" jq -e '.build == "b20" and .started == false and (.reason | test("model"))' "$RUN_DIR/refused.json"

stop_vm
finish
