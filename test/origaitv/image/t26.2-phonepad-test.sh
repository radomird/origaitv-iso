#!/bin/bash
#
# T26.2: a phone in game mode is one more controller a game sees, on an
# installed box (ADR-113). And with its switch off, as it lands, there's
# nothing there.
#
# The phone is a stand-in, the box's own origaitv-phone-call, which signs and
# seals as a phone does and opens game mode as an app would, over the box's
# address on the network. The game is a stand-in too: Steam's stand-in
# window in its stand-in gamescope (as S3.5 has them), with a reader beside
# it that does what a game does with controllers (pad-reader.py): it counts
# the devices udev marked as joysticks and reads the phone's. So the path is
# the box's own: the daemon's phone port, the input helper making a real
# uinput device, udev, and the device read by the person logged in on the
# screen.
#
#   - Off: game mode's address answers a paired phone as one that isn't
#     there, and anybody else as any address does. The state says nothing of
#     games or controllers, and the input helper's own address isn't there.
#   - On: a phone that opens game mode is one more controller the game sees,
#     with the buttons, the axes and the ids of the wired controller games
#     know, readable by the person on the screen and nobody else.
#   - The game takes a press from the phone, and the stick as the d-pad too.
#   - How long a press takes to reach the controller and be answered, on
#     the box, 200 times.
#   - The state says the game in front and one controller.
#   - A short press of Home is the game's own, and held it goes home.
#   - The controller goes when the phone closes game mode, when the phone
#     stops dead, when it's there and says nothing for 5 s, and when the
#     switch is turned off.
# A real game played from a real phone over the Wi-Fi is the NUC's (T26.3).

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

NAME="OrigaiTV phone controller"

start_vm_from_base
wait_for_ssh 300 failure-t26.2-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-t26.2-no-tv"; check "the TV session came up" false; stop_vm; finish; }
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
wait_home 60 >/dev/null || true

# wait_front <role> <seconds>: until <role> is in front.
wait_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] && return 0
    sleep 0.3
  done
  return 1
}

# stays_front <role> <seconds>: <role> is in front for that long.
stays_front() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    [[ $(front '.front.role // ""') == "$1" ]] || return 1
    sleep 0.5
  done
  return 0
}

# How many times the screen daemon went home for a held guide button.
held_count() {
  guest "journalctl --user -b --no-pager -u origaitv-screen | grep -c 'guide button held'" 2>/dev/null | tail -n 1 || true
}

# A phone, paired with a code the box shows for it.
address=$(ssh_guest "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n 1" 2>/dev/null || true)
phone="http://$address:3001"
phone_key=$(ssh_guest "ORIGAITV_PHONE_URL=$phone origaitv-phone-call pair-new 'test phone'" 2>"$RUN_DIR/pair.log" || true)
check "a phone pairs" test -n "$phone_key"

# call <METHOD> <path>: one request as the phone, with the answer printed
# whatever its status, and then the command's own exit status.
call() {
  ssh_guest "ORIGAITV_PHONE_URL=$phone origaitv-phone-call --errors $phone_key $1 $2; echo \" exit \$?\"" 2>/dev/null | tr -d '\n' || true
}
# pad <step>...: the phone in game mode, doing each step. It comes back when
# the phone has closed game mode.
pad() {
  ssh_guest "ORIGAITV_PHONE_URL=$phone origaitv-phone-call $phone_key pad $*"
}
# pad_start <log> <step>...: the same, left running, with what it prints in
# <log> on the box.
pad_start() {
  local log="$1"
  shift
  ssh_guest "(ORIGAITV_PHONE_URL=$phone nohup origaitv-phone-call $phone_key pad $* >$log 2>&1 &)"
}
state() {
  ssh_guest "ORIGAITV_PHONE_URL=$phone origaitv-phone-call $phone_key GET /api/phone/state" 2>/dev/null || true
}
# wait_state <jq filter> <seconds>: until the phone's state fits.
wait_state() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    jq -e "$1" <<<"$(state)" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
# Asks an address for a WebSocket with nothing to say who's asking, and
# prints the status.
stranger() {
  local as=""
  [[ -n ${3:-} ]] && as="-H '$3'"
  ssh_guest "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Connection: Upgrade' -H 'Upgrade: $2' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==' $as '$1'" 2>/dev/null || true
}
# The phone's controller's event device, once udev has marked it as a
# joystick.
pad_device() {
  # shellcheck disable=SC2016 # expanded on the box
  ssh_guest 'for node in /sys/class/input/event*; do
    [[ $(cat "$node/device/name" 2>/dev/null) == "'"$NAME"'" ]] || continue
    grep -qx "E:ID_INPUT_JOYSTICK=1" "/run/udev/data/c$(cat "$node/dev")" 2>/dev/null && echo "/dev/input/${node##*/}"
  done' 2>/dev/null | head -n 1 || true
}
# wait_device <there|gone> <seconds>: until the controller is, or isn't.
# Prints the device when it's there.
wait_device() {
  local started=$SECONDS device
  while (( SECONDS - started < $2 )); do
    device=$(pad_device)
    if [[ $1 == there && -n $device ]]; then
      echo "$device"
      return 0
    fi
    [[ $1 == gone && -z $device ]] && return 0
    sleep 0.5
  done
  return 1
}
# What the game's reader has seen so far.
reader() {
  ssh_guest "cat /tmp/origaitv-pad-reader.log" 2>/dev/null || true
}
# wait_reader <regex> <seconds>: until a line of the reader's fits.
wait_reader() {
  local started=$SECONDS
  while (( SECONDS - started < $2 )); do
    grep -Eq "$1" <<<"$(reader)" && return 0
    sleep 0.5
  done
  return 1
}

# --- Off, as it lands ----------------------------------------------------------

features=$(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/features" 2>/dev/null || true)
check "T26.2 the phonepad switch is there, and off" test "$(jq -r '.phonepad' <<<"$features" 2>/dev/null)" = "false"
off=$(call GET /api/phone/pad)
nowhere=$(call GET /api/phone/nothing-here)
log "Off, game mode's address answers a paired phone: $off"
check "T26.2 with it off, game mode's address answers a paired phone 404" grep -q '"error":"not found"}.* exit 22$' <<<"$off"
check "T26.2 exactly as an address that isn't there does" test "$off" = "$nowhere"
refused=$(pad wait:0.1 2>&1 || true)
check "T26.2 and game mode doesn't open ($refused)" grep -q "the box answered 404" <<<"$refused"
check "to anybody else it answers as any address does" test "$(stranger "$phone/api/phone/pad" websocket)" = "$(stranger "$phone/api/phone/nothing-here" websocket)"
check "which is that they aren't paired" test "$(stranger "$phone/api/phone/pad" websocket)" = "401"
check "the input helper's own address isn't there either" test "$(stranger http://127.0.0.1:3000/api/pads origaitv-pads 'X-OrigaiTV-Screen: 1')" = "404"
said=$(state)
check "T26.2 the state says nothing of controllers or of a game" jq -e '(has("controllers") | not) and (.tv | has("game") | not)' <<<"$said"
check "and no controller is on the box" test -z "$(pad_device)"

# --- On ------------------------------------------------------------------------

# A switch that's off by default turns on on edge only. The file is all the
# daemon reads of it, so the box's packages stay where they come from.
ssh_sudo "install -d -m 755 /etc/origaitv && echo edge >/etc/origaitv/channel" >"$RUN_DIR/channel.log" 2>&1 || true
guest "origaitv feature on phonepad" >"$RUN_DIR/feature.log" 2>&1 || true
check "T26.2 the switch turns on" test "$(ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/features" 2>/dev/null | jq -r '.phonepad' 2>/dev/null)" = "true"
check "the udev rule for the phone's controller is installed" ssh_guest "test -f /usr/lib/udev/rules.d/70-origaitv-phonepad.rules"

# The stand-ins for Steam and gamescope, where their own packages put them,
# on this throwaway box only (s3.5-steam-test.sh says why each is one). This
# Steam has the reader beside it: the part of a game that reads controllers.
ssh_guest "cat >/tmp/origaitv-pad-reader.py" <"$DIR/pad-reader.py"
ssh_guest "cat >/tmp/steam" <<STEAM
#!/bin/bash
# A stand-in for Steam in OrigaiTV's image checks: a full-screen window, drawn
# without a GPU, until /tmp/origaitv-steam-quit appears, as Exit Steam does,
# and a reader of the phone's controller, as a game reads one.
rm -f /tmp/origaitv-steam-quit
python3 -I /tmp/origaitv-pad-reader.py "$NAME" >/tmp/origaitv-pad-reader.log 2>&1 &
reader=\$!
mpv --vo=wlshm --idle=yes --force-window=yes --fs --no-audio --no-terminal --title=steam-stand-in &
window=\$!
sleep 3
if ! kill -0 "\$window" 2>/dev/null; then
  chromium --ozone-platform=wayland --user-data-dir=/tmp/origaitv-steam-stand-in --no-first-run --kiosk \\
    "data:text/html,<title>steam-stand-in</title><body style='background:%23123'>" &
  window=\$!
fi
while [[ ! -e /tmp/origaitv-steam-quit ]] && kill -0 "\$window" 2>/dev/null; do sleep 0.2; done
kill "\$window" "\$reader" 2>/dev/null
wait "\$window" 2>/dev/null
exit 0
STEAM
ssh_guest "cat >/tmp/gamescope" <<'GAMESCOPE'
#!/bin/bash
# A stand-in for gamescope in OrigaiTV's image checks, which have no GPU: it
# runs what comes after --, and it ends when that does, as gamescope does.
while (( $# > 0 )) && [[ $1 != "--" ]]; do shift; done
shift
"$@"
GAMESCOPE
ssh_sudo "install -m 755 /tmp/steam /usr/bin/steam && install -m 755 /tmp/gamescope /usr/bin/gamescope"

guest "origaitv screen open steam" >>"$RUN_DIR/screen.log" 2>&1 || true
up=no
wait_front game 90 && up=yes
check "the stand-in game opens in front" test "$up" = yes
wait_reader '^controllers [0-9]+$' 15 || true
before=$(grep -E '^controllers [0-9]+$' <<<"$(reader)" | tail -n 1 | awk '{ print $2 }')
log "The game sees ${before:-no answer about} controllers before any phone is one"

# The input helper asks the daemon for its connection every 15 s while the
# switch is off, so game mode opens within that of it turning on.
opened=no
started=$SECONDS
while (( SECONDS - started < 60 )); do
  if pad wait:0.2 >"$RUN_DIR/pad-first.log" 2>&1; then
    opened=yes
    break
  fi
  sleep 2
done
check "T26.2 with it on, a paired phone opens game mode ($(tr '\n' ' ' <"$RUN_DIR/pad-first.log"))" test "$opened" = yes
check "and its controller is gone again once it closes" wait_device gone 5

# The phone in game mode for a while: it waits, presses A, and pushes the
# stick right and up.
pad_start /tmp/origaitv-pad-1.log wait:30 a:0.5 wait:1 stick:1,-1:0.5 wait:3
device=$(wait_device there 8 || true)
check "T26.2 the phone is a controller on the box, which udev marks as a joystick ($device)" test -n "$device"
node=/sys/class/input/${device##*/}/device
ids=$(ssh_guest "cat $node/id/bustype $node/id/vendor $node/id/product $node/id/version" 2>/dev/null | tr '\n' ' ' || true)
check "it has the ids of the wired controller games know ($ids)" test "$ids" = "0003 045e 028e 0114 "
keys=$(ssh_guest "cat $node/capabilities/key" 2>/dev/null || true)
axes=$(ssh_guest "cat $node/capabilities/abs" 2>/dev/null || true)
check "and its buttons: A, B, X, Y, two shoulders, View, Menu, the guide button and the stick clicks ($keys)" test "$keys" = "7cdb000000000000 0 0 0 0"
check "and its axes: two sticks, two triggers and the d-pad ($axes)" test "$axes" = "3003f"
check "the person logged in on the screen can read it" ssh_guest "test -r '$device'"
check "and somebody else on the box can't" ssh_sudo "! sudo -u nobody test -r '$device'"
check "T26.2 the game sees one more controller" wait_reader "^controllers $(( ${before:-0} + 1 ))\$" 10
check "and opens it" wait_reader "^reading $device\$" 10
check "T26.2 the state says one phone is a controller, of four" jq -e '.controllers == { phones: 1, most: 4 }' <<<"$(state)"
# The screen daemon asks whether the switch is on every 15 s.
game=no
wait_state '.tv.game.id == "steam" and .tv.front == "app"' 20 && game=yes
check "T26.2 and that a game is in front ($(jq -c '.tv.game' <<<"$(state)" 2>/dev/null))" test "$game" = yes
capture_console "success-t26.2-game-mode"

# The press, and the stick, as the game read them.
check "T26.2 the game takes a press from the phone: A down" wait_reader '^key 304 1 ' 40
check "T26.2 and A up" wait_reader '^key 304 0 ' 5
check "the stick, right and up" wait_reader '^abs 0 32767 ' 10
wait_reader '^abs 17 0 ' 5 || true
seen=$(reader | awk '$1 == "key" || $1 == "abs" { printf "%s %s %s, ", $1, $2, $3 }')
log "The game read: $seen"
check "T26.2 the stick is the d-pad too: right, then up, then back" \
  grep -q 'abs 0 32767, abs 16 1, abs 1 -32767, abs 17 -1, abs 0 0, abs 16 0, abs 1 0, abs 17 0, $' <<<"$seen"
check "in the order the phone sent them, the button first" grep -q '^key 304 1, key 304 0, abs 0 32767, ' <<<"$seen"
# The phone closes game mode at the end of its steps.
check "T26.2 the controller goes when the phone closes game mode" wait_device gone 15
check "and the game sees it go" wait_reader "^gone $device\$" 5
ssh_guest "cat /tmp/origaitv-pad-1.log" >"$RUN_DIR/pad-1.log" 2>&1 || true
check "the phone heard that each press was taken ($(tr '\n' ' ' <"$RUN_DIR/pad-1.log"))" grep -q '"step":"a:0.5","ms":\[' "$RUN_DIR/pad-1.log"
check "the state says no phone is a controller now" jq -e '.controllers.phones == 0' <<<"$(state)"

# How long a press takes: from the phone sending it to the phone hearing
# that the controller took it, over the box's own address. The Wi-Fi's part
# is the NUC's to measure (T26.3).
pad time:200 >"$RUN_DIR/pad-time.log" 2>&1 || true
timing=$(grep '"presses"' "$RUN_DIR/pad-time.log" || true)
log "200 presses, there and back, on the box: $timing"
check "T26.2 a press reaches the controller and is answered within 50 ms, 19 times in 20 ($(jq -r '"median \(.median) ms, 95th \(.p95) ms, slowest \(.slowest) ms"' <<<"$timing" 2>/dev/null))" \
  jq -e '.presses == 200 and .p95 < 50' <<<"$timing"

# The guide button, by a real controller's rule: a short press is the
# game's own, and held it goes home.
guest "origaitv screen open steam" >>"$RUN_DIR/screen.log" 2>&1 || true
wait_front game 15 || true
pad home:0.2 wait:3 >"$RUN_DIR/pad-tap.log" 2>&1 || true
check "T26.2 a short press of Home leaves the game in front" test "$(front '.front.role // ""')" = "game"
check "nothing went home for a held guide button so far" test "$(held_count)" = "0"
pad_start /tmp/origaitv-pad-hold.log home:6
home=no
wait_front home 5 && home=yes
check "T26.2 Home held goes home from the game, while it's still down" test "$home" = yes
check "the hold went home once" test "$(held_count)" = "1"
check "the game keeps running behind home" ssh_guest "pgrep -f 'steam-stand-i[n]' >/dev/null"
wait_device gone 15 || true

# A phone that stops dead: its connection ends, and the controller with it.
pad_start /tmp/origaitv-pad-dead.log wait:60
device=$(wait_device there 8 || true)
check "a second game mode makes a controller again ($device)" test -n "$device"
ssh_guest "pkill -KILL -f 'phone-call.ts .* pa[d]'" || true
check "T26.2 a phone that stops dead loses its controller at once" wait_device gone 3

# A phone that's there and says nothing: the connection stays open, and
# after 5 s the TV takes the controller away.
pad_start /tmp/origaitv-pad-quiet.log wait:60
device=$(wait_device there 8 || true)
check "a third game mode makes a controller again ($device)" test -n "$device"
ssh_guest "pkill -STOP -f 'phone-call.ts .* pa[d]'" || true
stopped=$SECONDS
check "T26.2 a phone that says nothing loses its controller" wait_device gone 12
took=$(( SECONDS - stopped ))
check "after about 5 s, not at once (it took $took s)" test "$took" -ge 3
ssh_guest "pkill -KILL -f 'phone-call.ts .* pa[d]'" || true
check "the daemon said why" ssh_guest "journalctl -b --no-pager -u origaitv-daemon | grep -q 'controller 1 is gone (nothing for a while)'"

# --- Off again -------------------------------------------------------------------

pad_start /tmp/origaitv-pad-off.log wait:60
device=$(wait_device there 8 || true)
check "a fourth game mode makes a controller again ($device)" test -n "$device"
guest "origaitv feature off phonepad" >>"$RUN_DIR/feature.log" 2>&1 || true
check "T26.2 turned off, the controller goes with it" wait_device gone 5
check "T26.2 and game mode's address isn't there again" grep -q '"error":"not found"}.* exit 22$' <<<"$(call GET /api/phone/pad)"
check "nor the input helper's" test "$(stranger http://127.0.0.1:3000/api/pads origaitv-pads 'X-OrigaiTV-Screen: 1')" = "404"

ssh_guest "cat /tmp/origaitv-pad-reader.log" >"$RUN_DIR/pad-reader.log" 2>&1 || true
ssh_guest "journalctl -b --no-pager -u origaitv-daemon | grep 'phone controllers'" >"$RUN_DIR/daemon.log" 2>&1 || true
guest "journalctl --user -b --no-pager -u origaitv-screen -u origaitv-input" >"$RUN_DIR/screen-input.log" 2>&1 || true
ssh_guest "touch /tmp/origaitv-steam-quit" || true
stop_vm
finish
