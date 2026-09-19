# Changelog

## 0.9.1.4-2 — 2026-09-17（2026-09-19 提审规范对齐整改）

### Fixed
- postinst 就绪探测改用免认证健康接口 `/kavita/api/health`（原探测 SPA 首页，
  语义不精确；首次启动需等数据库迁移完成，健康接口就绪即后端完全可用）。
- postrm purge 补清 postinst 生成的派生文件（kavita.env / index.html / 自建的
  bin/config 符号链接），purge 后 /usr/local/kavita 目录彻底消失。
- 构建修复：`TARGET_ARCH=arm64 ./build.sh` 环境变量不再被 config.env 覆盖；
  上游 tarball 内 Kavita apphost 为 0644，stage 阶段补执行位；makedeb 打包器
  兑底排除 macOS .DS_Store / ._ 污染物（350MB 树压缩耗时分钟级，stage 清理后
  可能再生成）。

### Changed（对照最新封装指南的提审驳回实录逐项整改）
- **V6（一票否决）**：不再分发上游预编译 tarball。新增公开 CI
  `build-upstream.yml` 从上游源码 tag 自建（步骤与上游 release-workflow.yml
  逐字对齐：Node 24 编 WebUI + monorepo-build.sh dotnet publish），
  tarball 携带 BUILD-INFO 溯源文件；fetch 对 Release SHA256SUMS 与
  config.env 锚点双层互验；verify 断言 built_from=source；
  随包附 /usr/share/doc/kavita/PROVENANCE.md 审计链说明。
- **C3（一票拒）**：新增双语隐私政策 privacy-policy.html，包内双落盘
  /usr/local/kavita/ + nginx 精确路由 /kavita/privacy-policy.html 直出，
  webui 占位页加可发现入口；披露上游匿名统计端点及关闭方法。
- **S11**：webui.bz2 嵌套归档改 python tarfile 重打（uid/gid=0、
  uname/gname=root、mtime=0），verify 断言全部条目 root:root
  （macOS bsdtar 无 --owner 参数，曾把打包机 uid 501 写进归档）。
- **V11 双重门禁**：check_assets 新增 `\bbeta\b` 全文打门（lang 现零命中；
  提审版本名仍为纯数字选增）。
- **坑 49 署名分工**：config.ini publisher 与 lang auth 改填上游
  `Kavita Team`；deb control Maintainer 仍为打包者，Description 尾部注明
  Upstream author / Packaged for TOS by。
- **零网络扫描**：verify 新增在线安装令牌扫描（pip install/--index-url/
  pypi/urlopen 等，S8 审查员同款扫法）；lang 23 语 release_note 同步把
  “官方构建”措辞改为“公开 CI 从上游源码构建”。

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
