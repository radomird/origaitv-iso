#!/bin/bash
#
# OrigaiTV's sign-in (ADR-032, ADR-136) on an installed box: a stand-in app
# with signIn, for a sign-in page served on the box itself, says Sign in until
# it's signed in. origaitv screen sign-in opens it the way its tile does, with
# another page already open in the services' Chromium, so the app's window is
# one Chromium makes over its pipe, an ordinary browser window. The TV shows
# only the service's page, where any app goes, with nothing of OrigaiTV's over
# it and none of Chromium's tabs or address bar. "I'm signed in" is the
# phone's, and asks the app now. Home ends it, with the app asked once more.
# Opened again, the app takes its page to the site's form, the virtual
# keyboard fills it in as the phone will, and once the site's cookie says so,
# the app says it's signed in by itself, and the tile stops saying Sign in.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

start_vm_from_base
wait_for_ssh 300 failure-sign-in-ssh-timeout || exit 1
wait_tv 240 >/dev/null || { capture_console "failure-sign-in-no-tv"; check "the TV session came up" false; stop_vm; finish; }
passwordless_sudo

guest "origaitv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 5

id=local.sign-in-check
site=http://127.0.0.1:8767

# The service: a home page, and its own sign-in form, which sets its cookie.
ssh_guest "mkdir -p /tmp/origaitv-sign-in-check && cat >/tmp/origaitv-sign-in-check/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Check TV</title>
<body style="background:#fff;color:#000;font:28px sans-serif;margin:60px"><h1>Check TV</h1><p>Welcome.</p></body>
HTML
ssh_guest "cat >/tmp/origaitv-sign-in-check/login.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Sign in to Check TV</title>
<body style="background:#fff;color:#000;font:28px sans-serif;margin:60px">
<h1>Sign in to Check TV</h1>
<form id="login"><input name="email" autocomplete="username" autofocus><input name="password" type="password" autocomplete="current-password"><button>Sign in</button></form>
<script>document.getElementById("login").addEventListener("submit", (e) => { e.preventDefault(); document.cookie = "signed=in; path=/"; location.href = "/"; });</script>
</body>
HTML
ssh_guest "cd /tmp/origaitv-sign-in-check && (nohup python3 -m http.server 8767 --bind 127.0.0.1 >requests.log 2>&1 &)"

# The app: it asks the site's cookie whether it's signed in, and takes its
# page to the form.
ssh_guest "mkdir -p /tmp/origaitv-sign-in-check/app && cat >/tmp/origaitv-sign-in-check/app/manifest.json" <<JSON
{
  "schemaVersion": 1, "id": "$id", "name": "Sign-in check", "version": "1.0.0", "author": "origaitv", "license": "MIT",
  "description": "A stand-in for a streaming service with a sign-in", "kinds": ["tv-app"], "entryPoints": { "tvApp": "app.ts" },
  "tv": { "contract": 1, "category": "streaming", "runtime": "web", "homeUrl": "$site/", "origins": ["$site"],
    "capabilities": ["launch", "signIn"], "setup": [{ "type": "signIn" }], "childSafe": true }
}
JSON
ssh_guest "cat >/tmp/origaitv-sign-in-check/app/app.ts" <<'APP'
export default {
  id: "local.sign-in-check",
  async launch() {},
  signIn: {
    async isSignedIn(ctx) {
      return ctx.page.evaluate(() => document.cookie.split("; ").includes("signed=in"));
    },
    async open(ctx) {
      await ctx.page.goto("http://127.0.0.1:8767/login.html");
    },
  },
};
APP
# Installed the way an app built on this box is (ADR-039).
guest "origaitv app install --local /tmp/origaitv-sign-in-check/app --yes --stand-in" >"$RUN_DIR/install.log" 2>&1 || true
check "the stand-in installs with origaitv app install --local" grep -q "^Installed Sign-in check 1.0.0" "$RUN_DIR/install.log"

signin_bar() {
  guest_hyprctl "-j layers" 2>/dev/null | jq -e '[.. | objects | select(.namespace? == "origaitv-signin")] | length > 0' >/dev/null
}

no_signin_bar() {
  ! signin_bar
}

# Where an app goes once it's signed in: full screen, or maximized inside
# Fit to screen's margin while there is one. A release from before it says
# no margin.
page_fullscreen() {
  local margin want=2
  margin=$(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/display" 2>/dev/null | jq -r '.margin // 0' 2>/dev/null || echo 0)
  [[ ${margin:-0} != 0 ]] && want=1
  guest_hyprctl "-j clients" 2>/dev/null | jq -e --argjson want "$want" '.[] | select(.workspace.name == "1" and .fullscreen == $want)' >/dev/null
}

signs_in() {
  ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/home" | jq -r --arg id "$id" '.apps[] | select(.id == $id) | .signIn // "done"'
}
check "the app's tile says Sign in before it's signed in" test "$(signs_in)" = "needed"

# Another page open first, so the sign-in's window is the services' second.
guest "origaitv screen open $site/" >"$RUN_DIR/open.json" 2>&1 || true
for _ in $(seq 1 20); do
  guest_hyprctl "-j clients" 2>/dev/null | jq -e '.[] | select(.workspace.name == "1" and (.title | test("Check TV")))' >/dev/null 2>&1 && break
  sleep 0.5
done

guest "origaitv screen sign-in $id" >"$RUN_DIR/sign-in.json" 2>&1 || true
cat "$RUN_DIR/sign-in.json"
check "origaitv screen sign-in opens the sign-in screen" jq -e '.ok == true' "$RUN_DIR/sign-in.json"

height=$(guest_hyprctl "-j monitors" 2>/dev/null | jq '.[0].height / .[0].scale | floor' 2>/dev/null || echo 0)

# Up to 30 s for the page and the form.
for _ in $(seq 1 60); do
  page_fullscreen && ssh_guest "grep -q 'GET /login.html' /tmp/origaitv-sign-in-check/requests.log" && break
  sleep 0.5
done
guest_hyprctl "-j layers" >"$RUN_DIR/layers.json" 2>/dev/null || true
guest_hyprctl "-j clients" >"$RUN_DIR/clients.json" 2>/dev/null || true
check "the app took its page to the site's sign-in form" ssh_guest "grep -q 'GET /login.html' /tmp/origaitv-sign-in-check/requests.log"
check "nothing of OrigaiTV's is over the page: no sign-in bar" no_signin_bar
check "the page is where an app goes: full screen, or inside Fit to screen's margin" page_fullscreen
# With no margin, the page reaches the bottom of the screen: no room is kept
# there for a bar.
margin=$(ssh_guest "curl -fsS --max-time 3 http://127.0.0.1:3000/api/display" 2>/dev/null | jq -r '.margin // 0' 2>/dev/null || echo 0)
if [[ ${margin:-0} == 0 ]]; then
  # shellcheck disable=SC2016 # $height is jq's own
  check "and it fills the screen, down to the bottom" \
    jq -e --argjson height "${height:-0}" '$height > 0 and ([.[] | select(.workspace.name == "1")][0] | .at[1] + .size[1] >= $height - 2)' "$RUN_DIR/clients.json"
fi
sleep 2
capture_console "success-sign-in-screen"
# Chromium's own bars would show the page's address at the top. The page's
# own words don't have it.
: >"$RUN_DIR/top.txt"
if magick "$RUN_DIR/success-sign-in-screen.png" -resize '1920x1080>' -gravity north -crop 100%x12%+0+0 +repage "$RUN_DIR/.top.png" 2>/dev/null; then
  magick "$RUN_DIR/.top.png" -colorspace gray -resize 200% png:- 2>/dev/null | tesseract - - --psm 6 >"$RUN_DIR/top.txt" 2>/dev/null || true
fi
cat "$RUN_DIR/top.txt"
check "none of Chromium's tabs or address bar: the top of the screen has no address (OCR)" bash -c "test -s '$RUN_DIR/top.txt' && ! grep -aqE '127\\.0\\.0\\.1|8767|login\\.html' '$RUN_DIR/top.txt'"

# "I'm signed in" from a phone, before the form is sent: the app is asked
# now, and isn't yet.
guest "origaitv screen signed-in" >"$RUN_DIR/signed-in.json" 2>&1 || true
cat "$RUN_DIR/signed-in.json"
check "I'm signed in asks the app now, which says it isn't yet" jq -e '.ok == true and .signedIn == false' "$RUN_DIR/signed-in.json"

# With only a keyboard or the remote, Home ends the sign-in, and the app is
# asked once more on its way out. It isn't signed in yet, so its tile still
# says Sign in. Then the sign-in opens again, to finish it.
guest "origaitv screen home" >/dev/null 2>&1 || true
sleep 5
guest "journalctl --user -b --no-pager -u origaitv-screen" >"$RUN_DIR/home.log" 2>&1 || true
check "Home ends the sign-in" grep -q "sign-in to $id over: home" "$RUN_DIR/home.log"
check "and the tile still says Sign in, since the app isn't signed in yet" test "$(signs_in)" = "needed"
guest "origaitv screen sign-in $id" >"$RUN_DIR/sign-in-again.json" 2>&1 || true
for _ in $(seq 1 60); do
  page_fullscreen && break
  sleep 0.5
done
check "the sign-in opens again" jq -e '.ok == true' "$RUN_DIR/sign-in-again.json"

# Typed the way the phone will, the password from stdin.
printf 'viewer@example.org\tcheck-%s' "$RANDOM$RANDOM" | ssh_guest "bash -lc 'origaitv input text -'" >"$RUN_DIR/input.log" 2>&1 || true
guest "origaitv input key enter" >>"$RUN_DIR/input.log" 2>&1 || true

done_at=""
for second in $(seq 1 20); do
  if [[ $(signs_in) == "done" ]]; then
    done_at=$second
    break
  fi
  sleep 1
done
check "once the form is sent, the app says it's signed in, and the tile stops saying Sign in" test -n "$done_at"
sleep 2
check "and the page stays where an app goes: full screen, or inside Fit to screen's margin" page_fullscreen

guest "journalctl --user -b --no-pager -u origaitv-screen -u origaitv-input" >"$RUN_DIR/tv-session.log" 2>&1 || true
check "the screen daemon says the sign-in is over because it signed in, by itself" grep -q "sign-in to $id over: signed in" "$RUN_DIR/tv-session.log"
check "nothing the keyboard typed is in the TV session's log" bash -c "! grep -q 'check-[0-9]' '$RUN_DIR/tv-session.log'"

guest "origaitv screen quit $id" >/dev/null 2>&1 || true
guest "origaitv app remove $id" >/dev/null 2>&1 || true
stop_vm
finish
