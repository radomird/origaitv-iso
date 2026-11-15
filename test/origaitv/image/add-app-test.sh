#!/bin/bash
#
# ADR-042: an official app added from Apps on the TV, after setup. Apps →
# add an app lists the official apps in the signed index that aren't on the
# box. Choosing one asks for the adult PIN, then root installs it through
# the same hand-over as setup's apps step, with the program a native app
# opens, from its own unit. A child's profile doesn't see it.
#
# The index here is a test one, signed with a key made for this run alone,
# and its one app is a stand-in game. Its program is a stand-in package in
# a local repository on this throwaway box, never Steam or anything of
# Valve's. The TV is driven with its keys, from origaitv screen apps.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

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
  [[ -z ${4:-} ]] || headers+=" -H 'X-origaiTV-Grant: $4'"
  [[ -z ${3:-} ]] || body="-d '$3'"
  ssh_guest "curl -sS --max-time 10 -X $1 $headers $body http://127.0.0.1:3000$2" 2>/dev/null
}

start_vm_from_base
wait_for_ssh 300 failure-add-app-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-add-app-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
wait_home 60 >/dev/null || true

# The test index, its one app and the key it's signed with, made here.
work="$RUN_DIR/add-app"
rm -rf "$work"
mkdir -p "$work/repo/apps/standin" "$work/index"
# gpg's agent listens on a socket in GNUPGHOME, whose path has a length
# limit the run's folder is past, so the key is made in a short one.
GNUPGHOME=$(mktemp -d /tmp/origaitv-gpg.XXXXXX)
export GNUPGHOME
gpg --batch --quiet --passphrase '' --quick-gen-key "origaiTV image check <check@origaitv.invalid>" ed25519 sign never
gpg --batch --armor --export >"$work/keyring.asc"
cat >"$work/repo/apps/standin/manifest.json" <<'MANIFEST'
{
  "schemaVersion": 1,
  "id": "origaitv.standin",
  "name": "Stand-in game",
  "version": "1.0.0",
  "author": "origaitv",
  "license": "MIT",
  "description": "A stand-in game for origaiTV's image check",
  "kinds": ["tv-app"],
  "entryPoints": { "tvApp": "app.ts" },
  "tv": {
    "contract": 1,
    "category": "games",
    "runtime": "native",
    "package": { "pacman": "origaitv-stand-in-game" },
    "exec": ["origaitv-stand-in-game"],
    "capabilities": ["launch"],
    "childSafe": false
  }
}
MANIFEST
cat >"$work/repo/apps/standin/app.ts" <<'APP'
// A stand-in game for origaiTV's image check: the box opens its program.
export default { id: "origaitv.standin", async launch() {} };
APP

# The stand-in game's package, built on the box, in a repository of its own
# that pacman uses from now on, as it would any other.
cat >"$work/package.sh" <<'PACKAGE'
set -euo pipefail
pkg=/var/lib/origaitv-check/pkg
rm -rf "$pkg"
install -d "$pkg/root/usr/bin"
printf '#!/bin/bash\necho "a stand-in game for origaiTV'"'"'s image check"\n' >"$pkg/root/usr/bin/origaitv-stand-in-game"
chmod 755 "$pkg/root/usr/bin/origaitv-stand-in-game"
cat >"$pkg/root/.PKGINFO" <<'INFO'
pkgname = origaitv-stand-in-game
pkgbase = origaitv-stand-in-game
pkgver = 1.0-1
pkgdesc = A stand-in program for origaiTV's image check
url = https://example.invalid/origaitv-stand-in-game
builddate = 1700000000
packager = origaiTV image check
size = 64
arch = any
license = MIT
INFO
(cd "$pkg/root" && bsdtar --zstd -cf ../origaitv-stand-in-game-1.0-1-any.pkg.tar.zst .PKGINFO usr)
(cd "$pkg" && repo-add -q origaitv-check.db.tar.gz origaitv-stand-in-game-1.0-1-any.pkg.tar.zst)
grep -q '^\[origaitv-check\]' /etc/pacman.conf || printf '\n[origaitv-check]\nSigLevel = Optional TrustAll\nServer = file:///var/lib/origaitv-check/pkg\n' >>/etc/pacman.conf
install -m 644 "$pkg/origaitv-check.db.tar.gz" /var/lib/pacman/sync/origaitv-check.db
# A box that's been updated has every repository's package list, and one
# straight from the ISO has none. So this one fetches them, as its first
# update would. An empty list in a real one's place isn't enough: origaiTV's
# repository takes a list only with its signature, and nothing here can
# sign one. An empty one still stands in for a repository that didn't
# answer and takes an unsigned list.
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

# The app's repo is made on the box, which has git as any box does for
# its installs, and the index pins the commit it made, signed here.
ssh_sudo "git -C $CHECK/repo init -q && git -C $CHECK/repo add -A && git -C $CHECK/repo -c user.name='origaiTV image check' -c user.email=check@origaitv.invalid commit -qm 'A stand-in game'" >>"$RUN_DIR/check-setup.log" 2>&1 || true
commit=$(ssh_sudo "git -C $CHECK/repo rev-parse HEAD" 2>/dev/null | tr -d '\r' | tail -n 1)
check "the stand-in game's repo is on the box, at a commit ($commit)" test "${#commit}" = 40
jq -n --arg commit "$commit" --arg repo "file://$CHECK/repo" \
  '{schema: 1, apps: [{id: "origaitv.standin", tier: "official", name: "Stand-in game", version: "1.0.0", description: "A stand-in game for origaiTV'"'"'s image check", repo: $repo, commit: $commit, path: "apps/standin"}]}' >"$work/index/index.json"
gpg --batch --quiet --detach-sign --output "$work/index/index.json.sig" "$work/index/index.json"
# The key's done its job: nothing of it is kept.
gpgconf --kill gpg-agent 2>/dev/null || true
rm -rf -- "${GNUPGHOME:?}"
tar -C "$work" -czf "$work/index.tgz" index
ssh_guest "cat >/tmp/origaitv-check-index.tgz" <"$work/index.tgz"
ssh_sudo "tar -xzf /tmp/origaitv-check-index.tgz -C $CHECK && chown -R root:root $CHECK/index && chmod -R a+rX $CHECK/index" >>"$RUN_DIR/check-setup.log" 2>&1 || true
check "the stand-in game's package is in a repository pacman uses, and not installed" \
  ssh_guest "pacman -Si origaitv-stand-in-game >/dev/null && ! pacman -Q origaitv-stand-in-game >/dev/null 2>&1"

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
check "ADR-042 add an app lists the official app that isn't on the box, from the signed index" \
  until_json /api/apps/add '[.apps[].id] == ["origaitv.standin"] and .error == null' 60

# On the TV, with its keys: Apps, then add an app, then the stand-in game.
guest "origaitv screen apps" >>"$RUN_DIR/screen.log" 2>&1 || true
check "ADR-042 Apps has add an app for an adult (OCR)" ocr_finds success-add-app-apps "add an" 30
capture_console "success-add-app-apps"
guest "origaitv screen apps add" >>"$RUN_DIR/screen.log" 2>&1 || true
check "ADR-042 add an app shows the stand-in game, with its line (OCR)" ocr_finds success-add-app-list "stand-in game" 30
capture_console "success-add-app-list"
guest "origaitv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true
check "ADR-042 choosing it asks for the adult PIN (OCR)" ocr_finds success-add-app-pin "adult pin|adding an app" 20
capture_console "success-add-app-pin"
check "and nothing is handed over before the PIN" \
  test -z "$(ssh_guest "jq -r '.apps[\"origaitv.standin\"] // empty' /run/origaitv-setup-apps/state.json 2>/dev/null")"
guest "origaitv input text $PIN" >>"$RUN_DIR/input.log" 2>&1 || true

log "Waiting for the stand-in game and its program to install"
until_file '.apps["origaitv.standin"].state == "installed" or .apps["origaitv.standin"].state == "failed"' /run/origaitv-setup-apps/state.json 600 || true
ssh_guest "cat /run/origaitv-setup-apps/state.json" >"$RUN_DIR/setup-apps-state.json" 2>&1 || true
ssh_guest "journalctl -u origaitv-setup-apps.service -u 'origaitv-app-package@*' --no-pager" >"$RUN_DIR/hand-over.log" 2>&1 || true
check "ADR-042 after the PIN, root installed it from the test index ($(jq -r '.apps["origaitv.standin"] | "\(.state) \(.error // "")"' "$RUN_DIR/setup-apps-state.json" 2>/dev/null))" \
  jq -e '.apps["origaitv.standin"].state == "installed"' "$RUN_DIR/setup-apps-state.json"
check "ADR-042 its program came with it, through the hand-over" ssh_guest "pacman -Q origaitv-stand-in-game >/dev/null && test -x /usr/bin/origaitv-stand-in-game"
check "from origaitv-app-package@origaitv.standin.service" grep -q "installed origaitv-stand-in-game for origaitv.standin" "$RUN_DIR/hand-over.log"
grep -E "origaitv-setup-apps|origaitv-app-package" "$RUN_DIR/hand-over.log" | tail -n 20 || true
check "home has it" until_json /api/home '[.apps[].id] | index("origaitv.standin") != null' 30
check "ADR-042 its tile says it's installed (OCR)" ocr_finds success-add-app-installed "installed" 30
capture_console "success-add-app-installed"

# A child's profile: no add an app, on the TV or from the daemon.
grant=$(api POST /api/pin/check "{\"pin\":\"$PIN\"}" | jq -r '.grant // empty')
child=$(api POST /api/viewers '{"name":"mia","role":"child"}' "$grant" | jq -r '.profile.id // empty')
api POST /api/viewer "{\"id\":\"$child\"}" "$grant" >/dev/null || true
check "a child's profile is watching" until_json /api/home '.viewer.role == "child"' 20
check "ADR-042 the daemon doesn't list apps to add for a child's profile" \
  test "$(ssh_guest "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/apps/add")" = 403
guest "origaitv screen apps" >>"$RUN_DIR/screen.log" 2>&1 || true
sleep 3
ocr_finds success-add-app-child-apps "apps" 15 || true
capture_console "success-add-app-child-apps"
check "ADR-042 a child's profile has no add an app on Apps (OCR)" bash -c "! grep -Eqi 'add an' '$RUN_DIR/success-add-app-child-apps.txt'"
guest "origaitv screen apps add" >>"$RUN_DIR/screen.log" 2>&1 || true
sleep 3
ocr_finds success-add-app-child-add "." 5 || true
check "and asking for it goes home instead (OCR)" bash -c "! grep -Eqi 'add an app|stand-in game' '$RUN_DIR/success-add-app-child-add.txt'"

pin_off "$PIN"
stop_vm
finish
