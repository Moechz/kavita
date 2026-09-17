# Changelog

## 0.9.1.4-2 — 2026-09-17

### Fixed
- postinst 就绪探测改用免认证健康接口 `/kavita/api/health`（原探测 SPA 首页，
  语义不精确；首次启动需等数据库迁移完成，健康接口就绪即后端完全可用）。
- postrm purge 补清 postinst 生成的派生文件（kavita.env / index.html / 自建的
  bin/config 符号链接），purge 后 /usr/local/kavita 目录彻底消失。
- 构建修复：`TARGET_ARCH=arm64 ./build.sh` 环境变量不再被 config.env 覆盖；
  上游 tarball 内 Kavita apphost 为 0644，stage 阶段补执行位；makedeb 打包器
  兑底排除 macOS .DS_Store / ._ 污染物（350MB 树压缩耗时分钟级，stage 清理后
  可能再生成）。

## 0.9.1.4-1 — 2026-09-17

### Added
- 首个封装：基于 Kavita 上游 v0.9.1.4（.NET self-contained，官方 Release 二进制）。
- TOS 7 应用中心规范 deb：新标签页打开（`/kavita/` 路由），后端仅监听
  `127.0.0.1:8500`，不对外暴露端口。
- 原生子路径部署（上游 `BaseUrl=/kavita/` + SPA base href 构建期预写），
  nginx 保留前缀转发，OPDS（`/kavita/opds`）与 WebSocket（SignalR）全兼容。
- 状态目录经 `bin/config` 符号链接落在 `/var/lib/kavita`（数据库/封面/缓存/日志/书签），
  `apt remove` 保留、`apt purge` 清空；默认库目录 `/var/lib/kavita/library`。
- 首装引导走上游原生 `appsettings-init.json` 流程，JWT TokenKey 由应用首启自动生成。
- 专用低权用户 `kavita` + systemd 沙箱（NoNewPrivileges/ProtectSystem=strict 等）。
- 23 语超集多语言文件（覆盖真机 14 语与官方 14 语两个口径）。
