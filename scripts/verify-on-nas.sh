#!/usr/bin/env bash
# On-device verification script (run once after an App Center manual install;
# also usable for apt installs, upgrades and uninstall regressions).
#
# Usage:
#   bash scripts/verify-on-nas.sh                 # defaults to: ssh tnas-57
#   bash scripts/verify-on-nas.sh <ssh-alias>
#   bash scripts/verify-on-nas.sh root@192.168.1.10
#
# The TOS admin account is uid 0, so do not prefix with sudo.
set -u

HOST="${1:-tnas-57}"
APP=kavita
PORT=8500
WEB=8181

run() { ssh -o ConnectTimeout=10 "$HOST" "$@"; }

echo "===== 0. Connectivity ====="
run 'echo "host: $(hostname) / $(dpkg --print-architecture)"' \
  || { echo "SSH unreachable - check the network and the alias"; exit 1; }

echo
echo "===== 1. dpkg and service state ====="
run "dpkg-query -W -f='dpkg: \${Status} \${Version}\n' $APP 2>/dev/null || echo 'dpkg: not installed'
echo \"active: \$(systemctl is-active $APP 2>/dev/null) / enabled: \$(systemctl is-enabled $APP 2>/dev/null)\""

echo
echo "===== 2. App Center registration artifacts (pitfall 11: stuck-install criteria) ====="
run "echo -n 'sc.d registration: '; [ -s /etc/sc.d/$APP ] && echo \"non-empty \$(stat -c%s /etc/sc.d/$APP)B OK\" || echo 'empty/missing FAIL (registration did not complete)'
echo -n 'desktop oexe: '; n=\$(ls /var/subvols/*/@/@desktop/*[Kk]avita*.oexe 2>/dev/null | wc -l); echo \"\$n $([ \"\$n\" -ge 14 ] && echo OK || echo 'FAIL expected 14') (one set per user is normal on multi-user devices)\""

echo
echo "===== 3. Loopback + platform route ====="
run "ss -tlnp 2>/dev/null | grep -q '127.0.0.1:$PORT' && echo 'loopback $PORT: OK listening' || echo 'loopback $PORT: FAIL not listening'
ss -tlnp 2>/dev/null | grep -qE '(0\.0\.0\.0|\*):$PORT' && echo 'WARNING: port exposed (non-loopback listener)' || echo 'loopback closed: OK (no external listener)'
curl -s -o /dev/null -w 'health endpoint /$APP/api/health: %{http_code}\n' http://127.0.0.1:$WEB/$APP/api/health
curl -s -o /dev/null -w 'platform route /$APP/: %{http_code}\n' http://127.0.0.1:$WEB/$APP/
curl -s -o /dev/null -w 'privacy policy (review C3): %{http_code}\n' http://127.0.0.1:$WEB/$APP/privacy-policy.html
curl -s http://127.0.0.1:$WEB/$APP/api/health | head -c 40; echo"

echo
echo "===== 4. Compliance artifacts (review V6/C3) ====="
run "for f in /usr/local/$APP/bin/BUILD-INFO /usr/local/$APP/PROVENANCE.md /usr/local/$APP/privacy-policy.html /usr/local/$APP/bin/Kavita; do
  if [ -e \"\$f\" ]; then echo \"OK   \$f\"; else echo \"FAIL missing \$f\"; fi
done
echo '--- BUILD-INFO ---'; cat /usr/local/$APP/bin/BUILD-INFO 2>/dev/null
echo -n 'bin/Kavita architecture: '; file /usr/local/$APP/bin/Kavita 2>/dev/null | cut -d: -f2 | cut -c1-60"

echo
echo "===== 5. Data directory and permissions ====="
run "ls -ld /var/lib/$APP 2>/dev/null || echo '/var/lib/$APP does not exist yet (created on first start)'
[ -f /var/lib/$APP/appsettings.json ] && echo -n 'appsettings.json: ' && md5sum /var/lib/$APP/appsettings.json | cut -c1-12 || echo 'appsettings.json not generated yet (appears after the first-run wizard)'
grep -o '<base href=\"[^\"]*\">' /usr/local/$APP/bin/wwwroot/index.html 2>/dev/null | head -1"

echo
echo "===== 6. Logs (last 20 lines, for troubleshooting) ====="
run "journalctl -u $APP -n 20 --no-pager 2>/dev/null | tail -20" || true

echo
echo "===== Done: paste the output above back to the assistant for a verdict ====="
