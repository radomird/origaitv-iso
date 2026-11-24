#!/bin/bash
#
# TV setup's apps (board 09): the official apps for what the TV is for come
# from OrigaiTV's signed index, and the one ticked on the TV installs as root,
# through origaitv-setup-apps.path, with `origaitv app install`, while setup
# finishes and home takes over. Then home has it.
#
# The steps before the apps go by on the daemon's own API, as the setup
# screens move them on; the apps step is driven with the TV's keys, as from
# the remote. The box fetches the index and the app from GitHub, as a real
# box does.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# until_json <url path> <jq filter> <seconds>: until the filter on what the
# daemon answers there is true.
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "curl -fsS --max-time 10 http://127.0.0.1:3000$1" 2>/dev/null | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 2
  done
  return 1
}

# until_file <jq filter> <file> <seconds>: until the filter on a file on the
# box is true.
until_file() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(ssh_guest "cat $2 2>/dev/null" | jq -r "$1" 2>/dev/null) == "true" ]] && return 0
    sleep 3
  done
  return 1
}

# setup_post <path> <json>: a step moved on, as the setup screens do it.
setup_post() {
  ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '$2' http://127.0.0.1:3000$1" >>"$RUN_DIR/setup-posts.log" 2>&1
}

start_vm_from_base
wait_for_ssh 300 failure-setup-apps-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
check "setup starts on the welcome screen" until_json /api/setup '.setup.step == "welcome"' 30
check "the hand-over to root is waiting for setup's apps" test "$(ssh_guest "systemctl is-active origaitv-setup-apps.path")" = "active"

setup_post /api/setup/finish '{"step": "welcome", "keyboard": true}'
setup_post /api/setup/ready '{"update": "none"}'
setup_post /api/setup/finish '{"step": "ready"}'
# Your box, on a release that has the step.
setup_post /api/setup/finish '{"step": "box"}' || true
# Where the TV is (ADR-055), on a release that has the step.
setup_post /api/setup/finish '{"step": "country"}' || true
setup_post /api/setup/finish '{"step": "ai"}'
setup_post /api/setup/finish '{"step": "people"}'
setup_post /api/setup/goal '{"goal": "media"}'
setup_post /api/setup/finish '{"step": "goal"}'
check "setup is at its apps" until_json /api/setup '.setup.step == "apps"' 30

# The goal's apps are Jellyfin, Plex and Immich, in that order, each once
# it's in the index.
# shellcheck disable=SC2016 # $f and $id are jq's own
check "the official apps for photos come from the signed index, in the goal's order: Jellyfin first, Immich among them" \
  until_json /api/setup/apps '[.for[].id] as $f | ($f | index("origaitv.jellyfin")) == 0 and ($f | index("origaitv.immich")) != null and ($f == (["origaitv.jellyfin", "origaitv.plex", "origaitv.immich"] | map(select(. as $id | $f | index($id) != null)))) and (.error == null)' 120
ssh_guest "curl -fsS http://127.0.0.1:3000/api/setup/apps" >"$RUN_DIR/setup-apps.json" 2>&1 || true
log "the goal's apps: $(jq -c '[.for[].id]' "$RUN_DIR/setup-apps.json" 2>/dev/null)"
check "the built-in Music is under more" jq -e '[.more[].id] | index("origaitv.music") != null' "$RUN_DIR/setup-apps.json"
# Steam is a game: it's in setup's games group on a box the box check says
# runs games, and offered nowhere on one it says doesn't, as QEMU's VM is.
games=$(ssh_guest "curl -fsS http://127.0.0.1:3000/api/box" 2>/dev/null | jq -r '.verdicts.games // empty' 2>/dev/null || true)
log "the box check says, for games: ${games:-nothing}"
if [[ $games == "none" ]]; then
  check "and Steam isn't offered on a box that isn't for games" jq -e '([.games[]?.id] | index("origaitv.steam") == null) and ([.more[].id] | index("origaitv.steam") == null)' "$RUN_DIR/setup-apps.json"
else
  check "and Steam is in the games group, not under more" jq -e '([.games[]?.id] | index("origaitv.steam") != null) and ([.more[].id] | index("origaitv.steam") == null)' "$RUN_DIR/setup-apps.json"
fi
check "the apps step is on the TV (OCR)" ocr_finds success-setup-apps "pick your apps|build your own|add your own" 30
capture_console "success-setup-apps"

# The goal's second app ticked with the remote's keys, then continue, above
# it. The focus starts on the goal's first app, and the second is always
# beside it; the row wraps at the TV's width, so a third may not be.
ticked=$(jq -r '.for[1].id // "origaitv.immich"' "$RUN_DIR/setup-apps.json" 2>/dev/null || echo origaitv.immich)
for key in right enter up enter; do
  guest "origaitv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
  sleep 1
done
# A server's app, such as Plex, then asks where its server is, from what
# the box finds on the network: "Pick your Plex". There's none in the VM,
# so "Later" carries on. It sits to the right of "Enter the address
# manually", which has the focus, so right then OK. The buttons are too
# faint for OCR to read reliably, so the headline says the page is up. A
# release before setup's new screens had "Later" under "Type its address"
# ("set it up later" before that), so down then OK.
name=$(jq -r '.for[1].name // "plex"' "$RUN_DIR/setup-apps.json" 2>/dev/null || echo plex)
keys=""
if ocr_finds setup-apps-server "pick your ${name,,}|enter the address manually|type its address|set it up later" 30; then
  if grep -Eqi "type its address|set it up later" "$RUN_DIR/setup-apps-server.txt"; then
    keys="down enter"
  else
    keys="right enter"
  fi
fi
if [[ -n $keys ]]; then
  capture_console "success-setup-apps-server"
  for key in $keys; do
    guest "origaitv input key $key" >>"$RUN_DIR/input.log" 2>&1 || true
    sleep 1
  done
fi
# Continue moves setup on: to its look once that step is there, or home.
# The steps after this one have checks of their own, so it skips them.
check "continue moves setup on from its apps" until_json /api/setup '.setup.done or (.setup.step != "apps")' 60
guest "origaitv setup skip" >>"$RUN_DIR/input.log" 2>&1 || true
took=$(wait_home 60) || took=""
check "and home takes over${took:+ (after $took s)}" test -n "$took"

log "Waiting for $ticked to install"
until_file ".apps[\"$ticked\"].state == \"installed\" or .apps[\"$ticked\"].state == \"failed\"" /run/origaitv-setup-apps/state.json 600 || true
ssh_guest "cat /run/origaitv-setup-apps/state.json" >"$RUN_DIR/setup-apps-state.json" 2>&1 || true
ssh_guest "journalctl -u origaitv-setup-apps.service --no-pager" >"$RUN_DIR/setup-apps-service.log" 2>&1 || true
# shellcheck disable=SC2016 # $id is jq's own
check "the ticked app, $ticked, installed as root, from the index ($(jq -r --arg id "$ticked" '.apps[$id] | "\(.state) \(.error // "")"' "$RUN_DIR/setup-apps-state.json" 2>/dev/null))" \
  jq -e --arg id "$ticked" '.apps[$id].state == "installed"' "$RUN_DIR/setup-apps-state.json"
# shellcheck disable=SC2016 # $id is jq's own
check "and only that one" jq -e --arg id "$ticked" '.apps | keys == [$id]' "$RUN_DIR/setup-apps-state.json"
guest "origaitv app list" >"$RUN_DIR/app-list.txt" 2>&1 || true
check "origaitv app list has it" grep -q "^$ticked " "$RUN_DIR/app-list.txt"
check "home has it" until_json /api/home "[.apps[].id] | index(\"$ticked\") != null" 30
check "the daemon's drop is gone" test -z "$(ssh_sudo "ls /var/lib/origaitv/daemon/apps-drop 2>/dev/null")"

stop_vm
finish
