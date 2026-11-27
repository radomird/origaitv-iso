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
  # sed reads every line. head stops at the first, and on a box with a
  # release the next line is on its way by then, so the command died of a
  # closed pipe and took this whole check with it, saying nothing.
  said=$(ssh_guest "origaitv version" | sed -n '1p' | cut -d' ' -f2)
  check "and origaitv version says so (${package%-*}, and it says ${said:-nothing})" test "$said" = "${package%-*}"
else
  log "The packages the ISO was built with aren't here, so the box's origaitv isn't compared with them"
fi
# A release tag's ISO says which release it is, and the box it installs
# keeps that, with the build of OrigaiTV it installed on the line under it,
# for Settings, System (T30.3): the ISO workflow writes the release before
# the build. A pull request's ISO says it's a stand-in release, so this side
# is checked before a tag is. Any other ISO writes none, and the box has
# none.
release_file=$ROOT/configs/airootfs/usr/share/origaitv-iso/release
if [[ -s $release_file ]]; then
  release=$(sed -n '1{s/[[:space:]]//g;p;}' "$release_file")
  build=$(ssh_guest ". /usr/share/origaitv/settings && echo \$ORIGAITV_VERSION" 2>/dev/null || true)
  channel=$(ssh_guest ". /usr/share/origaitv/settings && echo \$ORIGAITV_CHANNEL" 2>/dev/null || true)
  kept=$(ssh_guest "cat /etc/origaitv/release" 2>/dev/null || true)
  check "T30.3 the box keeps the release it was installed from and the build it has ($release and $build, and it has $(paste -sd' ' <<<"${kept:-none}"))" \
    test "$kept" = "$release"$'\n'"$build"
  # What the TV's state says, which Settings, System shows: the release it
  # runs, and the one it was installed from.
  state() {
    local said=""
    for _ in $(seq 1 24); do
      said=$(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/health" 2>/dev/null | jq -r '"\(.release) \(.installedFrom)"' 2>/dev/null || true)
      [[ -z $said ]] || break
      sleep 5
    done
    echo "$said"
  }
  if [[ $channel == "stable" ]]; then
    # A release's ISO carries the release's own package, so that's what runs.
    said=$(state)
    check "T30.3 a stable box runs its package's release ($build, and it says ${said:-nothing})" test "$said" = "$build $release"
    check "T30.3 and origaitv version adds nothing" ssh_guest "[[ \$(origaitv version | grep -c -e '^Release ' -e '^Edge channel') == 0 ]]"
  else
    # A candidate's ISO carries edge's package: still that build, it runs
    # the candidate.
    said=$(state)
    check "T30.3 still on the ISO's build, the TV runs $release (it says ${said:-nothing})" test "$said" = "$release $release"
    check "T30.3 and origaitv version says Release $release" ssh_guest "origaitv version | grep -qx 'Release $release'"
    # An update on edge moves it past that build. The file says another
    # build for a moment, as if the package were newer, and back after.
    ssh_sudo "cp /etc/origaitv/release /etc/origaitv/release.kept && printf '%s\\n%s\\n' '$release' '0.0.0.r1.g0000000' >/etc/origaitv/release" >/dev/null 2>&1 || true
    said=$(state)
    check "T30.3 updated past it, the TV runs edge, installed from $release (it says ${said:-nothing})" test "$said" = "null $release"
    check "T30.3 and origaitv version says Edge channel, installed from $release" ssh_guest "origaitv version | grep -qx 'Edge channel, installed from $release'"
    ssh_sudo "mv /etc/origaitv/release.kept /etc/origaitv/release" >/dev/null 2>&1 || true
    check "the box's release file is as the install left it" ssh_guest "[[ \$(cat /etc/origaitv/release) == '$release'$'\\n''$build' ]]"
  fi
else
  check "an ISO with no release puts none on the box" ssh_guest "test ! -e /etc/origaitv/release"
fi
# Edge counts from the last release or candidate, and a box only ever takes
# a newer package. So the box's own pacman is asked about every pair of the
# versions edge moves through (edge-order.txt): each has to be older than
# all that come after it. The pairs are counted on the box, in one go.
mapfile -t ordered < <(grep -v -e '^#' -e '^[[:space:]]*$' "$ROOT/test/origaitv/edge-order.txt")
wrong=$(ssh_guest "bash -s -- ${ordered[*]}" <<'ORDER' 2>/dev/null || echo "couldn't ask"
versions=("$@")
for (( i = 0; i < ${#versions[@]}; i++ )); do
  for (( j = i + 1; j < ${#versions[@]}; j++ )); do
    [[ $(vercmp "${versions[i]}" "${versions[j]}") == -1 && $(vercmp "${versions[j]}" "${versions[i]}") == 1 ]] ||
      echo "${versions[i]} isn't older than ${versions[j]}"
  done
done
ORDER
)
wrong=${wrong//$'\n'/; }
check "the box's pacman puts edge's versions in order, all ${#ordered[@]} of them (${wrong:-every pair is right})" \
  test "${#ordered[@]}" -ge 9 -a -z "$wrong"
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
