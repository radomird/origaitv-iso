#!/bin/bash
#
# T22.2: Fit to screen (ADR-103) at standard's 1920 x 1080 canvas, where a
# TV that crops its edges would cut a page off. The VM offers 4K too, which
# the box picks, at scale 2: everything here is in the canvas's logical
# pixels, the same as on a 1080p TV at scale 1. The margin is 3 percent on
# each side to start with:
#   - Hyprland keeps it as the monitor's reserved area, 58 by 32;
#   - a stand-in service page is maximized inside it, so its window's
#     corners are 58 and 32 in from the screen's, and the page is that size;
#   - the page asking for full screen, as a player does, stays inside it;
#   - home stays full screen, its picture to the edges;
#   - a bigger margin picked in Settings moves the page in at once, without
#     setting the TV's mode again;
#   - and after a restart the TV session starts with that margin, from the
#     line the screen daemon kept, and the page is inside it again.
# About two minutes from the night's box, most of it the restart.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# Upstream's start_vm_from_base, with virtio-gpu's screen at 1920 x 1080: the
# preferred mode in the EDID it gives the box, as a 1080p TV's is.
qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
if [[ $FIRMWARE == uefi ]]; then
  cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
  # shellcheck disable=SC2034 # start_vm in base-test.sh reads it
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
fi
start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log" -global virtio-gpu-device.xres=1920 -global virtio-gpu-device.yres=1080

wait_for_ssh 300 failure-T22.2-ssh-timeout || exit 1
wait_tv 300 >/dev/null || { capture_console "failure-T22.2-no-tv"; check "the TV session came up" false; stop_vm; finish; }
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

# Hyprland's view of the screen: the first monitor that's on.
monitor() {
  guest_hyprctl "-j monitors" 2>/dev/null | jq -r "first(.[] | select(.disabled != true)) | $1" 2>/dev/null || true
}
display() {
  ssh_guest "curl -fsS --max-time 5 http://127.0.0.1:3000/api/display" 2>/dev/null | jq -r "$1" 2>/dev/null || true
}
# The window in front, as Hyprland places it: "x y width height", logical.
front_box() {
  local address
  address=$(front '.front.address // ""')
  guest_hyprctl "-j clients" 2>/dev/null | jq -r --arg a "$address" 'first(.[] | select(.address == $a)) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' 2>/dev/null || true
}
front_fullscreen() {
  local address
  address=$(front '.front.address // ""')
  guest_hyprctl "-j clients" 2>/dev/null | jq -r --arg a "$address" 'first(.[] | select(.address == $a)) | .fullscreen' 2>/dev/null || true
}
# wait_for <seconds> <command...>: until the command passes.
wait_for() {
  local started=$SECONDS limit=$1
  shift
  while (( SECONDS - started < limit )); do
    "$@" && return 0
    sleep 0.5
  done
  return 1
}
reserved_is() {
  [[ $(monitor '.reserved | join(" ")') == "$1" ]]
}
front_is() {
  [[ $(front_box) == "$1" ]]
}
title_is() {
  [[ $(front '.front.title // ""') =~ $1 ]]
}

guest_hyprctl "-j monitors" >"$RUN_DIR/monitors-before.json" 2>&1 || true
check "the TV's canvas is standard's 1920 by 1080 (it runs $(monitor '"\(.width)x\(.height) at \(.scale)"'))" \
  test "$(monitor '"\(.width / .scale | round)x\(.height / .scale | round)"')" = "1920x1080"

# On to start with: 3 percent, 58 by 32 at 1080p.
check "T22.2 Fit to screen is on to start with: a margin of 3 (it's $(display .margin), $(display '.inset | join(" by ")'))" \
  test "$(display '"\(.margin) \(.inset | join(" "))"')" = "3 58 32"
check "T22.2 Hyprland keeps it as the monitor's reserved area (left, top, right, bottom: $(monitor '.reserved | join(" ")'))" \
  wait_for 15 reserved_is "58 32 58 32"
check "T22.2 home stays full screen, its picture to the edges ($(front '.front.role // ""'), $(front_box))" \
  test "$(front '.front.role // ""') $(front_box)" = "home 0 0 1920 1080"

# The stand-in service page, served on the box itself. Again after the
# restart, which empties /tmp.
serve() {
  ssh_guest "mkdir -p /tmp/origaitv-fit && cat >/tmp/origaitv-fit/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/fit.html" || true
  ssh_guest "cd /tmp/origaitv-fit && (nohup python3 -m http.server 8768 --bind 127.0.0.1 >/dev/null 2>&1 &)" || true
}
serve

# open_page <x> <y>: the page in front, maximized inside a margin of x by y.
open_page() {
  local x=$1 y=$2 width=$(( 1920 - 2 * $1 )) height=$(( 1080 - 2 * $2 ))
  guest "origaitv screen open http://127.0.0.1:8768/" >>"$RUN_DIR/screen.log" 2>&1 || true
  wait_for 30 title_is "^fit $width $height " || true
  wait_for 10 front_is "$x $y $width $height" || true
}

open_page 58 32
guest_hyprctl "-j clients" >"$RUN_DIR/clients-page.json" 2>&1 || true
capture_console "success-T22.2-page"
check "T22.2 the service page is maximized, not full screen (fullscreen $(front_fullscreen))" test "$(front_fullscreen)" = "1"
check "T22.2 its corners sit 58 and 32 inside the screen's: at 58,32, 1804 by 1016 (it's $(front_box))" front_is "58 32 1804 1016"
check "T22.2 and the page itself is 1804 by 1016 (its title: $(front '.front.title // ""'))" title_is "^fit 1804 1016 "

# A player's full screen: the page asks, and stays inside the margin.
guest "origaitv input key f" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 3
printf 'after f: %s, window %s, fullscreen %s\n' "$(front '.front.title // ""')" "$(front_box)" "$(front_fullscreen)" | tee -a "$RUN_DIR/full.txt"
capture_console "success-T22.2-player"
check "T22.2 the page asking for full screen stays inside the margin (it's $(front_box))" front_is "58 32 1804 1016"

# A bigger margin, as Settings, Appearance's Fit to screen picks: 5, which is
# 96 by 54. The page moves in at once, at the same mode.
since=$(ssh_guest "date +%s" 2>/dev/null | tr -d '\r' || true)
answer=$(ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"margin\":5}' --max-time 10 http://127.0.0.1:3000/api/display" 2>/dev/null || true)
printf '%s\n' "$answer" >"$RUN_DIR/put-margin.json"
check "T22.2 a margin of 5 is set at once (answer: $(head -c 300 <<<"$answer"))" test "$(jq -r '"\(.applied) \(.inset | join(" "))"' <<<"$answer" 2>/dev/null)" = "true 96 54"
check "T22.2 the monitor keeps it ($(monitor '.reserved | join(" ")'))" wait_for 10 reserved_is "96 54 96 54"
check "T22.2 the page in front moves inside it: at 96,54, 1728 by 972 (it's $(front_box))" wait_for 10 front_is "96 54 1728 972"
guest "journalctl --user -u origaitv-screen --since @${since:-0} --no-pager" >"$RUN_DIR/origaitv-screen-margin.log" 2>&1 || true
check "T22.2 the screen daemon set the margin alone" grep -q "display: the margin on .* is 96 by 54" "$RUN_DIR/origaitv-screen-margin.log"
check "T22.2 without setting the TV's mode again" bash -c "! grep -Eq 'display: .* at [0-9]+x[0-9]+@' '$RUN_DIR/origaitv-screen-margin.log'"
kept=$(guest "cat \"\${XDG_STATE_HOME:-\$HOME/.local/state}/origaitv/display\"" 2>/dev/null | tr -d '\r' || true)
check "T22.2 the screen daemon keeps the margin for the next session (the line: $kept)" grep -Eq '^[A-Za-z0-9._-]+ [0-9]+x[0-9]+@[0-9.]+ [0-9.]+ 96 54$' <<<"$kept"

# A restart: the TV session starts with the margin, and the page is inside it.
boot=$(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
ssh_sudo "systemctl reboot" >/dev/null 2>&1 || true
started=$SECONDS
while (( SECONDS - started < 90 )); do
  [[ $(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null) != "$boot" ]] && break
  sleep 1
done
wait_for_ssh 300 failure-T22.2-reboot-ssh-timeout || { check "the box came back after the restart" false; stop_vm; finish; }
wait_home 240 >/dev/null || { capture_console "failure-T22.2-no-home"; check "home came back after the restart" false; stop_vm; finish; }
check "it came back as a new boot" test "$(ssh_guest "cat /proc/sys/kernel/random/boot_id" 2>/dev/null)" != "$boot"
guest_hyprctl "-j monitors" >"$RUN_DIR/monitors-after.json" 2>&1 || true
check "T22.2 after the restart, the monitor has the margin ($(monitor '.reserved | join(" ")'))" wait_for 15 reserved_is "96 54 96 54"
guest "journalctl --user -b -u origaitv-screen --no-pager" >"$RUN_DIR/origaitv-screen-after.log" 2>&1 || true
check "T22.2 the session started with it: the screen daemon had nothing to set" \
  bash -c "! grep -qE 'display: .* at [0-9]+x[0-9]+@|display: the margin on' '$RUN_DIR/origaitv-screen-after.log'"
serve
open_page 96 54
guest_hyprctl "-j clients" >"$RUN_DIR/clients-after.json" 2>&1 || true
capture_console "success-T22.2-after-restart"
check "T22.2 after the restart, the page's corners sit 96 and 54 inside the screen's (it's $(front_box))" front_is "96 54 1728 972"
check "T22.2 and the page itself is 1728 by 972 (its title: $(front '.front.title // ""'))" title_is "^fit 1728 972 "

guest "journalctl --user -b --no-pager -u origaitv-screen" >"$RUN_DIR/origaitv-screen.log" 2>&1 || true
ssh_sudo "journalctl -b --no-pager -u origaitv-daemon" >"$RUN_DIR/origaitv-daemon.log" 2>&1 || true
stop_vm
finish
