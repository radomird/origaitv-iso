#!/bin/bash
#
# T1.1: the USB stick boots to OrigaiTV's own first screen, step 1 of 12, which
# asks only which disk. One press of Enter installs on the disk it
# highlights, with no question of Omarchy's on the screen from the boot to
# the restart (OCR). The box restarts by itself and lands in TV setup's first
# screen. On it, the box is called origaitv, the account is origaitv, the disk
# isn't encrypted, and the box knows nobody knows the account's password.
#
# T30.1: the first start after the install goes straight to setup, even
# when the disk's old system had asked for the boot menu on its next start
# (Settings, Power, restart to the boot menu). That request lives in the
# firmware, and the stick's GRUB never reads it, so it's planted here from
# the live system, the way logind writes it, before Enter is pressed. And
# a key pressed as the new system first starts, in the boot loader's quiet
# second, doesn't stop it at the menu either: the install asks for that one
# start to have no countdown. Keys go in from the moment the firmware starts
# the new system's boot loader, as T2.1 presses them on a later start.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/first-screen.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

# The account the first screen makes. Its password is one nobody knows, so
# the harness logs in with its key, and the VM stops from QEMU.
# shellcheck disable=SC2034 # ssh_guest reads it
GUEST_USER=origaitv

log "Booting the USB stick onto a blank disk"
boot_stick t1.1
wait_for_live_root_ssh 300 || { stop_vm; finish; }

check "T1.1 the USB stick boots to OrigaiTV's first screen, step 1 of 12 (OCR)" wait_for_screen "of 12" 300
capture_console "success-T1.1-first-screen"

# first_screen_read: the first screen, read three ways. ocr_screen's black
# and white can lose the pink erase line, or mangle it ("on if iLL be
# erased"). The plain greys read it, as a block and as scattered text, but
# they can misread "origaitv" as "agenty", which ocr_screen reads right.
first_screen_read() {
  local shot="$RUN_DIR/.first-screen.ppm" grey="$RUN_DIR/.first-screen.png"

  ocr_screen
  echo
  rm -f "$shot"
  screendump "$shot"
  if [[ -s $shot ]] && magick "$shot" -colorspace gray -negate -resize 150% "$grey" 2>/dev/null; then
    tesseract "$grey" - --psm 6 2>/dev/null
    tesseract "$grey" - --psm 11 2>/dev/null
  fi
}

first_screen_read >"$RUN_DIR/first-screen.txt"
cat "$RUN_DIR/first-screen.txt"

# first_screen_says <pattern>: what OCR read finds it (grep -E, any case).
# The screen stays put, so OCR reads it again, up to three more times, and
# each reading goes in first-screen.txt, where the check below for
# Omarchy's questions reads them all too.
first_screen_says() {
  local tries=0
  until grep -qiE "$1" "$RUN_DIR/first-screen.txt"; do
    (( tries++ < 3 )) || return 1
    sleep 2
    { echo; first_screen_read; } >>"$RUN_DIR/first-screen.txt"
  done
}

check "it asks which disk to install on" first_screen_says "install origaitv on"
# OCR misreads this font next to the QR code beside these lines: "uill",
# "oun", "ouwn", "bhe erased", "evergthing", "ui w0 eraser", and the
# apostrophe as two ("omarchy’'s"). So each line is matched by the words it
# reads steadily, at the start of the line or close to its end, and read
# again if it misses.
check "and says everything on it will be erased" first_screen_says "ever.thing on it|on it .{0,12}eras"
check "and that Ctrl+C gives Omarchy's own installer" first_screen_says "ctrl.c omarchy.{1,6}s .*installer"
# shellcheck disable=SC2016 # the single quotes hold the inner bash's own
check "T1.1 no question of Omarchy's on it (OCR)" \
  bash -c '! grep -qiE "$1|password|language|email" "$2"' _ "$OMARCHY_QUESTIONS" "$RUN_DIR/first-screen.txt"

give_key
# logind's "0" for the boot loader's menu with no countdown: the variable's
# attributes (non-volatile, boot and runtime), then "0" in UTF-16 with its
# NUL. Limine shows its menu and waits for Enter when it finds this.
ONE_SHOT=/sys/firmware/efi/efivars/LoaderConfigTimeoutOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
ssh_live_root "printf '\\x07\\x00\\x00\\x00\\x30\\x00\\x00\\x00' >$ONE_SHOT" >"$RUN_DIR/one-shot.log" 2>&1 || true
check "the old system's request for the boot menu is in the firmware, as Settings leaves it" \
  ssh_live_root "test -f $ONE_SHOT"
log "Pressing Enter, once"
press ret
# The first start's boot loader: a key every tenth of a second for three
# seconds, from when the firmware starts it. The menu does nothing with x.
(
  until installed_system_started "$STICK_SERIAL"; do sleep 0.05; done
  for (( i = 0; i < 30; i++ )); do
    press x
    sleep 0.1
  done
  touch "$RUN_DIR/first-start-keys"
) &
keys=$!
installed=0
wait_for_box t1.1 && installed=1
kill "$keys" 2>/dev/null || true
check "T30.1 keys were pressed as the first start's boot loader began" test -e "$RUN_DIR/first-start-keys"
check "T1.1 one press of Enter installed it, and the box restarted by itself" test "$installed" = 1
check "T30.1 the first start after the install reached the TV by itself, past the old system's request for the boot menu and keys in the boot loader's second" \
  test "$installed" = 1
(( installed )) || { stop_vm; finish; }
check "T30.1 the install dropped that request, and the boot loader read and erased the one the install left" ssh_guest "test ! -e $ONE_SHOT"
if [[ -n $QUESTIONS_SEEN ]]; then
  printf '%s\n' "$QUESTIONS_SEEN" >"$RUN_DIR/questions.txt"
  cat "$RUN_DIR/questions.txt"
fi
check "T1.1 no question of Omarchy's on the screen while it installed (OCR every 10 s)" test -z "$QUESTIONS_SEEN"

check "the box is called origaitv" test "$(ssh_guest hostname 2>/dev/null)" = origaitv
check "its account is origaitv, with sudo" ssh_guest "id -nG | grep -qw wheel"
check "the disk isn't encrypted" ssh_guest "! lsblk -no TYPE | grep -qx crypt"
check "the box knows nobody knows the account's password" \
  ssh_guest "jq -e '.name == \"origaitv\" and .passwordKnown == false' /var/lib/origaitv/account.json"
check "T1.1 TV setup's first screen is on the TV (daemon /health)" tv_setup_on_screen
capture_console "success-T1.1-tv-setup"

stop_vm
finish
