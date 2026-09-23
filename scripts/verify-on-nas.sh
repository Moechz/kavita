#!/usr/bin/env bash
# 真机验证脚本（App Center 手动安装后跑一遍；也可用于 apt 路径/升级回归）
#
# 用法：
#   bash scripts/verify-on-nas.sh              # 默认 ssh tnas-57
#   bash scripts/verify-on-nas.sh <ssh别名>
#   bash scripts/verify-on-nas.sh root@192.168.124.57
#
# TOS 管理账户即 uid 0，不加 sudo。对应 docs/TASK_STATE.md §8 验证清单。
set -u

HOST="${1:-tnas-57}"
APP=kavita
PORT=8500
WEB=8181

run() { ssh -o ConnectTimeout=10 "$HOST" "$@"; }

echo "===== 0. 连通性 ====="
run 'echo "主机: $(hostname) / $(dpkg --print-architecture)"' || { echo "SSH 不通，检查网络/别名"; exit 1; }

echo
echo "===== 1. dpkg 与服务状态 ====="
run "dpkg-query -W -f='dpkg: \${Status} \${Version}\n' $APP 2>/dev/null || echo 'dpkg: 未安装'
echo \"active: \$(systemctl is-active $APP 2>/dev/null) / enabled: \$(systemctl is-enabled $APP 2>/dev/null)\""

echo
echo "===== 2. App Center 注册产物（坑 11：卡死判据）====="
run "echo -n 'sc.d 注册: '; [ -s /etc/sc.d/$APP ] && echo \"非空 \$(stat -c%s /etc/sc.d/$APP)B ✓\" || echo '空/缺失 ✗（注册未走完）'
echo -n '桌面 oexe: '; n=\$(ls /var/subvols/*/@/@desktop/*[Kk]avita*.oexe 2>/dev/null | wc -l); echo \"\$n 个 $([ \"\$n\" -ge 14 ] && echo ✓ || echo '✗ 预期 14')（多用户机器上按用户多份属正常）\""

echo
echo "===== 3. 回环 + 平台路由 ====="
run "ss -tlnp 2>/dev/null | grep -q '127.0.0.1:$PORT' && echo '回环 $PORT: ✓ 监听中' || echo '回环 $PORT: ✗ 未监听'
ss -tlnp 2>/dev/null | grep -qE '(0\.0\.0\.0|\*):$PORT' && echo '⚠️ 端口外泄（非回环监听）' || echo '回环封闭: ✓ 无对外监听'
curl -s -o /dev/null -w '健康接口 /$APP/api/health: %{http_code}\n' http://127.0.0.1:$WEB/$APP/api/health
curl -s -o /dev/null -w '平台路由 /$APP/: %{http_code}\n' http://127.0.0.1:$WEB/$APP/
curl -s -o /dev/null -w '隐私政策(审核 C3): %{http_code}\n' http://127.0.0.1:$WEB/$APP/privacy-policy.html
curl -s http://127.0.0.1:$WEB/$APP/api/health | head -c 40; echo"

echo
echo "===== 4. 合规资产（审核 V6/C3）====="
run "for f in /usr/local/$APP/bin/BUILD-INFO /usr/local/$APP/PROVENANCE.md /usr/local/$APP/privacy-policy.html /usr/local/$APP/bin/Kavita; do
  if [ -e \"\$f\" ]; then echo \"✓ \$f\"; else echo \"✗ 缺失 \$f\"; fi
done
echo '--- BUILD-INFO ---'; cat /usr/local/$APP/bin/BUILD-INFO 2>/dev/null
echo -n 'bin/Kavita 架构: '; file /usr/local/$APP/bin/Kavita 2>/dev/null | cut -d: -f2 | cut -c1-60"

echo
echo "===== 5. 数据目录与权限 ====="
run "ls -ld /var/lib/$APP 2>/dev/null || echo '/var/lib/$APP 不存在（首启后创建）'
[ -f /var/lib/$APP/appsettings.json ] && echo -n 'appsettings.json: ' && md5sum /var/lib/$APP/appsettings.json | cut -c1-12 || echo 'appsettings.json 尚未生成（首启向导后出现）'
grep -o '<base href=\"[^\"]*\">' /usr/local/$APP/bin/wwwroot/index.html 2>/dev/null | head -1"

echo
echo "===== 6. 日志（最近 20 行，排障用）====="
run "journalctl -u $APP -n 20 --no-pager 2>/dev/null | tail -20" || true

echo
echo "===== 完成：把上面输出贴回给 AI 即可判定 ====="
