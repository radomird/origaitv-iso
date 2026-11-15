#!/bin/bash
#
# For the nightly run (ADR-026): writes every package and version on the
# freshly installed box to $ORIGAITV_TEST_TESTED_OUT, which the run turns into
# the signed tested.json once every check has passed. Skips otherwise.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ssh.sh"

if [[ -z ${ORIGAITV_TEST_TESTED_OUT:-} ]]; then
  log "Not a nightly run; skipping"
  exit 0
fi
base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-tested-ssh-timeout || exit 1

ssh_guest "pacman -Q" >"$ORIGAITV_TEST_TESTED_OUT"
check "the box lists its packages" test -s "$ORIGAITV_TEST_TESTED_OUT"
check "the list has Omarchy's and OrigaiTV's packages" grep -qE '^(omarchy|origaitv) ' "$ORIGAITV_TEST_TESTED_OUT"

stop_vm
finish
