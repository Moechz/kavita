# Task state

快照日期：2026-09-17
当前版本：0.9.1.4-2（上游 v0.9.1.4）
最近实现提交：初始封装（git init 后首个提交）

## 1. 仓库状态

- 首包全流程已验证，git init + 首提交（见 HANDOFF）。

## 2. 完成情况（按模块）

| 模块 | 状态 |
|---|---|
| 上游调研（config 解析/BaseUrl/首启流程/安全头） | ✅ 源码级确认（DESIGN_DECISIONS D-001~009） |
| 构建系统（build.sh 四阶段 + makedeb.sh + Makefile check） | ✅ 跑通 |
| 资产（config.ini/lang 23 语/图标/nginx/service/生命周期脚本） | ✅ 完成 |
| amd64 deb（0.9.1.4-2） | ✅ 构建通过 verify |
| arm64 deb（0.9.1.4-2） | ✅ 构建通过 verify + 解包 ELF 复核（坑 28） |
| 真机安装/升级/卸载（tnas-57，apt 路径） | ✅ 全部通过（见 §3） |
| 应用中心手动安装路径（坑 11/⑨） | ⬜ 手工步骤（需 TOS web UI 操作） |

## 3. 最近一次验证（2026-09-17，tnas-57 TOS 真机 x86_64）

命令与结果（amd64 包 0.9.1.4-1 → -2 全生命周期）：
- 安装：`apt install -y /tmp/kavita.deb` → postinst 就绪轮询通过；
  `systemctl is-active/is-enabled` = active/enabled
- 回环：`curl 127.0.0.1:8500/kavita/` = 200；`ss -tlnp` 仅 `127.0.0.1:8500`（外部 TCP 探测不可达）
- 平台路由：`curl 127.0.0.1:8181/kavita/` = 200；SPA 资源经前缀拉取 200（styles 489KB/chunk 均正常）
- 无尾斜杠 301：`Location: /kavita/`（相对、不丢端口，坑 13 ✓）
- API/OPDS/SignalR：`/kavita/api/health`=200 "Ok"；`/kavita/api/opds/FAKEKEY`=401 挑战；
  `POST /kavita/api/Account/login`=400（路由命中）；`/kavita/hub/negotiate`=200
- 首启链：`/var/lib/kavita/appsettings.json` 由 init 重命名生成，TokenKey 336 字符自动生成，
  Port=8500/IpAddresses=127.0.0.1/BaseUrl=/kavita/ 保持兜底值；wwwroot base href=/kavita/（单文件放行生效）
- 升级（-1 → -2）：appsettings.json md5 不变、数据目录 22 项不变、enabled 保持（坑 3 ✓）；
  启动日志 "Now listening on: http://127.0.0.1:8500"
- remove：数据/用户保留，服务与 nginx 注册清除
- purge：/var/lib/kavita 清空、用户删除、kavita.env/index.html/bin/config 派生物补清、
  /usr/local/kavita 目录完全消失、8181/kavita/ 回 404
- 最终状态：0.9.1.4-2 全新安装，active+enabled+health Ok（机器上保留可用状态）

产物（out/，Release tag = v0.9.1.4-2）：
- kavita_x86_64.deb 86,858,890B  sha256 953687301084ea52d261c4c23f831ff4f8364205fdae86adf2c8f4ab8b16ad8a
- kavita_aarch64.deb 82,707,652B  sha256 4e92f56aa4b7da273521ae2dc77944cae63d11f62321f8fdc4e13b23816f3335
- （本地测试包 kavita_0.9.1.4-2_{amd64,arm64}.deb 同内容带版本名）

## 4. 测试环境状态

- tnas-57（TOS 真机，x86_64）：kavita 0.9.1.4-2 已装、active、仅回环 8500。
- arm64 真机：无（aarch64 包只做了解包 ELF 断言，未装机）。

## 5. 开放问题

| # | 现象 → 结论 → 下一步 |
|---|---|
| 1 | 应用中心手动安装未测（需 TOS web UI 上传 deb）→ 结构与 navidrome/hermesagent 同构，风险点已在坑 11 排查清单内 → 送审前按指南 §五⑨ 走一遍：确认 /etc/sc.d/kavita 非空、oexe 14 个、不卡进度 |
| 2 | 桌面图标点击/浏览器首访向导属 GUI 冒烟 → API 层已验证向导端点存在（register/login 路由命中）→ 人工打开 http://<NAS>:8181/kavita/ 完成向导并建库一次 |
| 3 | journal 中 "Fatal ... This is not an error" 为上游迁移日志的日志级别怪癖（源码自称非错误）→ 无需处理，排障时注意不要误判 |
| 4 | arm64 未真机验证 → 无 aarch64 测试机 → 上架前如有条件补测；ELF/架构断言已防错包 |

## 6. 发布闸门

- [x] `make check` 通过
- [x] amd64/arm64 双架构 deb 构建通过 verify（含 ELF 架构断言 + 解包复核）
- [x] 真机 apt 安装：服务 active+enabled、回环 200、平台路由 200、无端口外泄
- [x] API/OPDS/SignalR/SPA 资源经 /kavita/ 前缀可达
- [x] 升级路径（-1 → -2）：数据/配置未动、is-enabled 保持
- [x] remove 保留 / purge 全清复核
- [ ] 浏览器首访向导 + 建库冒烟（GUI）
- [ ] 应用中心手动安装不卡进度（GUI，坑 11 判据）
- [ ] 提交前官方 review-standards 红线自查（含坑 15 S8 零网络 grep——本包无任何在线安装脚本，天然合规）

## 7. 建议的恢复顺序

1. 读 AGENTS.md §3 + DESIGN_DECISIONS.md。
2. 完成 §6 剩余两个 GUI 闸门（浏览器向导 / 应用中心 sideload）。
3. 上架：公开仓库 → Release v0.9.1.4-2 → 附 4 个资产（x86_64/aarch64 × deb+sha256）。

## 8. 常用命令

```bash
make check && ./build.sh                       # amd64
TARGET_ARCH=arm64 ./build.sh                   # aarch64（env 覆盖 config.env）
cat out/kavita_0.9.1.4-2_amd64.deb | ssh tnas-57 "cat > /tmp/kavita.deb" && ssh tnas-57 "apt install -y /tmp/kavita.deb"
ssh tnas-57 "systemctl status kavita --no-pager; curl -s http://127.0.0.1:8181/kavita/api/health"
```
