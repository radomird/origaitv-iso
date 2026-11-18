#!/bin/bash
#
# The TV found and woken (T25.1), under a name of its own (T28.6), on an
# installed box.
#
# With the announce switch off, as a box has it, the TV says nothing about
# itself: Avahi has no file of OrigaiTV's, a browse finds nothing, no box id
# has been made, and a paired phone's answers are as they were.
#
# Turned on the way an edge box turns it on, Avahi publishes _origaitv._tcp on
# the phones' port, with the TV's name, the installed version and the box
# id, and nothing else. The name is OrigaiTV until somebody names the TV. It
# isn't the machine's name, which stays what it was. A browse on the box finds it. So does a phone on the
# home network: a network namespace on the box stands in for one, through a
# veth pair, as the servers' check does. It asks everyone, the way a browse
# does, and then the box alone, straight to its address. Both go through the
# box's own firewall, and both get the record.
#
# The id is the same after the daemon restarts. A paired phone learns it,
# and gets the wired port's hardware address and its network's broadcast
# address, which are the ones the box itself has. A request with no pairing
# is refused, with nothing of either in the answer.
#
# Named from the TV's own pages, the TV is found under that name and no
# longer as OrigaiTV, by the browse and by the phone, and a paired phone
# reads the name in its state. Named again from a paired phone, with every
# character root has to escape and one Avahi would fill in if it were asked
# to, it's found under exactly what was typed. The name is the same after a
# restart. Turned off again, the record is gone for the browse and for the
# phone alike.

# shellcheck disable=SC2016 # the $names in jq's and awk's programs are their own

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

FILE=/etc/avahi/services/origaitv.service
TYPE=_origaitv._tcp
TV=http://127.0.0.1:3000

start_vm_from_base
wait_for_ssh 300 failure-T25.1-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-T25.1-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo
guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 3

daemon_get() {
  ssh_guest "curl -fsS --max-time 10 $TV$1" 2>/dev/null
}
until_json() {
  local started=$SECONDS
  while (( SECONDS - started < $3 )); do
    [[ $(daemon_get "$1" | jq -r "$2" 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 1
}
# eventually <seconds> <command>...: until the command works.
eventually() {
  local started=$SECONDS seconds=$1
  shift
  while (( SECONDS - started < seconds )); do
    "$@" && return 0
    sleep 1
  done
  return 1
}
published() { ssh_guest "test -s $FILE" 2>/dev/null; }
unpublished() { ssh_guest "! test -e $FILE" 2>/dev/null; }

# browse <name>: what Avahi on the box finds of the type, resolved, kept as
# <name>.txt. A resolved line is "=;<device>;<IPv4 or IPv6>;<name>;<type>;
# local;<host>;<address>;<port>;<txt>".
browse() {
  ssh_guest "avahi-browse --parsable --resolve --terminate --no-db-lookup $TYPE" >"$RUN_DIR/$1.txt" 2>"$RUN_DIR/$1.err" || true
}
found() {
  browse "$1"
  grep -q '^=;' "$RUN_DIR/$1.txt"
}
# plain <name>: a name as it was announced, from how avahi-browse prints it.
# It writes a byte it won't print as a backslash and three digits, and a dot
# or a backslash after a backslash.
plain() {
  python3 -I -c '
import re, sys
escaped = sys.argv[1].encode()
sys.stdout.buffer.write(re.sub(rb"\\(\d{3}|.)", lambda m: bytes([int(m.group(1))]) if len(m.group(1)) == 3 else m.group(1), escaped))
' "$1"
}
# found_as <name> <file's name>: the browse finds the TV, and every line of
# it has this name and no other.
found_as() {
  local line count=0
  browse "$2"
  while IFS= read -r line; do
    [[ $(plain "$(cut -d ';' -f 4 <<<"$line")") == "$1" ]] || return 1
    count=$(( count + 1 ))
  done < <(grep "^[+=];.*;$TYPE;" "$RUN_DIR/$2.txt")
  (( count >= 2 )) && grep -q '^=;' "$RUN_DIR/$2.txt"
}
nothing_found() {
  browse "$1"
  ! grep -q "$TYPE" "$RUN_DIR/$1.txt"
}

# The phone on the home network: 192.168.77.10, behind lan0, where the box
# is 192.168.77.1. It has no Avahi of its own, only mdns.py.
ssh_guest "mkdir -p /tmp/origaitv-announce && cat >/tmp/origaitv-announce/mdns.py" <"$DIR/mdns.py"
ssh_sudo "
  set -e
  ip netns add origaitv-lan
  ip link add lan0 type veth peer name eth0 netns origaitv-lan
  ip addr add 192.168.77.1/24 dev lan0
  ip link set lan0 up
  ip -n origaitv-lan addr add 192.168.77.10/24 dev eth0
  ip -n origaitv-lan link set lo up
  ip -n origaitv-lan link set eth0 up
" >"$RUN_DIR/lan.log" 2>&1
check "the home network's stand-in is up" ssh_sudo "ip netns exec origaitv-lan ping -c 1 -W 2 192.168.77.1"
# phone browse|ask <name>: what the phone hears, kept as <name>.json.
phone() {
  local how=$1 name=$2 box=""
  [[ $how == "ask" ]] && box=192.168.77.1
  ssh_sudo "ip netns exec origaitv-lan python3 -I /tmp/origaitv-announce/mdns.py $how 192.168.77.10 $TYPE $box" >"$RUN_DIR/$name.json" 2>"$RUN_DIR/$name.err" || true
}
phone_hears() {
  phone "$1" "$2"
  jq -e 'length >= 1' "$RUN_DIR/$2.json" >/dev/null 2>&1
}
phone_hears_nothing() {
  phone "$1" "$2"
  jq -e '. == []' "$RUN_DIR/$2.json" >/dev/null 2>&1
}

# --- Off, as a box has it ---------------------------------------------------

check "the announce switch is off, as every box has it" until_json /api/features '.announce == false' 20
check "the hand-over waits for the daemon's drop" ssh_guest "systemctl is-active origaitv-announce.path"
check "T25.1 off: Avahi has no file of OrigaiTV's" unpublished
check "T25.1 off: a browse on the box finds nothing" nothing_found off-browse
check "T25.1 off: a phone that asks everyone hears nothing" phone_hears_nothing browse off-phone-browse
check "T25.1 off: and nothing when it asks the box alone" phone_hears_nothing ask off-phone-ask
check "off: no box id has been made" ssh_sudo "! test -e /var/lib/origaitv/daemon/box-id"
check "off: and the daemon handed nothing over" ssh_sudo "! test -e /var/lib/origaitv/daemon/announce-drop"

# The firewall's line is there from first boot, or from the migration on a
# box that was updated: mDNS from the home network's ranges, and no others.
ssh_sudo "ufw status verbose" >"$RUN_DIR/ufw.txt" 2>&1 || true
grep 5353 "$RUN_DIR/ufw.txt" || true
mdns_rules() {
  local got want
  got=$(awk '$1 == "5353/udp" { for (i = 2; i <= NF; i++) if ($i == "IN") { print $(i + 1); break } }' "$RUN_DIR/ufw.txt" | sort | paste -sd ' ')
  want=$(printf '%s\n' 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 | sort | paste -sd ' ')
  echo "$got" >"$RUN_DIR/ufw-5353.txt"
  [[ $got == "$want" ]]
}
check "the firewall takes mDNS from the home network's ranges, and from nowhere else" mdns_rules

key=$(pair_phone "announce check" || true)
check "a phone pairs" test -n "$key"
call() {
  ssh_guest "origaitv-phone-call $key GET $1" 2>/dev/null
}
call /api/phone/box >"$RUN_DIR/off-box.json" || true
call /api/phone/state >"$RUN_DIR/off-state.json" || true
check "T25.1 off: a paired phone's box answer is as it was" jq -e 'keys_unsorted == ["ok", "line", "box"]' "$RUN_DIR/off-box.json"
check "T25.1 off: and its state has no box id" jq -e '.ok == true and (has("boxId") | not)' "$RUN_DIR/off-state.json"

# --- On, the way an edge box turns a switch on ------------------------------

ssh_sudo "echo edge >/etc/origaitv/channel" >"$RUN_DIR/switch.log" 2>&1 || true
guest "origaitv feature on announce" >>"$RUN_DIR/switch.log" 2>&1 || true
check "the announce switch is on" until_json /api/features '.announce == true' 10
check "root wrote Avahi's file, with no restart" eventually 30 published
ssh_guest "cat $FILE" >"$RUN_DIR/origaitv.service" 2>&1 || true
cat "$RUN_DIR/origaitv.service"
check "the file is root's, and anyone may read it" test "$(ssh_guest "stat -c %U:%G:%a $FILE" 2>/dev/null)" = "root:root:644"

id=$(ssh_sudo "cat /var/lib/origaitv/daemon/box-id" 2>/dev/null | tr -d '[:space:]' || true)
version=$(ssh_guest "sed -n 's/^ORIGAITV_VERSION=//p' /usr/share/origaitv/settings" 2>/dev/null | head -n 1 || true)
# What the TV is called until somebody names it, and the machine's own
# name, which is something else and never changes here.
name=OrigaiTV
machine=$(ssh_guest hostname 2>/dev/null || true)
log "The box: called $name, machine ${machine:-none}, version ${version:-none}, id ${id:-none}"
check "the machine has a name of its own, which isn't the TV's" test -n "$machine" -a "$machine" != "$name"
check "T28.6 Avahi's file has the TV's name, and Avahi is told to fill nothing in" grep -qxF "  <name replace-wildcards=\"no\">$name</name>" "$RUN_DIR/origaitv.service"
check "T25.1 the box id is 16 random bytes in hex" grep -Eqx '[0-9a-f]{32}' <<<"$id"
check "kept in the daemon's state, where only the daemon reads it" test "$(ssh_sudo "stat -c %U:%a /var/lib/origaitv/daemon/box-id" 2>/dev/null)" = "origaitv-server:600"

check "T25.1 a browse on the box finds $TYPE" eventually 30 found on-browse
cat "$RUN_DIR/on-browse.txt"
# The first resolved line, a field at a time.
field() {
  grep '^=;' "$RUN_DIR/$1.txt" | head -n 1 | cut -d ';' -f "$2"
}
browse_has() {
  local txt
  txt=$(field "$1" 10-)
  [[ $(plain "$(field "$1" 4)") == "$name" && $(field "$1" 9) == "3001" && $txt == *"\"id=$id\""* && $txt == *"\"version=$version\""* ]]
}
check "T25.1 with the name, the phones' port, the version and the id" browse_has on-browse
check "T28.6 before it's named, the browse finds the TV as OrigaiTV, and not by the machine's name" found_as OrigaiTV unnamed-browse
only_two() {
  [[ $(field "$1" 10- | grep -o '"[^"]*"' | wc -l) -eq 2 ]]
}
check "and nothing else in the record" only_two on-browse
check "the record is on IPv4, as the phones' port is" bash -c "! grep -q '^=;[^;]*;IPv6;' '$RUN_DIR/on-browse.txt'"

# What somebody on the home network who isn't paired learns: the same four
# things, through the box's firewall.
phone_has() {
  jq -e --arg name "$name" --arg id "id=$id" --arg version "version=$version" \
    'length == 1 and .[0].name == $name and .[0].port == 3001 and .[0].txt == ([$id, $version] | sort)' "$RUN_DIR/$1.json" >/dev/null 2>&1
}
check "T25.1 a phone on the home network that asks everyone hears the TV" eventually 20 phone_hears browse on-phone-browse
cat "$RUN_DIR/on-phone-browse.json"
check "T25.1 with the name, the port, the version and the id, and nothing else" phone_has on-phone-browse
check "T28.6 before it's named, the phone hears the TV as OrigaiTV" jq -e '.[0].name == "OrigaiTV"' "$RUN_DIR/on-phone-browse.json"
check "at the box's own address on that network" jq -e '.[0].addresses | index("192.168.77.1") != null' "$RUN_DIR/on-phone-browse.json"
check "T25.1 a phone that asks the box alone is answered too, through the firewall's line" eventually 20 phone_hears ask on-phone-ask
cat "$RUN_DIR/on-phone-ask.json"
check "with the same record" phone_has on-phone-ask
no_hardware_address() {
  local all
  all=$(ssh_guest "cat /sys/class/net/*/address" 2>/dev/null | grep -v '^00:00:00:00:00:00$' | paste -sd '|' || true)
  [[ -n $all ]] && ! grep -Eiq "$all" "$RUN_DIR/on-phone-browse.json" "$RUN_DIR/on-phone-ask.json" "$RUN_DIR/origaitv.service" "$RUN_DIR/on-browse.txt"
}
check "no hardware address of the box's is in what it announces" no_hardware_address

# --- A paired phone, and one that isn't -------------------------------------

call /api/phone/state >"$RUN_DIR/on-state.json" || true
call /api/phone/box >"$RUN_DIR/on-box.json" || true
jq -c '{wake}' "$RUN_DIR/on-box.json" 2>/dev/null || true
check "T25.1 a paired phone learns the id from the state" jq -e --arg id "$id" '.boxId == $id' "$RUN_DIR/on-state.json"
# The box's own wired port: the one its way out goes through.
wired=$(ssh_guest "ip -4 -o route show default | awk '{ for (i = 1; i <= NF; i++) if (\$i == \"dev\") print \$(i + 1) }' | head -n 1" 2>/dev/null || true)
mac=$(ssh_guest "cat /sys/class/net/$wired/address" 2>/dev/null || true)
broadcast=$(ssh_guest "ip -4 -o addr show dev $wired | awk '{ for (i = 1; i <= NF; i++) if (\$i == \"brd\") print \$(i + 1) }' | head -n 1" 2>/dev/null || true)
log "The box's wired port: ${wired:-none}, ${mac:-no address}, broadcast ${broadcast:-none}"
check "T25.1 and gets the wired port's hardware address and its network's broadcast address" \
  jq -e --arg mac "$mac" --arg broadcast "$broadcast" '($mac | length) == 17 and .wake == {mac: $mac, broadcast: $broadcast}' "$RUN_DIR/on-box.json"
second=$(pair_phone "announce check 2" || true)
check "a phone that pairs now gets the same id in its state" test "$(ssh_guest "origaitv-phone-call $second GET /api/phone/state" 2>/dev/null | jq -r '.boxId // empty')" = "$id"

address=$(ssh_guest "ip -4 -o addr show dev $wired | awk '{print \$4}' | cut -d/ -f1 | head -n 1" 2>/dev/null || true)
for path in /api/phone/box /api/phone/state; do
  ssh_guest "curl -s -o /tmp/origaitv-announce/refused -w '%{http_code}' http://$address:3001$path" >"$RUN_DIR/refused-code.txt" 2>/dev/null || true
  ssh_guest "cat /tmp/origaitv-announce/refused" >"$RUN_DIR/refused.json" 2>/dev/null || true
  check "T25.1 $path refuses a phone that isn't paired" test "$(cat "$RUN_DIR/refused-code.txt")" = "401"
  check "and says nothing of the id or the hardware address" bash -c "! grep -Eiq '${id:-no id}|${mac:-no address}|wake|boxId' '$RUN_DIR/refused.json'"
done
ssh_guest "curl -fsS --max-time 10 $TV/api/box" >"$RUN_DIR/own-box.json" 2>/dev/null || true
check "the TV's own pages get the box without it" bash -c "test -s '$RUN_DIR/own-box.json' && ! grep -Eiq '${mac:-no address}|wake' '$RUN_DIR/own-box.json'"

# --- A name for the TV (T28.6) ----------------------------------------------

check "T28.6 before it's named, a paired phone reads OrigaiTV in its state" jq -e '.boxName == "OrigaiTV"' "$RUN_DIR/on-state.json"
check "and the TV's own pages read the same" test "$(daemon_get /api/name | jq -r '.name // empty')" = "OrigaiTV"

# heard_as <name> <file's name>: the phone that asks everyone hears one TV,
# under this name, with the same port, version and id as before.
heard_as() {
  phone browse "$2"
  jq -e --arg name "$1" --arg id "id=$id" --arg version "version=$version" \
    'length == 1 and .[0].name == $name and .[0].port == 3001 and .[0].txt == ([$id, $version] | sort)' "$RUN_DIR/$2.json" >/dev/null 2>&1
}
# The name between the tags of Avahi's file, as root wrote it.
written_as() {
  ssh_guest "cat $FILE" >"$RUN_DIR/$2.service" 2>/dev/null || true
  grep -qxF "  <name replace-wildcards=\"no\">$1</name>" "$RUN_DIR/$2.service"
}

# From the TV's own pages, as Settings sends it. No PIN is set on this box.
name="Dnevna soba"
ssh_guest "curl -fsS --max-time 10 -X PUT -H 'Content-Type: application/json' -d '{\"name\":\"  $name \"}' $TV/api/name" >"$RUN_DIR/named.json" 2>"$RUN_DIR/named.err" || true
check "T28.6 the TV takes a name from its own pages, trimmed" jq -e --arg name "$name" '.ok == true and .name == $name' "$RUN_DIR/named.json"
check "T28.6 root writes the new name, with no restart" eventually 30 written_as "$name" named
check "T28.6 the browse finds the TV under its name, space and all, and no longer as OrigaiTV" eventually 30 found_as "$name" named-browse
cat "$RUN_DIR/named-browse.txt"
check "with the same port, version and id" browse_has named-browse
check "T28.6 a phone on the home network hears one TV, under that name" eventually 20 heard_as "$name" named-phone
cat "$RUN_DIR/named-phone.json"
check "T28.6 a paired phone reads the name in its state" test "$(call /api/phone/state | jq -r '.boxName // empty')" = "$name"
check "T28.6 the machine's own name didn't move" test "$(ssh_guest hostname 2>/dev/null)" = "$machine"

# From a paired phone: an ampersand, both angle brackets, both quotes, an
# accent, an emoji, and the two letters Avahi would swap for the machine's
# name if root let it. It's handed over as a file, so no shell on the way
# reads a character of it.
name="Tom & Jerry's <\"Küche\"> %h 📺"
jq -cn --arg name "$name" '{name: $name}' >"$RUN_DIR/hard-name.json"
ssh_guest "cat >/tmp/origaitv-announce/name.json" <"$RUN_DIR/hard-name.json"
ssh_guest "origaitv-phone-call $key POST /api/phone/name \"\$(cat /tmp/origaitv-announce/name.json)\"" >"$RUN_DIR/hard-named.json" 2>"$RUN_DIR/hard-named.err" || true
check "T28.6 the TV takes a name from a paired phone, as it was typed" jq -e --arg name "$name" '.ok == true and .name == $name' "$RUN_DIR/hard-named.json"
check "T28.6 root writes it with its five characters escaped, and the rest as typed" eventually 30 written_as "Tom &amp; Jerry&#39;s &lt;&quot;Küche&quot;&gt; %h 📺" hard
cat "$RUN_DIR/hard.service"
check "T28.6 the browse finds the TV under exactly that, with %h still %h" eventually 30 found_as "$name" hard-browse
cat "$RUN_DIR/hard-browse.txt"
check "with the same port, version and id" browse_has hard-browse
check "T28.6 and so does a phone on the home network" eventually 20 heard_as "$name" hard-phone
cat "$RUN_DIR/hard-phone.json"
check "T28.6 both paired phones read it in their state" test "$(call /api/phone/state | jq -r '.boxName // empty')|$(ssh_guest "origaitv-phone-call $second GET /api/phone/state" 2>/dev/null | jq -r '.boxName // empty')" = "$name|$name"
check "and the TV's own pages do" test "$(daemon_get /api/name | jq -r '.name // empty')" = "$name"
check "the id is the one it was" test "$(call /api/phone/state | jq -r '.boxId // empty')" = "$id"

# --- The same id and the same name after a restart --------------------------

ssh_sudo "systemctl restart origaitv-daemon.service" >"$RUN_DIR/restart.log" 2>&1 || true
check "the daemon is back" until_json /health '.ok == true' 60
same_id() {
  [[ $(ssh_sudo "cat /var/lib/origaitv/daemon/box-id" 2>/dev/null | tr -d '[:space:]') == "$id" ]]
}
check "T25.1 the id is the same after a restart" same_id
check "and the daemon's hand-over as it started was taken" eventually 20 ssh_sudo "! test -e /var/lib/origaitv/daemon/announce-drop/announce.json"
check "T25.1 the browse still finds the TV" eventually 30 found restart-browse
check "T25.1 with the same name, port, version and id" browse_has restart-browse
check "T28.6 the TV is still found under its name, and only that" found_as "$name" restart-named-browse
check "and a paired phone reads the same id" test "$(call /api/phone/state | jq -r '.boxId // empty')" = "$id"
check "T28.6 and the same name" test "$(call /api/phone/state | jq -r '.boxName // empty')" = "$name"

# --- Off again --------------------------------------------------------------

guest "origaitv feature off announce" >>"$RUN_DIR/switch.log" 2>&1 || true
check "the announce switch is off again" until_json /api/features '.announce == false' 10
check "T25.1 off again: root took Avahi's file away, with no restart" eventually 30 unpublished
check "T25.1 off again: a browse on the box finds nothing" eventually 20 nothing_found again-browse
check "T25.1 off again: a phone that asks everyone hears nothing" eventually 20 phone_hears_nothing browse again-phone-browse
check "T25.1 off again: and nothing when it asks the box alone" phone_hears_nothing ask again-phone-ask
check "off again: a paired phone's state has no box id and no name" test "$(call /api/phone/state | jq -r 'has("boxId") or has("boxName")')" = "false"
check "off again: the TV's own pages have no name to give" test "$(ssh_guest "curl -s -o /dev/null -w '%{http_code}' --max-time 10 $TV/api/name" 2>/dev/null)" = "404"
check "off again: and its box answer has nothing to wake the TV by" test "$(call /api/phone/box | jq -r 'has("wake")')" = "false"

# What root's hand-over said, and that it never failed.
ssh_sudo "journalctl -b -u origaitv-announce.service --no-pager" >"$RUN_DIR/announce.log" 2>&1 || true
cat "$RUN_DIR/announce.log"
check "root's hand-over never failed" bash -c "! grep -Eq 'Failed|failed with result' '$RUN_DIR/announce.log'"
check "it wrote the file as the switch came on and once for each new name, and took it away once" bash -c "[[ \$(grep -c 'is announced on the home network' '$RUN_DIR/announce.log') == 3 && \$(grep -c \"isn't announced on the home network any more\" '$RUN_DIR/announce.log') == 1 ]]"
check "T28.6 root took every name it was handed" bash -c "! grep -q 'announced as OrigaiTV' '$RUN_DIR/announce.log'"
ssh_sudo "journalctl -b -u avahi-daemon.service --no-pager" >"$RUN_DIR/avahi.log" 2>&1 || true
grep -i "origaitv" "$RUN_DIR/avahi.log" | tail -n 20 || true
check "T28.6 Avahi read OrigaiTV's file each time, and refused no name" bash -c "! grep -i 'origaitv.service' '$RUN_DIR/avahi.log' | grep -Eiq 'fail|error|invalid'"

ssh_sudo "ip netns pids origaitv-lan | xargs -r kill; ip netns del origaitv-lan" >/dev/null 2>&1 || true
stop_vm
finish
