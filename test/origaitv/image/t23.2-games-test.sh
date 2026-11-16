#!/bin/bash
#
# T23.2: two game platforms added from Settings, under Home and apps, Games,
# on an installed box (ADR-103). RetroArch and Xbox Cloud Gaming are added
# one after the other, the second while the first installs, past the adult
# PIN. Root installs both through the same hand-over as setup's apps step,
# in turn, and runs RetroArch's own first steps as the person: its settings
# and ~/Games, in their home and owned by them. Both land in home's Games
# row. Each opens, RetroArch natively in its gamescope and Xbox Cloud Gaming
# in the services' Chromium, and each keeps a short press of the guide
# button as its own and goes home on a hold, still running behind it.
#
# The index is a test one, signed with a key made for this run alone.
# RetroArch's program is a stand-in package in a local repository on this
# throwaway box, which shows a full-screen window, and gamescope and the
# gamepad are the stand-ins of t16-guide-home-test.sh: there's no GPU here.
# Xbox Cloud Gaming is the real app's manifest, which opens Xbox's own site.
# What a real RetroArch and a real Xbox account do is the NUC's to see.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

PIN=2468
# The PIN comes off again however the check ends.
trap 'pin_off_then_cleanup "$PIN"' EXIT
CHECK=/var/lib/origaitv-check

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

# api <method> <path> [json] [grant]: the daemon's answer, as the TV asks.
api() {
  local headers="-H 'Content-Type: application/json'" body=""
  [[ -z ${4:-} ]] || headers+=" -H 'X-OrigaiTV-Grant: $4'"
  [[ -z ${3:-} ]] || body="-d '$3'"
  ssh_guest "curl -sS --max-time 10 -X $1 $headers $body http://127.0.0.1:3000$2" 2>/dev/null
}

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

start_vm_from_base
wait_for_ssh 300 failure-t23.2-games-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-t23.2-games-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
wait_home 60 >/dev/null || true
owner=$(ssh_guest "id -un" 2>/dev/null | tr -d '\r' | tail -n 1)

# --- The test index, RetroArch's stand-in program, and gamescope's ---------------

work="$RUN_DIR/t23.2"
rm -rf "$work"
mkdir -p "$work/repo/apps/retroarch" "$work/repo/apps/xboxcloud" "$work/index"
GNUPGHOME=$(mktemp -d /tmp/origaitv-gpg.XXXXXX)
export GNUPGHOME
gpg --batch --quiet --passphrase '' --quick-gen-key "OrigaiTV image check <check@origaitv.invalid>" ed25519 sign never
gpg --batch --armor --export >"$work/keyring.asc"

# RetroArch's app, by its own id, so its first steps are RetroArch's, with
# a stand-in for its program.
cat >"$work/repo/apps/retroarch/manifest.json" <<'MANIFEST'
{
  "schemaVersion": 1,
  "id": "origaitv.retroarch",
  "name": "RetroArch",
  "version": "1.0.0",
  "author": "origaitv",
  "license": "MIT",
  "description": "Classic consoles, from your own games",
  "kinds": ["tv-app"],
  "entryPoints": { "tvApp": "app.ts" },
  "tv": {
    "contract": 1,
    "category": "games",
    "runtime": "native",
    "package": { "pacman": "origaitv-stand-in-retro" },
    "exec": ["origaitv-stand-in-retro"],
    "capabilities": ["launch"],
    "childSafe": false
  }
}
MANIFEST
cat >"$work/repo/apps/retroarch/app.ts" <<'APP'
// RetroArch's stand-in for OrigaiTV's image check: the box opens its program.
export default { id: "origaitv.retroarch", async launch() {} };
APP
# Xbox Cloud Gaming, as the real app is.
cat >"$work/repo/apps/xboxcloud/manifest.json" <<'MANIFEST'
{
  "schemaVersion": 1,
  "id": "origaitv.xboxcloud",
  "name": "Xbox Cloud Gaming",
  "version": "1.0.0",
  "author": "origaitv",
  "license": "MIT",
  "description": "Xbox games streamed from the cloud",
  "kinds": ["tv-app"],
  "entryPoints": { "tvApp": "app.ts" },
  "tv": {
    "contract": 1,
    "category": "games",
    "runtime": "web",
    "homeUrl": "https://www.xbox.com/play",
    "capabilities": ["launch"],
    "origins": ["https://www.xbox.com"],
    "childSafe": false
  }
}
MANIFEST
cat >"$work/repo/apps/xboxcloud/app.ts" <<'APP'
// Xbox Cloud Gaming for OrigaiTV's image check: the box opens its site.
export default { id: "origaitv.xboxcloud", async launch() {} };
APP

# The stand-in program, built on the box into a repository pacman uses: a
# full-screen window, drawn without a GPU, until /tmp/origaitv-retro-quit.
cat >"$work/package.sh" <<'PACKAGE'
set -euo pipefail
pkg=/var/lib/origaitv-check/pkg
rm -rf "$pkg"
install -d "$pkg/root/usr/bin"
cat >"$pkg/root/usr/bin/origaitv-stand-in-retro" <<'PROGRAM'
#!/bin/bash
rm -f /tmp/origaitv-retro-quit
mpv --vo=wlshm --idle=yes --force-window=yes --fs --no-audio --no-terminal --title=retro-stand-in &
window=$!
sleep 3
if ! kill -0 "$window" 2>/dev/null; then
  chromium --ozone-platform=wayland --user-data-dir=/tmp/origaitv-retro-stand-in --no-first-run --kiosk \
    "data:text/html,<title>retro-stand-in</title><body style='background:%23123'>" &
  window=$!
fi
while [[ ! -e /tmp/origaitv-retro-quit ]] && kill -0 "$window" 2>/dev/null; do sleep 0.2; done
kill "$window" 2>/dev/null
wait "$window" 2>/dev/null
exit 0
PROGRAM
chmod 755 "$pkg/root/usr/bin/origaitv-stand-in-retro"
cat >"$pkg/root/.PKGINFO" <<'INFO'
pkgname = origaitv-stand-in-retro
pkgbase = origaitv-stand-in-retro
pkgver = 1.0-1
pkgdesc = A stand-in program for OrigaiTV's image check
url = https://example.invalid/origaitv-stand-in-retro
builddate = 1700000000
packager = OrigaiTV image check
size = 64
arch = any
license = MIT
INFO
(cd "$pkg/root" && bsdtar --zstd -cf ../origaitv-stand-in-retro-1.0-1-any.pkg.tar.zst .PKGINFO usr)
(cd "$pkg" && repo-add -q origaitv-check.db.tar.gz origaitv-stand-in-retro-1.0-1-any.pkg.tar.zst)
grep -q '^\[origaitv-check\]' /etc/pacman.conf || printf '\n[origaitv-check]\nSigLevel = Optional TrustAll\nServer = file:///var/lib/origaitv-check/pkg\n' >>/etc/pacman.conf
install -m 644 "$pkg/origaitv-check.db.tar.gz" /var/lib/pacman/sync/origaitv-check.db
# Every repository's package list, as a box that's been updated has them
# (add-app-test.sh says why).
missing=0
for repo in $(pacman-conf --repo-list); do
  [[ -f /var/lib/pacman/sync/$repo.db ]] || missing=1
done
if (( missing )); then
  pacman -Sy || true
fi
for repo in $(pacman-conf --repo-list); do
  [[ -f /var/lib/pacman/sync/$repo.db ]] || bsdtar -czf "/var/lib/pacman/sync/$repo.db" -T /dev/null
done
PACKAGE

tar -C "$work" -czf "$work/check.tgz" repo keyring.asc package.sh
ssh_guest "cat >/tmp/origaitv-check.tgz" <"$work/check.tgz"
ssh_sudo "install -d -m 755 $CHECK && tar -xzf /tmp/origaitv-check.tgz -C $CHECK && chown -R root:root $CHECK && chmod -R a+rX $CHECK && bash $CHECK/package.sh" >"$RUN_DIR/check-setup.log" 2>&1 || true
ssh_sudo "git -C $CHECK/repo init -q && git -C $CHECK/repo add -A && git -C $CHECK/repo -c user.name='OrigaiTV image check' -c user.email=check@origaitv.invalid commit -qm 'Two game platforms'" >>"$RUN_DIR/check-setup.log" 2>&1 || true
commit=$(ssh_sudo "git -C $CHECK/repo rev-parse HEAD" 2>/dev/null | tr -d '\r' | tail -n 1)
check "the test apps' repo is on the box, at a commit ($commit)" test "${#commit}" = 40
jq -n --arg commit "$commit" --arg repo "file://$CHECK/repo" '{schema: 1, apps: [
  {id: "origaitv.retroarch", tier: "official", name: "RetroArch", version: "1.0.0", description: "Classic consoles, from your own games", category: "games", repo: $repo, commit: $commit, path: "apps/retroarch"},
  {id: "origaitv.xboxcloud", tier: "official", name: "Xbox Cloud Gaming", version: "1.0.0", description: "Xbox games streamed from the cloud", category: "games", repo: $repo, commit: $commit, path: "apps/xboxcloud"}
]}' >"$work/index/index.json"
gpg --batch --quiet --detach-sign --output "$work/index/index.json.sig" "$work/index/index.json"
gpgconf --kill gpg-agent 2>/dev/null || true
rm -rf -- "${GNUPGHOME:?}"
tar -C "$work" -czf "$work/index.tgz" index
ssh_guest "cat >/tmp/origaitv-check-index.tgz" <"$work/index.tgz"
ssh_sudo "tar -xzf /tmp/origaitv-check-index.tgz -C $CHECK && chown -R root:root $CHECK/index && chmod -R a+rX $CHECK/index" >>"$RUN_DIR/check-setup.log" 2>&1 || true
check "RetroArch's stand-in program is in a repository pacman uses, and not installed" \
  ssh_guest "pacman -Si origaitv-stand-in-retro >/dev/null && ! pacman -Q origaitv-stand-in-retro >/dev/null 2>&1"

# gamescope's stand-in, where its package puts it (t16-guide-home-test.sh).
ssh_guest "cat >/tmp/gamescope" <<'GAMESCOPE'
#!/bin/bash
# A stand-in for gamescope in OrigaiTV's image checks, which have no GPU: it
# notes how it was started and runs what comes after --, and it ends when
# that does, as gamescope does.
printf '%s\n' "$*" >>/tmp/origaitv-gamescope-args
while (( $# > 0 )) && [[ $1 != "--" ]]; do shift; done
shift
"$@"
GAMESCOPE
ssh_sudo "install -m 755 /tmp/gamescope /usr/bin/gamescope"

# The daemon and root's hand-over read the test index, with its key.
for unit in origaitv-daemon origaitv-setup-apps; do
  ssh_sudo "install -d /etc/systemd/system/$unit.service.d && printf '[Service]\nEnvironment=ORIGAITV_INDEX_URL=$CHECK/index\nEnvironment=ORIGAITV_KEYRING=$CHECK/keyring.asc\n' >/etc/systemd/system/$unit.service.d/origaitv-check.conf"
done
ssh_sudo "systemctl daemon-reload && systemctl restart origaitv-daemon"
up() {
  local started=$SECONDS
  while (( SECONDS - started < 60 )); do
    [[ -n $(health) ]] && return 0
    sleep 1
  done
  return 1
}
check "the daemon is back with the test index" up
api PUT /api/pin "{\"pin\":\"$PIN\"}" >"$RUN_DIR/pin.json" || true
check "the adult PIN is set" jq -e '.ok' "$RUN_DIR/pin.json"
check "T23.2 Settings' Games page lists both, neither on the TV" \
  until_json /api/games '[.apps[] | "\(.id) \(.installed)"] == ["origaitv.retroarch false", "origaitv.xboxcloud false"]' 60

# --- Adding both from Settings, with the TV's keys ---------------------------------

guest "origaitv screen settings games" >>"$RUN_DIR/screen.log" 2>&1 || true
check "T23.2 Settings opens on Games, with RetroArch and Xbox Cloud Gaming (OCR)" ocr_finds success-t23.2-games "retroarch" 30
capture_console "success-t23.2-games"
# Into the page: RetroArch is its first row. OK asks for the PIN.
guest "origaitv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 1
guest "origaitv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "T23.2 adding RetroArch asks for the adult PIN (OCR)" ocr_finds success-t23.2-pin "adult pin|settings" 20
capture_console "success-t23.2-pin"
guest "origaitv input text $PIN" >>"$RUN_DIR/input.log" 2>&1 || true
check "RetroArch is handed to root" until_file '.apps["origaitv.retroarch"].state != null' /run/origaitv-setup-apps/state.json 60
# The next row, while RetroArch installs: it waits its turn.
guest "origaitv input key down" >>"$RUN_DIR/input.log" 2>&1 || true
sleep 1
guest "origaitv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "T23.2 Xbox Cloud Gaming, added while RetroArch installs, isn't refused" until_json /api/games '[.apps[] | select(.id == "origaitv.xboxcloud") | .state != null or .installed] == [true]' 30
capture_console "success-t23.2-queued"

log "Waiting for both to install"
until_file '([.apps["origaitv.retroarch"].state, .apps["origaitv.xboxcloud"].state] | all(. == "installed" or . == "failed"))' /run/origaitv-setup-apps/state.json 600 || true
ssh_guest "cat /run/origaitv-setup-apps/state.json" >"$RUN_DIR/setup-apps-state.json" 2>&1 || true
ssh_guest "journalctl -u origaitv-setup-apps.service -u 'origaitv-app-package@*' --no-pager" >"$RUN_DIR/hand-over.log" 2>&1 || true
check "T23.2 RetroArch installed ($(jq -r '.apps["origaitv.retroarch"] | "\(.state) \(.error // "")"' "$RUN_DIR/setup-apps-state.json" 2>/dev/null))" \
  jq -e '.apps["origaitv.retroarch"].state == "installed"' "$RUN_DIR/setup-apps-state.json"
check "T23.2 Xbox Cloud Gaming installed after it ($(jq -r '.apps["origaitv.xboxcloud"] | "\(.state) \(.error // "")"' "$RUN_DIR/setup-apps-state.json" 2>/dev/null))" \
  jq -e '.apps["origaitv.xboxcloud"].state == "installed"' "$RUN_DIR/setup-apps-state.json"
check "RetroArch's program came with it, through the hand-over" ssh_guest "pacman -Q origaitv-stand-in-retro >/dev/null && test -x /usr/bin/origaitv-stand-in-retro"
# Its first steps, as the person, in their own home.
ssh_guest "cat ~/.config/retroarch/retroarch.cfg" >"$RUN_DIR/retroarch.cfg" 2>&1 || true
check "T23.2 RetroArch's settings are in the person's home, as Omarchy's installer makes them" \
  grep -qx "rgui_browser_directory = \"/home/$owner/Games/roms\"" "$RUN_DIR/retroarch.cfg"
check "and owned by them, with ~/Games for BIOS files and games" \
  ssh_guest "test \"\$(stat -c %U ~/.config/retroarch/retroarch.cfg ~/Games/roms ~/Games/bios | sort -u)\" = \"$owner\""
check "and no file manager was opened for it, as Omarchy's installer does at the end" ssh_guest "! pgrep -x nautilus >/dev/null"
check "T23.2 home has both, in its Games row" \
  until_json /api/home '[.apps[] | select(.category == "games") | .id] | (index("origaitv.retroarch") != null and index("origaitv.xboxcloud") != null)' 30
check "T23.2 Settings says each can be removed now (OCR)" ocr_finds success-t23.2-installed "remove" 30
capture_console "success-t23.2-installed"

# --- Each opens, and the guide button's hold goes home --------------------------------

# The stand-in gamepad, made by the person logged in on the screen.
ssh_guest "cat >/tmp/origaitv-gamepad.py" <"$DIR/gamepad.py"
ssh_guest "rm -f /tmp/origaitv-gamepad; (nohup python3 -I /tmp/origaitv-gamepad.py /tmp/origaitv-gamepad >/tmp/origaitv-gamepad.log 2>&1 &)"
pad() {
  ssh_guest "echo '$1 $2' >/tmp/origaitv-gamepad"
}
pad_device() {
  # shellcheck disable=SC2016 # expanded on the box
  ssh_guest 'for node in /sys/class/input/event*; do
    [[ $(cat "$node/device/name" 2>/dev/null) == "OrigaiTV test gamepad" ]] || continue
    grep -qx "E:ID_INPUT_JOYSTICK=1" "/run/udev/data/c$(cat "$node/dev")" 2>/dev/null && echo "/dev/input/${node##*/}"
  done' 2>/dev/null | head -n 1 || true
}
device=""
started=$SECONDS
while (( SECONDS - started < 20 )) && [[ -z $device ]]; do
  device=$(pad_device)
  [[ -n $device ]] || sleep 1
done
check "a stand-in gamepad is on the box ($device)" test -n "$device"
# The input helper looks for new gamepads every 3 s.
sleep 5

# RetroArch, natively, in its gamescope.
guest "origaitv screen app origaitv.retroarch" >>"$RUN_DIR/screen.log" 2>&1 || true
up=no
wait_front game 90 && up=yes
check "T23.2 RetroArch opens in front, in its gamescope" test "$up" = yes
check "as RetroArch's window" test "$(front '.front.app // ""')" = "origaitv.retroarch"
started_with=$(ssh_guest "tail -n 1 /tmp/origaitv-gamescope-args" 2>/dev/null || true)
log "gamescope was started with: $started_with"
check "T23.2 gamescope runs RetroArch's own command, full screen, without Steam's integration" \
  bash -c "[[ ' $started_with ' == *' -f '* && ' $started_with ' != *' -e '* && '$started_with' == *'-- origaitv-stand-in-retro' ]]"
sleep 3
capture_console "success-t23.2-retroarch"
pad guide 0.15
check "T23.2 a short press of the guide button is RetroArch's own" stays_front game 4
pad guide 3
check "T23.2 holding the guide button goes home from RetroArch" wait_front home 5
check "and RetroArch keeps running behind home" ssh_guest "pgrep -f 'retro-stand-i[n]' >/dev/null"
check "home lists it as a game that's open" \
  test "$(jq -c '[.open[] | select(.id == "origaitv.retroarch") | [.role, .game]]' <<<"$(screen_status)" 2>/dev/null)" = '[["game",true]]'
sleep 4

# Xbox Cloud Gaming, in the services' Chromium, is a game too.
guest "origaitv screen app origaitv.xboxcloud" >>"$RUN_DIR/screen.log" 2>&1 || true
up=no
wait_front web 60 && up=yes
check "T23.2 Xbox Cloud Gaming opens in front, in the services' Chromium" test "$up" = yes
check "as a game" test "$(jq -c '[.open[] | select(.id == "origaitv.xboxcloud") | .game]' <<<"$(screen_status)" 2>/dev/null)" = '[true]'
sleep 3
capture_console "success-t23.2-xboxcloud"
pad guide 0.15
check "T23.2 a short press of the guide button is Xbox Cloud Gaming's own" stays_front web 4
pad guide 3
check "T23.2 holding the guide button goes home from Xbox Cloud Gaming" wait_front home 5
check "and it stays open behind home, with RetroArch" \
  test "$(jq -c '[.open[] | select(.game == true) | .id] | sort' <<<"$(screen_status)" 2>/dev/null)" = '["origaitv.retroarch","origaitv.xboxcloud"]'
capture_console "success-t23.2-home"

ssh_guest "cat /tmp/origaitv-gamepad.log" >"$RUN_DIR/gamepad.log" 2>&1 || true
guest "journalctl --user -b --no-pager -u origaitv-screen -u origaitv-input" >"$RUN_DIR/games.log" 2>&1 || true
ssh_guest "touch /tmp/origaitv-retro-quit" || true

pin_off "$PIN"
stop_vm
finish
