#!/bin/bash

# Makes the live ISO's installer OrigaiTV's without editing a file of
# omarchy-iso's (ADR-025, ADR-029): OrigaiTV's logo, tagline and words, no
# encryption by default, and OrigaiTV's key trusted on the installed box. Runs
# once, in the live system's chroot, from a line bin/origaitv-iso-brand puts
# in omarchy-iso's /root/customize_airootfs.sh for the build. Each change
# stops the build if upstream has moved the line it changes.
#
# OrigaiTV's packages aren't added here. The installer installs a root image
# that omarchy-iso's build makes before this runs, from a mirror whose
# checksums it has recorded by then, so bin/origaitv-iso-depends puts them in
# that mirror and image before the build starts.

set -euo pipefail

here=/usr/share/origaitv-iso

# The installer's logo (ADR-021): the greeter, the configurator and the
# install dashboard read /usr/share/omarchy/logo.txt. This changes the live
# ISO only; on the installed box Omarchy's own package owns that file.
# logo.txt comes from origaitv-os's branding/build.py and keeps its 81 columns,
# which the dashboard takes its width from.
install -D -m 644 "$here/logo.txt" /usr/share/omarchy/logo.txt

# The greeter's tagline (ADR-027). Under OrigaiTV's logo, Omarchy's own line,
# "Beautiful, Fun & Agentic Linux by DHH", would read as if DHH made OrigaiTV.
# It becomes OrigaiTV's public tagline; the logo still says powered by omarchy.
# Stop if upstream has moved the line, rather than ship it.
export ORIGAITV_TAGLINE="The world's first open-source agentic TV OS"
if ! grep -q '^  tagline="Beautiful, Fun & Agentic Linux by DHH"$' /root/configurator; then
  echo "origaitv-iso: the greeter's tagline in /root/configurator has moved upstream" >&2
  exit 1
fi
perl -pi -e 's/^  tagline="Beautiful, Fun & Agentic Linux by DHH"$/  tagline="$ENV{ORIGAITV_TAGLINE}"/' /root/configurator

# The logo in OrigaiTV's colours (ADR-028). The greeter, every step's header
# and the install dashboard's finish screen draw logo.txt all in Omarchy's
# green; they draw it with origaitv-logo instead. The greeter's green colour
# shift animation goes, and the finish screen's laser etch settles on OrigaiTV's
# blue before the two-colour logo is drawn over it. Each change stops the
# build if upstream has moved the line it replaces.
install -D -m 644 "$here/logo.ansi" /usr/local/share/origaitv/logo.ansi
install -D -m 755 "$here/origaitv-logo" /usr/local/bin/origaitv-logo

# patch <file> <description> <perl substitution, -0 so it can span lines>
patch() {
  local file="$1" what="$2" expression="$3" before
  before=$(mktemp)
  cp "$file" "$before"
  perl -0pi -e "$expression" "$file"
  if cmp -s "$before" "$file"; then
    rm -f "$before"
    echo "origaitv-iso: $what in $file has moved upstream" >&2
    exit 1
  fi
  rm -f "$before"
}

configurator=/root/configurator
dashboard=/usr/local/bin/omarchy-install-dashboard

# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the step header's logo" \
  's/^  gum style --foreground 2 --padding "1 0 0 \$PADDING_LEFT" "\$\(<"\$LOGO_PATH"\)"$/  origaitv-logo --top 1 --pad "\$PADDING_LEFT"/m'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the greeter's logo" \
  's/^  gum style --foreground 2 --padding "0 0 0 \$PADDING_LEFT" "\$\(<"\$LOGO_PATH"\)"$/  origaitv-logo --pad "\$PADDING_LEFT"/m'
# The greeter waits for Return and then stops $anim, so something has to run.
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the greeter's animation" \
  's/^  ttfx -i "\$LOGO_PATH" \\\n.*?^    <\/dev\/null >\/dev\/tty 2>\/dev\/null &$/  sleep infinity <\/dev\/null >\/dev\/null 2>&1 &/ms'
# No disk encryption by default (ADR-007): a TV box boots straight to the TV,
# and the PIN locks the TV, not the disk. Both disk confirms start out
# unencrypted, and Ctrl+C still gives an encrypted install, said on screen
# the way Omarchy says the opposite.
patch "$configurator" "the free-space install's encryption default" \
  's/^  local mode="encrypted" affirmative confirm_status$/  local mode="unencrypted" affirmative confirm_status/m'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the full-disk install's encryption default" \
  's/^(confirm_disk_overwrite\(\) \{\n)  local mode="encrypted"$/$1  local mode="unencrypted"/m'
# Each confirm says how to get the other kind: upstream's encrypted default
# says Ctrl+C gives an unencrypted install, so OrigaiTV's unencrypted one says
# Ctrl+C gives an encrypted install, in the catalog's words (below).
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the free-space confirm's Ctrl+C line" \
  's/^(        )(affirmative="\$\(t install\.yesUnencrypted\)")$/$1say --foreground 8 "\$(t encryption.hintEncrypted)"\n$1$2/m'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$configurator" "the full-disk confirm's Ctrl+C line" \
  's/^(      )(affirmative="\$\(t install\.yesUnencrypted\)")$/$1say --foreground 8 "\$(t encryption.hintEncrypted)"\n$1$2/m'
if (( $(grep -c '^  local mode="unencrypted"' "$configurator") != 2 )) || grep -q '^  local mode="encrypted"' "$configurator"; then
  echo "origaitv-iso: the installer doesn't default to no encryption in both disk confirms" >&2
  exit 1
fi

# The installer is OrigaiTV's (ADR-029): where it names what it installs, it
# says OrigaiTV, the box is called origaitv unless the owner names it, and the
# tips while it installs are OrigaiTV's.
form=/usr/share/omarchy-iso/setup-form.sh
patch "$form" "the hostname's default" \
  "s/^OMARCHY_HOSTNAME_DEFAULT='omarchy'\$/OMARCHY_HOSTNAME_DEFAULT='origaitv'/m"
patch "$configurator" "a deferred install's hostname" \
  's/^  hostname="omarchy"$/  hostname="origaitv"/m'

# From Omarchy 4.5 on, the words are in catalogs: the installer's own
# (/usr/share/omarchy-iso/i18n/<language>.json) and, for the setup form's
# questions, Omarchy's (/usr/share/omarchy/default/i18n/<language>/cli.json).
# A language that lacks a key falls back to English.
#
# catalog <file> <description> <jq filter>: fails when it changes nothing.
catalog() {
  local file="$1" what="$2" filter="$3" changed
  changed=$(mktemp)
  jq --indent 2 "$filter" "$file" >"$changed"
  if cmp -s <(jq -S . "$file") <(jq -S . "$changed"); then
    rm -f "$changed"
    echo "origaitv-iso: $what in $file has moved upstream" >&2
    exit 1
  fi
  cat "$changed" >"$file"
  rm -f "$changed"
}

iso_i18n=/usr/share/omarchy-iso/i18n
dashboard_tips=$(sed -n '/^tips=($/,/^)$/p' "$dashboard" | sed '1d;$d' | tr -d ' ')

# The hostname question's placeholder, in every language: "or return for
# 'omarchy'" says what an empty answer gives, which is origaitv now.
for cli in /usr/share/omarchy/default/i18n/*/cli.json; do
  if jq -e '."setupForm.hostnamePlaceholder" // "" | contains("'"'"'omarchy'"'"'")' "$cli" >/dev/null; then
    catalog "$cli" "the hostname prompt" '."setupForm.hostnamePlaceholder" |= gsub("'"'"'omarchy'"'"'"; "'"'"'origaitv'"'"'")'
  fi
done
if ! jq -e '."setupForm.hostnamePlaceholder" | contains("'"'"'origaitv'"'"'")' /usr/share/omarchy/default/i18n/en/cli.json >/dev/null; then
  echo "origaitv-iso: the hostname prompt doesn't say origaitv" >&2
  exit 1
fi

# OrigaiTV's own lines, in English: the unencrypted confirm's Ctrl+C line, and
# the tips while it installs, in place of Omarchy's.
catalog "$iso_i18n/en.json" "OrigaiTV's own lines" '. + {
  "encryption.hintEncrypted": "Press Ctrl+C for encrypted install.",
  "origaitv.tip.tv": "OrigaiTV starts straight on home. No password to type.",
  "origaitv.tip.phone": "Next, setup from your phone",
  "origaitv.tip.agent": "Missing an app? Ask, and your TV makes it",
  "origaitv.tip.local": "Apps you build stay on this TV",
  "origaitv.tip.update": "Every update saves a backup first",
  "origaitv.tip.back": "A bad update? Go back from Settings",
  "origaitv.tip.selftest": "Something off? Run origaitv selftest",
  "origaitv.tip.omarchy": "Omarchy is underneath: Super + Return still opens a terminal"
}'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$dashboard" "the tips while it installs" \
  's/^tips=\(\n.*?^\)$/tips=(
  origaitv.tip.tv
  origaitv.tip.phone
  origaitv.tip.agent
  origaitv.tip.local
  origaitv.tip.update
  origaitv.tip.back
  origaitv.tip.selftest
  origaitv.tip.omarchy
)/ms'

# The disk screens, the stopped install's headline and the finish screen
# name what they install: OrigaiTV, in every language that names it. Omarchy's
# own tips go unused, so they're left as they are, and so are OrigaiTV's.
mapfile -t named < <(jq -r 'to_entries[] | select((.key | startswith("origaitv.") | not) and (.value | type) == "string" and (.value | test("\\bOmarchy\\b"))) | .key' "$iso_i18n/en.json" |
  grep -Fxv -f <(printf '%s\n' "$dashboard_tips"))
(( ${#named[@]} > 0 )) || { echo "origaitv-iso: no installer line names Omarchy any more; has upstream moved them?" >&2; exit 1; }
named_json=$(printf '%s\n' "${named[@]}" | jq -R . | jq -s .)
for language in "$iso_i18n"/*.json; do
  jq --indent 2 --argjson keys "$named_json" \
    'with_entries(if (.key as $k | $keys | index($k)) and (.value | type) == "string" then .value |= gsub("\\bOmarchy\\b"; "OrigaiTV") else . end)' \
    "$language" >"$language.new"
  mv "$language.new" "$language"
done
for key in disk.intro mode.intro freeSpace.title failure.title finish.title finish.titleWithTime; do
  if ! jq -e --arg key "$key" '.[$key] | test("\\bOrigaiTV\\b")' "$iso_i18n/en.json" >/dev/null; then
    echo "origaitv-iso: the installer's $key doesn't say OrigaiTV; has upstream moved it?" >&2
    exit 1
  fi
done

# Upstream's English has em dashes, which OrigaiTV's copy never has.
catalog "$iso_i18n/en.json" "the lines with a dash" '
  ."bitlocker.suspend" |= sub(" \u2014 the drive"; ": the drive")
  | ."esp.found" |= sub(" \u2014 leaving it"; ". Leaving it")
  | ."tool.warning" |= sub(" \u2014 leave the"; ". Leave the")'
if grep -q $'\xe2\x80\x94' "$iso_i18n/en.json"; then
  echo "origaitv-iso: the installer's English still has an em dash:" >&2
  grep $'\xe2\x80\x94' "$iso_i18n/en.json" >&2
  exit 1
fi

# The dashboard's logo, in OrigaiTV's colours, wherever it draws it.
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$dashboard" "the dashboard's logo" \
  's/^    while IFS= read -r line; do\n      printf .\\r%s%s%b%s%b\\n. "\$CLEAR_LINE" "\$pad" "\$GREEN" "\$line" "\$RESET"\n    done <"\$LOGO_PATH"$/    origaitv-logo --prefix "\\r\$CLEAR_LINE\$pad"/m'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$dashboard" "the finish screen's effect" \
  's/^      --final-gradient-stops 2 \\\n      >"\$TTY_PATH" 2>\/dev\/null \|\| \{\n        dashboard_log "logo effect skipped \(ttfx exited \$\?\)"$/      --final-gradient-stops 4 \\\n      >"\$TTY_PATH" 2>\/dev\/null || true; {\n        dashboard_log "OrigaiTV redraws its logo in its own colours"/m'

# The installed box trusts OrigaiTV's key, as it trusts Omarchy's. The image
# comes with no pacman keyring, and the installer makes one on the box and
# fills it from a list of keyrings that names Archlinux's and Omarchy's
# (phases_impl._target_keyrings). origaitv-keyring's own scriptlet ran in the
# image, with no keyring to fill, so without OrigaiTV's name on that list the
# box's first update would stop on a package signed by a key it doesn't know.
patch /usr/share/omarchy-iso/orchestrator/phases_impl.py "the installed box's keyrings" \
  's/^    keyrings = \["archlinux", "omarchy"\]$/    keyrings = ["archlinux", "omarchy", "origaitv"]/m'

# OrigaiTV's first screen: step 1 of setup's 12. It asks only which disk, and
# Enter installs. It writes the answers Omarchy's configurator would, so the
# install that follows is Omarchy's own, with no prompts, and restarts by
# itself. Ctrl+C on it gives Omarchy's configurator, every question included.
# An autoinstall drive still comes first, and skips both.
install -D -m 755 "$here/first-screen/origaitv-first-screen" /usr/local/bin/origaitv-first-screen
# The phone's way: the live system's own Wi-Fi network and the page on it,
# and the QR code the TV shows for it.
for file in origaitv_phone.py origaitv_qr.py phone.html; do
  install -D -m 644 "$here/first-screen/$file" "/usr/local/lib/origaitv-first-screen/$file"
done

# The live system's Wi-Fi network needs its radio's firmware. omarchy-iso's
# own build step removes every radio's firmware from the live system right
# after this one, since its installer never goes online. The kernel looks in
# firmware/updates first, and that removal leaves it alone, so the Wi-Fi
# cards' firmware goes there: Intel's, Atheros', MediaTek's and Realtek's.
# The installed box gets its firmware from the root image either way.
fw=/usr/lib/firmware
wifi_firmware=(intel/iwlwifi iwlwifi-* ath9k_htc ath10k ath11k ath12k mediatek/WIFI_* mediatek/mt79* rtw88 rtw89 rtlwifi)
(
  cd "$fw"
  shopt -s nullglob
  found=()
  # shellcheck disable=SC2068 # the globs are meant to expand here
  for path in ${wifi_firmware[@]}; do
    [[ -e $path || -L $path ]] && found+=("$path")
  done
  if ! compgen -G "iwlwifi-*" >/dev/null && [[ ! -d intel/iwlwifi ]]; then
    echo "origaitv-iso: no Intel Wi-Fi firmware in $fw; has linux-firmware moved it?" >&2
    exit 1
  fi
  mkdir -p updates
  cp -a --parents "${found[@]}" updates/
  # A link that leads outside what was copied would lead nowhere once the
  # originals are gone, so it gets what it points at.
  updates=$(realpath updates)
  while IFS= read -r link; do
    target=$(realpath -m "$link")
    if [[ $target != "$updates"/* ]]; then
      rm -f "$link"
      cp -rL "$target" "$link"
    fi
  done < <(find updates -type l)
  echo "origaitv-iso: kept $(du -sm updates | cut -f1) MB of Wi-Fi firmware for the live system's hotspot"
)

automated=/root/.automated_script.sh
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$automated" "where the configurator starts" \
  's/^else\n  \.\/configurator\nfi$/elif \/usr\/local\/bin\/origaitv-first-screen; then
  # OrigaiTV'"'"'s first screen wrote the answers, so nobody is asked anything
  # more (origaitv-iso'"'"'s customize.sh).
  echo "OrigaiTV'"'"'s first screen wrote the answers; installing without questions."
  export OMARCHY_UI_INTERACTIVE=no ORIGAITV_STEP="2 of 12 · install"
else
  .\/configurator
fi/m'
if (( $(grep -c '^elif /usr/local/bin/origaitv-first-screen; then$' "$automated") != 1 )); then
  echo "origaitv-iso: OrigaiTV's first screen isn't in $automated exactly once" >&2
  exit 1
fi

# What the first screen hands the installed box (the account's marker) goes
# on it in a phase of its own, right after SSH access.
orchestrator=/usr/share/omarchy-iso/orchestrator
install -D -m 644 "$here/first-screen/origaitv_handover.py" "$orchestrator/origaitv_handover.py"
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$orchestrator/main.py" "the install's phases" \
  's/^(    return \[\n        \("Preparing live environment", prepare_live\),\n)/    from .origaitv_handover import origaitv_handover\n\n$1/m'
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$orchestrator/main.py" "the SSH access phase" \
  's/^(        \("Configuring SSH access", +configure_ssh_access\),\n)/$1        ("Handing over to OrigaiTV",     origaitv_handover),\n/m'

# An ISO built from a release tag says which release it is, and the install
# writes that onto the box (origaitv_handover.py). This folder is gone from
# the live system as soon as this script ends (bin/origaitv-iso-brand removes
# it), so the release moves to where the installer reads it.
if [[ -s $here/release ]]; then
  install -D -m 644 "$here/release" /usr/local/share/origaitv/release
  echo "origaitv-iso: this ISO is OrigaiTV $(head -n 1 "$here/release"), and tells the box it installs"
fi

# While it installs, the dashboard says which step of setup it is, under the
# percentage, where the medium's check shows while that runs.
# shellcheck disable=SC2016 # the single quotes hold perl
patch "$dashboard" "the line under the percentage" \
  's/^(    center "\$\{DIM\}verifying the install medium: \$\{VERIFY_PCT\}%\$\{RESET\}" "\$PROGRESS_TEXT_WIDTH"\n)(  else\n    blank_line\n  fi)$/$1  elif [[ -n \$\{ORIGAITV_STEP:-\} ]]; then\n    center "\$\{DIM\}\$\{ORIGAITV_STEP\}\$\{RESET\}" "\$PROGRESS_TEXT_WIDTH"\n$2/m'

echo "origaitv-iso: OrigaiTV's logo, tagline and words in the installer, no encryption by default, and OrigaiTV's key on the box"
echo "origaitv-iso: OrigaiTV's first screen asks only which disk, and Ctrl+C on it gives Omarchy's installer"
