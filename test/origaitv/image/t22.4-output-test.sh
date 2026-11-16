#!/bin/bash
#
# T22.4: the TV's output going away, and Hyprland crashing. On the NUC the TV
# went to standby, its output went with it, and input ended the ambient
# screen. The screen daemon moved the app back in front with no monitor
# there, which killed Hyprland 0.56, and start-hyprland brought it back in
# its safe mode, which only a mouse or a keyboard gets past. Here:
#   - the monitor goes, as Hyprland drops it when a TV unplugs: a rule
#     that disables it runs the same disconnect (CMonitor::onDisconnect),
#     and Hyprland has no monitor. virtio-gpu's connector forced off
#     through sysfs didn't take the monitor away: it was back in seconds;
#   - input ends the ambient screen and an app opens, and Hyprland lives;
#   - the monitor comes back with the rule the session runs at, and the app
#     is in front again, inside Fit to screen's margin, on the same Hyprland;
#   - Hyprland killed with SIGSEGV comes back as the TV, not in safe mode,
#     with home in front and the TV's units on the new Hyprland;
#   - and only after two more crashes, each within a minute of a start, does
#     it start in safe mode.
# About four minutes from the night's box.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-T22.4-ssh-timeout || exit 1
wait_tv 300 >/dev/null || { capture_console "failure-T22.4-no-tv"; check "the TV session came up" false; stop_vm; finish; }
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

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
hyprland_pid() {
  ssh_guest "pgrep -xo Hyprland" 2>/dev/null | tr -d '\r' || true
}
hyprland_args() {
  ssh_guest "tr '\\0' ' ' </proc/\$(pgrep -xn Hyprland)/cmdline" 2>/dev/null || true
}
monitors() {
  guest_hyprctl "-j monitors" 2>/dev/null | jq -r 'length' 2>/dev/null || true
}
no_monitor() {
  [[ $(monitors) == "0" ]]
}
a_monitor() {
  (( $(monitors || echo 0) > 0 ))
}
role_is() {
  [[ $(front '.front.role // ""') == "$1" ]]
}
# The app in front, maximized inside Fit to screen's margin and focused.
app_inside() {
  local address monitor client inset
  role_is web || return 1
  address=$(front '.front.address // ""')
  monitor=$(guest_hyprctl "-j monitors" 2>/dev/null | jq -c 'first(.[] | select(.disabled != true)) | [(.width / .scale | round), (.height / .scale | round)]' 2>/dev/null || true)
  client=$(guest_hyprctl "-j clients" 2>/dev/null | jq -c --arg a "$address" 'first(.[] | select(.address == $a)) | {at, size, workspace: .workspace.name, fullscreen}' 2>/dev/null || true)
  inset=$(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/display" 2>/dev/null | jq -c '.inset // [0, 0]' 2>/dev/null || echo "[0,0]")
  echo "monitor $monitor, margin $inset, window $client" >>"$RUN_DIR/geometry.log"
  [[ -n $client && -n $monitor ]] && jq -e --argjson monitor "$monitor" --argjson inset "$inset" \
    '.workspace == "1" and .fullscreen == 1 and .at == $inset and .size == [$monitor[0] - 2 * $inset[0], $monitor[1] - 2 * $inset[1]]' <<<"$client" >/dev/null
}
# A Hyprland other than <pid> that answers hyprctl: up, as start-hyprland
# counts it.
not_safe_mode() {
  [[ " $(hyprland_args) " != *" --safe-mode "* ]]
}
safe_mode() {
  [[ " $(hyprland_args) " == *" --safe-mode "* ]]
}
new_hyprland() {
  local pid
  pid=$(hyprland_pid)
  [[ -n $pid && $pid != "$1" ]] && guest_hyprctl "version" >/dev/null 2>&1
}
# Lua in the TV session's Hyprland, as the screen daemon runs it.
hypr_eval() {
  guest_hyprctl "eval $(printf %q "$1")"
}
screen_log() {
  guest "journalctl --user -b --no-pager -u origaitv-screen" 2>/dev/null || true
}

# A stand-in app in front, and the ambient screen over it, as on the NUC.
ssh_guest "mkdir -p /tmp/origaitv-fit && cat >/tmp/origaitv-fit/index.html" <"$(dirname -- "${BASH_SOURCE[0]}")/pages/fit.html" || true
ssh_guest "cd /tmp/origaitv-fit && (nohup python3 -m http.server 8768 --bind 127.0.0.1 >/dev/null 2>&1 &)" || true
guest "origaitv screen open http://127.0.0.1:8768/" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the stand-in app opens in front, inside the margin" wait_for 60 app_inside
guest "origaitv screen ambient" >>"$RUN_DIR/screen.log" 2>&1 || true
check "the ambient screen comes up over it" wait_for 15 role_is home
pid=$(hyprland_pid)
log "Hyprland is pid $pid"

# The TV's output goes, as when the TV goes to standby or to another input.
output=$(guest_hyprctl "-j monitors" 2>/dev/null | jq -r 'first(.[] | select(.disabled != true)) | .name' 2>/dev/null || true)
kept=$(guest "cat \"\${XDG_STATE_HOME:-\$HOME/.local/state}/origaitv/display\"" 2>/dev/null | tr -d '\r' || true)
log "The TV is $output, kept as: $kept"
check "the TV has a monitor to take away ($output)" test -n "$output"
since=$(ssh_guest "date +%s" 2>/dev/null | tr -d '\r' || true)
hypr_eval "hl.monitor({ output = \"$output\", disabled = true })" >>"$RUN_DIR/monitor.log" 2>&1 || true
check "T22.4 with the monitor gone, Hyprland has none" wait_for 15 no_monitor

# What killed Hyprland on the NUC: input on the seat, as the overlay says it,
# ending the ambient screen, which put the app back in front. And a second
# app opening.
guest "origaitv screen idle no" >>"$RUN_DIR/screen.log" 2>&1 || true
guest "origaitv screen open http://127.0.0.1:8768/?again" >>"$RUN_DIR/screen.log" 2>&1 || true
sleep 8
guest "journalctl --user -u origaitv-screen --since @${since:-0} --no-pager" >"$RUN_DIR/origaitv-screen-gone.log" 2>&1 || true
check "T22.4 Hyprland lives through it, the same one as before (pid $(hyprland_pid))" test "$(hyprland_pid)" = "$pid"
check "T22.4 the screen daemon knew the output was gone" grep -q "the TV's output is gone; windows stay where they are until it's back" "$RUN_DIR/origaitv-screen-gone.log"
check "T22.4 and kept the app to put in front once it's back" grep -q "goes in front once the TV's output is back" "$RUN_DIR/origaitv-screen-gone.log"
check "T22.4 focus on no window isn't given back" bash -c "! grep -q 'focus went to 0x;' '$RUN_DIR/origaitv-screen-gone.log'"

# The output comes back, at the mode, scale and margin the session runs at.
read -r kept_output kept_mode kept_scale kept_x kept_y <<<"$kept"
rule="hl.monitor({ output = \"$output\", mode = \"preferred\", position = \"auto\", scale = \"auto\" })"
if [[ $kept_output == "$output" && -n $kept_mode && -n $kept_scale ]]; then
  reserved=""
  if [[ -n $kept_x && -n $kept_y ]]; then
    reserved=", reserved = { top = $kept_y, right = $kept_x, bottom = $kept_y, left = $kept_x }"
  fi
  rule="hl.monitor({ output = \"$output\", mode = \"$kept_mode\", position = \"auto\", scale = $kept_scale$reserved })"
fi
log "Back with: $rule"
hypr_eval "$rule" >>"$RUN_DIR/monitor.log" 2>&1 || true
check "T22.4 with the monitor back, Hyprland has it again" wait_for 20 a_monitor
check "T22.4 the app is in front again, inside the margin" wait_for 20 app_inside
capture_console "success-T22.4-back"
guest "journalctl --user -u origaitv-screen --since @${since:-0} --no-pager" >"$RUN_DIR/origaitv-screen-back.log" 2>&1 || true
check "T22.4 the screen daemon put it there when the monitor came" grep -q "came after the TV's output was gone; web" "$RUN_DIR/origaitv-screen-back.log"
check "T22.4 on the same Hyprland, with no crash" test "$(hyprland_pid)" = "$pid"

# Hyprland crashes, after it's run a while: it starts again as the TV.
ssh_guest "kill -SEGV $pid" >/dev/null 2>&1 || true
check "T22.4 after a crash a new Hyprland starts" wait_for 60 new_hyprland "$pid"
first=$(hyprland_pid)
check "T22.4 and not in its safe mode ($(hyprland_args))" not_safe_mode
check "T22.4 home comes back in front" wait_home 120
check "T22.4 the TV's units run on the new Hyprland (the screen daemon answers)" test "$(front '.ok')" = "true"
check "T22.4 the overlay runs again" guest "systemctl --user is-active origaitv-toast.service"
capture_console "success-T22.4-after-crash"
ssh_guest "journalctl -b --no-pager -t origaitv-session" >"$RUN_DIR/origaitv-session.log" 2>&1 || true
check "T22.4 the journal names Hyprland's crash report" grep -q "Hyprland crashed; starting the TV session's Hyprland again. Its crash report: " "$RUN_DIR/origaitv-session.log"
check "T22.4 and the report stays" guest "ls ~/.cache/hyprland/hyprlandCrashReport*.txt"

# Two more crashes, each as soon as Hyprland is up: the first still starts it
# as the TV, the second in safe mode. A minute after the first restart, so
# the crash just after it counts as the first quick one.
up=$(ssh_guest "ps -o etimes= -p $first" 2>/dev/null | tr -d ' \r' || true)
(( ${up:-60} < 62 )) && sleep $(( 62 - ${up:-60} ))
ssh_guest "kill -SEGV $first" >/dev/null 2>&1 || true
wait_for 60 new_hyprland "$first" || true
second=$(hyprland_pid)
ssh_guest "kill -SEGV $second" >/dev/null 2>&1 || true
wait_for 60 new_hyprland "$second" || true
check "T22.4 a crash soon after a start still starts it as the TV ($(hyprland_args))" not_safe_mode
third=$(hyprland_pid)
ssh_guest "kill -SEGV $third" >/dev/null 2>&1 || true
check "a new Hyprland starts after the next crash too" wait_for 60 new_hyprland "$third"
check "T22.4 the second crash in a row soon after a start goes to safe mode ($(hyprland_args))" safe_mode
capture_console "success-T22.4-safe-mode"
ssh_guest "journalctl -b --no-pager -t origaitv-session" >"$RUN_DIR/origaitv-session.log" 2>&1 || true
check "T22.4 the journal says why" grep -q "times in a row; starting it in its safe mode" "$RUN_DIR/origaitv-session.log"

screen_log >"$RUN_DIR/origaitv-screen.log"
stop_vm
finish
