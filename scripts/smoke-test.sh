#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
image="${1:?Usage: scripts/smoke-test.sh IMAGE}"
name="brave-test-$$"
volume="${name}-config"
test_files=$(mktemp -d)
cleanup() {
    result=$?
    if (( result )); then
        docker logs --tail 60 "$name" 2>/dev/null || true
        docker exec "$name" tail -50 /config/state/session.log 2>/dev/null || true
    fi
    docker rm -fv "$name" "${name}-conflict" "${name}-invalid" "${name}-updates" "${name}-storage" "${name}-unlocked" >/dev/null 2>&1 || true
    docker volume rm "$volume" "${volume}-unlocked" >/dev/null 2>&1 || true
    rm -rf "$test_files"
    exit "$result"
}
trap cleanup EXIT
wait_ready() {
    for ((i=0; i<60; i++)); do
        if docker exec "$name" bash /usr/local/bin/healthcheck.sh >/dev/null 2>&1; then return; fi
        sleep 1
    done
    echo 'Container did not become ready.' >&2; return 1
}
http_code() {
    docker exec "$name" curl -k -s -o /dev/null -w '%{http_code}' "$@" https://127.0.0.1:8443/
}
docker volume create "$volume" >/dev/null
# Same restrictions as compose.yaml and the Unraid template.
run_opts=(--shm-size=1g --security-opt seccomp=unconfined --security-opt no-new-privileges=true
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --cap-add KILL --pids-limit 2048)
docker run -d --name "$name" "${run_opts[@]}" \
    -v "$volume:/config" -e PUID=99 -e PGID=100 -e AUTO_UPDATE=false \
    -e ENABLE_GPU=false -e AUTH_ENABLED=true -e AUTH_PASSWORD=smoke-test-only \
    -e DISPLAY_WIDTH=1280 -e DISPLAY_HEIGHT=720 -e "BRAVE_FLAGS=--user-agent=smoke'quoted" "$image" >/dev/null
wait_ready
docker exec "$name" python3 -m pip check
[ "$(http_code)" = 401 ]
[ "$(http_code -u brave:smoke-test-only)" = 200 ]
[ "$(http_code -u brave:smoke-test-only -H 'Origin: https://127.0.0.1:8443')" = 200 ]
[ "$(http_code -u brave:smoke-test-only -H 'Origin: https://untrusted.example')" = 403 ]
[ "$(http_code -u brave:smoke-test-only -H 'Origin: null')" = 403 ]
docker exec "$name" curl -ksI -u brave:smoke-test-only https://127.0.0.1:8443/ | python3 -c 'import sys; h=sys.stdin.read().lower(); assert "frame-ancestors" in h and "x-frame-options: sameorigin" in h and "referrer-policy: no-referrer" in h and "nosniff" in h'
# Only Brave's sandbox helper may carry setuid; nothing carries file capabilities.
docker exec "$name" sh -c 'test "$(find / -xdev -type f -perm /6000)" = /opt/brave.com/brave-origin/chrome-sandbox && test -z "$(getcap -r / 2>/dev/null)"'
docker exec "$name" sh -c '! command -v gpg'
[ "$(docker exec "$name" dpkg-query -W -f='${db:Status-Status}' brave-origin)" = installed ]
docker exec "$name" sh -c '! pgrep -x Xwayland && ! pgrep -x Xvnc && ! pgrep -x openbox && ! command -v Xwayland && ! dpkg-query -W xwayland 2>/dev/null'
docker exec "$name" sh -c 'test -x /usr/local/bin/labwc && test -x /usr/local/bin/labwc-browser && ldd /usr/local/bin/labwc /usr/local/bin/labwc-browser | { ! grep -q "not found"; }'
# HSTS is off unless requested; the request limiter answers 429 past the burst.
docker exec "$name" curl -ksI -u brave:smoke-test-only https://127.0.0.1:8443/ | python3 -c 'import sys; assert "strict-transport-security" not in sys.stdin.read().lower()'
docker exec "$name" sh -c 'seq 1 80 | xargs -P 20 -I{} curl -k -s -o /dev/null -w "%{http_code}\n" -u brave:smoke-test-only https://127.0.0.1:8443/' | sort | uniq -c | python3 -c 'import sys; s=sys.stdin.read(); assert "200" in s and "429" in s, s'
sleep 3
docker exec "$name" sh -c 'test "$(awk "/^Uid:/ {print \$2}" /proc/$(cat /tmp/brave.pid)/status)" = 99'
docker exec "$name" sh -c 'tr "\0" " " < /proc/$(cat /tmp/brave.pid)/cmdline' | python3 -c 'import sys; s=sys.stdin.read(); assert "--ozone-platform=wayland" in s and "--no-sandbox" not in s'
docker exec "$name" runuser -u braveuser -- test ! -r /config/.passwd
# Verify session settings survived privilege dropping, with no login secrets.
docker exec "$name" runuser -u braveuser -- sh -c 'tr "\0" "\n" < /proc/$(cat /config/state/selkies.pid)/environ' | python3 -c 'import sys; s=sys.stdin.read(); assert "AUTH_PASSWORD=" not in s and "DISPLAY_WIDTH=1280" in s and "DISPLAY_HEIGHT=720" in s and "SELKIES_MANUAL_WIDTH=" not in s and "SELKIES_MANUAL_HEIGHT=" not in s'
# Verify display resizing using decoded frames from the live compositor.
docker cp tests/display.py "$name:/tmp/test-display.py"
docker exec "$name" runuser -u braveuser -- python3 /tmp/test-display.py
docker cp tests/window-lock.py "$name:/tmp/test-window-lock.py"
docker exec "$name" runuser -u braveuser -- env XDG_RUNTIME_DIR=/tmp/runtime-braveuser WAYLAND_DISPLAY=wayland-0 python3 /tmp/test-window-lock.py
# Verify Chromium actually created its namespace sandbox.
docker exec -i "$name" python3 - <<'PYTEST'
from pathlib import Path
browser = Path('/tmp/brave.pid').read_text().strip()
status = Path('/proc') / browser / 'status'
root_ids = next(x for x in status.read_text().splitlines() if x.startswith('NSpid:')).split()[1:]
sandboxed = []
for p in Path('/proc').glob('[0-9]*/status'):
    try:
        fields = dict(x.split(':', 1) for x in p.read_text().splitlines() if ':' in x)
        if fields.get('Name', '').strip() == 'brave' and len(fields.get('NSpid', '').split()) > len(root_ids):
            sandboxed.append(p.parent.name)
    except (FileNotFoundError, ProcessLookupError):
        pass
assert sandboxed, 'No Brave child process has a nested PID namespace'
print('Chromium namespace sandbox verified.')
PYTEST
# Real compositor clipboard, including fallback code used on older libraries.
docker cp tests/clipboard.py "$name:/tmp/clipboard-test.py"
docker exec "$name" runuser -u braveuser -- env XDG_RUNTIME_DIR=/tmp/runtime-braveuser WAYLAND_DISPLAY=wayland-0 python3 /tmp/clipboard-test.py
# Second container must fail before touching the shared profile.
docker run -d --name "${name}-conflict" -v "$volume:/config" -e AUTO_UPDATE=false -e AUTH_ENABLED=false "$image" >/dev/null
[ "$(docker wait "${name}-conflict")" != 0 ]
wait_ready
# Credentials survive restarts and reset without exposing hashes to Brave.
docker exec "$name" /usr/local/bin/reset-password.sh replacement-test-password >/dev/null
[ "$(http_code -u brave:smoke-test-only)" = 401 ]
[ "$(http_code -u brave:replacement-test-password)" = 200 ]
docker stop -t 30 "$name" >/dev/null
docker cp "$name:/config/profile/Default/Preferences" "$test_files/Preferences"
python3 - "$test_files/Preferences" <<'PYTEST'
import json, sys
profile = json.load(open(sys.argv[1]))['profile']
# SIGTERM is a session-ending shutdown, distinct from closing the last window.
assert profile['exit_type'] in ('Normal', 'SessionEnded'), profile['exit_type']
print('Container stop saved a clean browser profile.')
PYTEST
docker start "$name" >/dev/null
wait_ready
[ "$(http_code -u brave:replacement-test-password)" = 200 ]
# Backup state must stop profile writes, then resume the session.
docker exec "$name" /usr/local/bin/profile-control.sh quiesce
test "$(docker exec "$name" /usr/local/bin/profile-control.sh status)" = QUIESCED
docker exec "$name" sh -c '! pgrep -x brave'
docker exec "$name" python3 -c 'import json; p=json.load(open("/config/profile/Default/Preferences"))["profile"]; assert p["exit_type"] in ("Normal", "SessionEnded")'
docker exec "$name" /usr/local/bin/profile-control.sh resume
wait_ready
# Downgrade must stay blocked when AUTO_UPDATE=false.
docker exec "$name" /usr/local/bin/profile-control.sh quiesce
docker exec -u braveuser "$name" sh -c 'printf "999.0.0\n" > /config/state/last-brave-version'
docker exec "$name" /usr/local/bin/profile-control.sh resume >/dev/null
sleep 6
docker exec "$name" sh -c '! pgrep -x brave && test "$(cat /config/state/status)" = DOWNGRADE_BLOCKED && test "$(cat /config/state/last-brave-version)" = 999.0.0'
# The stock compositor build must run and honor window requests; HSTS must be opt-in.
docker volume create "${volume}-unlocked" >/dev/null
docker run -d --name "${name}-unlocked" "${run_opts[@]}" -v "${volume}-unlocked:/config" -e AUTO_UPDATE=false -e ENABLE_GPU=false \
    -e AUTH_ENABLED=true -e AUTH_PASSWORD=smoke-test-only -e BROWSER_LOCK_MAXIMIZED=false -e HSTS_ENABLED=true "$image" >/dev/null
for ((i=0; i<60; i++)); do docker exec "${name}-unlocked" bash /usr/local/bin/healthcheck.sh >/dev/null 2>&1 && break; sleep 1; done
docker exec "${name}-unlocked" bash /usr/local/bin/healthcheck.sh
docker exec "${name}-unlocked" sh -c 'pgrep -x labwc >/dev/null && ! pgrep -x labwc-browser'
docker exec "${name}-unlocked" curl -ksI -u brave:smoke-test-only https://127.0.0.1:8443/ | python3 -c 'import sys; assert "strict-transport-security: max-age=31536000" in sys.stdin.read().lower()'
docker cp tests/window-lock.py "${name}-unlocked:/tmp/test-window-lock.py"
docker exec "${name}-unlocked" runuser -u braveuser -- env XDG_RUNTIME_DIR=/tmp/runtime-braveuser WAYLAND_DISPLAY=wayland-0 python3 /tmp/test-window-lock.py --unlocked
docker rm -fv "${name}-unlocked" >/dev/null
# Invalid root user configuration must fail closed.
docker run -d --name "${name}-invalid" -e PUID=0 -e AUTO_UPDATE=false "$image" >/dev/null
[ "$(docker wait "${name}-invalid")" != 0 ]
# Simulate update failure modes without contacting package servers or changing packages.
docker create --name "${name}-updates" --entrypoint python3 "$image" /tmp/update-test.py >/dev/null
docker cp tests/update.py "${name}-updates:/tmp/update-test.py"
docker start -a "${name}-updates"
[ "$(docker wait "${name}-updates")" = 0 ]
docker create --name "${name}-storage" --network none --entrypoint python3 "$image" /tmp/storage-test.py >/dev/null
docker cp tests/storage.py "${name}-storage:/tmp/storage-test.py"
docker start -a "${name}-storage"
[ "$(docker wait "${name}-storage")" = 0 ]
echo 'All container smoke tests passed.'
