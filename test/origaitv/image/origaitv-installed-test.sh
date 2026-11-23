#!/bin/bash
#
# OrigaiTV's packages are on the installed box (ADR-025): the ISO's build put
# origaitv and origaitv-keyring in the root image beside Omarchy's own package,
# pacman trusts OrigaiTV's key, and origaitv runs. Boots the base image that
# upstream's test/integration left behind, like its own scenarios do.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ssh.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

fingerprint=$(tr -d '[:space:]' <"$ROOT/configs/airootfs/usr/share/origaitv-iso/key-fingerprint")

log "Booting the installed system"
start_vm_from_base
wait_for_ssh 300 failure-origaitv-ssh-timeout || exit 1

check "Omarchy's own package is installed" ssh_guest "pacman -Q omarchy"
check "origaitv and origaitv-keyring are installed" ssh_guest "pacman -Q origaitv origaitv-keyring"
# Right after boot, root's pacman (the update check's) can have the keyring
# open, as a root gpg-agent did in one image run, and a read as the box's
# own account fails while it does. So it's tried for up to 30 s.
has_key() {
  local started=$SECONDS
  until ssh_guest "pacman-key --list-keys $fingerprint" >/dev/null 2>&1; do
    (( SECONDS - started < 30 )) || return 1
    sleep 2
  done
}
check "pacman has OrigaiTV's key" has_key
# Trusted, not only there: the installer fills the box's keyring itself,
# from a list that has to name OrigaiTV's keyring (customize.sh), and a key
# that isn't signed by the box's own master key fails every update.
ssh_sudo "gpg --homedir /etc/pacman.d/gnupg --with-colons --list-keys $fingerprint" >"$RUN_DIR/origaitv-key.txt" 2>&1 || true
check "pacman trusts OrigaiTV's key fully" \
  test "$(awk -F: '$1 == "pub" { print $2; exit }' "$RUN_DIR/origaitv-key.txt")" = f -o "$(awk -F: '$1 == "pub" { print $2; exit }' "$RUN_DIR/origaitv-key.txt")" = u
# OrigaiTV's keyring names OrigaiTV's key and no other. A pull request's run is
# the one exception: its packages are signed with a throwaway key made for
# the run (origaitv-os's image.yml), and its own origaitv-keyring names that one
# too. A box installed from a channel must never have a second key.
expected=$fingerprint
if [[ -n ${ORIGAITV_TEST_PACKAGE_KEY:-} ]]; then
  expected+=" $(gpg --batch --with-colons --show-keys "$ORIGAITV_TEST_PACKAGE_KEY" | awk -F: '$1 == "fpr" { print $10; exit }')"
fi
trusted=$(ssh_guest "cut -d: -f1 /usr/share/pacman/keyrings/origaitv-trusted | paste -sd' '" 2>/dev/null || true)
check "OrigaiTV's keyring trusts the keys it should, and no other (it has: ${trusted:-none})" test "$trusted" = "$expected"
check "origaitv runs" ssh_guest "origaitv version"
# The box has the origaitv package the ISO was built with, and says so. A
# release's ISO is named after its version (origaitv-1.0.0-x86_64.iso), so
# what "origaitv version" prints on a box installed from it has to be that
# package's version. Checked wherever the packages the build read are still
# beside this check: always in this repo's own ISO run, which is the one a
# release tag starts. A job that was only handed the installed box doesn't
# have them, and says it skipped this.
carried=("$ROOT"/configs/airootfs/usr/share/origaitv-iso/packages/origaitv-[0-9]*-any.pkg.tar.zst)
if [[ ${#carried[@]} == 1 && -f ${carried[0]} ]]; then
  package=${carried[0]##*/origaitv-}
  package=${package%-any.pkg.tar.zst}
  installed=$(ssh_guest "pacman -Q origaitv" | cut -d' ' -f2)
  check "the box has the origaitv the ISO was built with ($package, and it has ${installed:-none})" test "$installed" = "$package"
  said=$(ssh_guest "origaitv version" | head -n 1 | cut -d' ' -f2)
  check "and origaitv version says so (${package%-*}, and it says ${said:-nothing})" test "$said" = "${package%-*}"
else
  log "The packages the ISO was built with aren't here, so the box's origaitv isn't compared with them"
fi
# A release tag's ISO says which release it is, and the box it installs
# keeps that, for Settings, System (T30.3): the ISO workflow writes the
# file before the build. Any other ISO writes none, and the box has none.
release_file=$ROOT/configs/airootfs/usr/share/origaitv-iso/release
if [[ -s $release_file ]]; then
  release=$(sed -n '1{s/[[:space:]]//g;p;}' "$release_file")
  kept=$(ssh_guest "cat /etc/origaitv/release" 2>/dev/null || true)
  check "T30.3 the box keeps the release it was installed from ($release, and it has ${kept:-none})" test "$kept" = "$release"
  check "T30.3 origaitv version names it" ssh_guest "origaitv version | grep -qx 'Installed from OrigaiTV $release'"
  # And the TV's state says it, which Settings, System shows: the release,
  # or on stable the package's own when it's newer.
  said=""
  for _ in $(seq 1 24); do
    said=$(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/health" 2>/dev/null | jq -r '.release // empty' 2>/dev/null || true)
    [[ -z $said ]] || break
    sleep 5
  done
  # shellcheck disable=SC2016 # the single quotes hold the inner bash's own
  check "T30.3 the TV says it runs a release (${said:-none}), $release on an edge package" \
    bash -c '[[ -n $1 && ( $1 == "$2" || $3 == stable ) ]]' - "$said" "$release" "$(ssh_guest "origaitv version" | head -n 1 | sed -n 's/.*(\(.*\))$/\1/p')"
else
  check "an ISO with no release puts none on the box" ssh_guest "test ! -e /etc/origaitv/release"
fi
# OrigaiTV's repository takes its package list only with the signature. A box
# straight from the ISO has no list yet, and one that has refreshed has both.
# A list alone would make pacman refuse every install that doesn't refresh.
check "OrigaiTV's package list is never on the box without its signature" \
  ssh_guest "[[ ! -e /var/lib/pacman/sync/origaitv.db || -s /var/lib/pacman/sync/origaitv.db.sig ]]"
check "pacman reads its package lists without an error about OrigaiTV's" \
  ssh_guest "! pacman -Si origaitv 2>&1 | grep -qi 'signature\|not valid'"
check "nothing of OrigaiTV's is in Omarchy's folder" \
  ssh_guest "! pacman -Ql origaitv | grep -q ' /usr/share/omarchy/'"

ssh_guest "origaitv version; pacman -Q omarchy origaitv origaitv-keyring" >"$RUN_DIR/versions.txt" 2>&1 || true
capture_console "success-origaitv-installed"

stop_vm
finish
