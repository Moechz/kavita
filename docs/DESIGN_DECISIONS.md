# Design decisions

## 打开方式与路由

### D-001: 采用 External Open（新标签页）模式，不做 iframe 集成
**Decision:** config.ini 使用 `"open_path": true` + `"path": "/kavita/"`（不出现 `type` 字段），应用从 TOS 桌面图标以新标签页打开。
**Consequences:**
- 直接原因：Kavita 上游 Startup.cs 对所有响应强制 `X-Frame-Options: SAMEORIGIN` + `Content-Security-Policy: frame-ancestors 'none'`，iframe 嵌入 TOS 桌面必被浏览器拒绝，除非改 `AllowIFraming` 配置——引入额外风险且非默认安全姿态。
- 与 beszel/navidrome/hermesagent 一致，SPA 全页运行零适配。
- 排除方案：iframe（metube 模式）因上游安全头而不可行。

### D-002: nginx 保留 `/kavita/` 前缀转发 + 上游原生 BaseUrl 子路径
**Decision:** `proxy_pass http://127.0.0.1:8500/kavita/;`（前缀保留），Kavita 以 `BaseUrl=/kavita/` 原生运行在子路径（navidrome 同款方案）。
**Consequences:**
- 上游支持链完整：`app.UsePathBase(basePath)`（Startup.cs）+ SPA `<base href>` 自写（UpdateBaseUrlInIndex）+ `ForwardedHeaders.All`（OPDS/邮件绝对 URL 能拿到正确 Host）。
- 构建期把 `wwwroot/index.html` 的 `<base href>` 预写为 `/kavita/`：沙箱下应用改写失败（只读 /usr）也能正确寻址；同时给 `wwwroot/index.html` 单文件 `ReadWritePaths` 放行，让上游自写成功、避免每次启动留 error 日志。
- 排除方案：尾斜杠剥前缀模式（`proxy_pass …:8500/`）——Kavita SPA/API 会收到无前缀请求，与 BaseUrl 配置冲突，产生绝对路径 404。

## 运行时布局

### D-003: WorkingDirectory=/usr/local/kavita/bin + `bin/config` 符号链接 → /var/lib/kavita
**Decision:** 整个上游运行时树（二进制+wwwroot+I18N+Assets+EmailTemplates）放 `/usr/local/kavita/bin/`；systemd `WorkingDirectory` 指向它；`bin/config` 是随 deb 分发的符号链接，指向 `/var/lib/kavita`；postinst 负责自愈。
**Consequences:**
- 根因：Kavita 一切路径相对**进程 CWD** 解析（`DirectoryService`/`Program.cs` 均用 `GetCurrentDirectory()`），状态默认写 `$(CWD)/config/*`；若 CWD 在 /usr 且无放行，ProtectSystem=strict 下启动即写失败。
- 状态（kavita.db、covers、cache、logs、bookmarks、themes…）全部落数据卷 `/var/lib/kavita`，purge 语义干净；dpkg 只管理 /usr 侧文件，升级整树替换。
- 二进制在 `bin/` 下满足 TOS 规范"二进制必须在 bin/"。
- 边界：若用户曾手工在 `bin/config` 位置建过真实目录，postinst 打印迁移指引、不自动搬数据。
- 排除方案：整树放 /var/lib（dpkg 无法管理数据卷内文件）；postinst 把 wwwroot 拷进 /var/lib（升级同步复杂、混数据与代码）。

### D-004: 回环端口选 8500
**Decision:** `IpAddresses=127.0.0.1`、`Port=8500`（appsettings 模板兜底，verify 断言）。
**Consequences:**
- 官方推荐段 8000-19999；与兄弟项目错开：metube 8081、navidrome 8453、audiobookshelf 13378、vaultwarden 8222。
- 上游默认 5000 不采用（低于推荐段且易撞通用端口）。

### D-005: 首装配置走上游原生 appsettings-init.json 机制
**Decision:** postinst 只在 `appsettings.json` 与 `appsettings-init.json` 都不存在时投放 init 模板（Port/IpAddresses/BaseUrl 安全兜底值）；Kavita 首启自行把 init 重命名为正式配置并自动生成 JWT TokenKey（`EnsureJwtTokenKey`）。
**Consequences:**
- 兼顾坑 2（永不覆盖用户配置）与上游原生流程；TokenKey 不需要打包侧生成。
- 升级路径零动作：appsettings.json 存在则 init 不投放，应用保留用户全部配置。
- 排除方案：postinst 直接 sed 改写已存在配置（侵入用户数据）；生成 TokenKey（重复造上游轮子）。

### D-006: 不提供 env 覆盖能力（与 navidrome 模式的差异点）
**Decision:** 不设计"env 文件覆盖端口/地址"能力；`kavita.env` 只承载进程级环境变量（TZ、.NET GC 开关）。
**Consequences:**
- 根因：上游 `Program.cs` 的 `ConfigureAppConfiguration` 里 `config.Sources.Clear()` 后只加 JSON 文件源——环境变量对 Kavita 业务配置**完全无效**，navidrome 的 env>flags 优先级设计在此无对应物。
- 用户改端口/地址/前缀的唯一入口：`/var/lib/kavita/appsettings.json`（postinst 输出与 env.example 头部均有指引）。
- 安全兜底相应地放在模板值 + verify 阶段断言（等价于 navidrome 的 ExecStart 写死 flags 的防线作用）。

## 构建与分发

### D-007: 上游无 checksums 文件 → config.env 锚点 + 本地 lock 双保险
**Decision:** sha256 校验分两层：`config.env` 的 `KAVITA_X64_SHA256/KAVITA_ARM64_SHA256` 手工锚点优先；为空时用 `build/downloads/sha256.lock` 首记后校验。
**Consequences:**
- 防下载缓存被静默替换（坑 7 变体：Kavita 资产名带架构不带版本，同版本重发布理论可能）。
- 首次 fetch 后应把 lock 值固化进 config.env（构建日志会提醒）。

### D-008: 语言文件采用 23 语超集
**Decision:** `kavita.lang` 覆盖真机 14 语与官方英文文档 14 语两个口径的并集（23 键）。
**Consequences:**
- 沿用 hermesagent 已真机验证的口径；未翻译节点填英文的规则不适用（本包全部真实翻译）。
- 后续新增语言口径变化时只增不改。

### D-009: jemalloc 不预载
**Decision:** 不复刻上游 Docker entrypoint 的 `LD_PRELOAD=libjemalloc` 内存优化。
**Consequences:**
- TOS 基座无 libjemalloc 保证；缺失时上游脚本也只是打印提示继续跑。
- 低内存机型用户可自行在 `/usr/local/kavita/kavita.env` 加 `LD_PRELOAD`（apt 装 libjemalloc2 后）。

### D-010: 二进制改为公开 CI 源码自建（审核 V6 路线，2026-09-19）
**Decision:** 不再从上游 Release 下载预编译 tarball 打包；新增
`build-upstream.yml`（公开仓库 Moechz/kavita）从上游源码 tag 自建
linux-x64/arm64 tarball，构建步骤与上游 release-workflow.yml 逐字对齐
（Node 24 `npm ci --legacy-peer-deps && npm run prod` + `monorepo-build.sh`）。
fetch 双层校验：Release SHA256SUMS × config.env 锚点；tarball 内带 BUILD-INFO
（source_tag/commit/dotnet_sdk/run_id）；verify 断言 `built_from=source`。
**Rationale:**
- metube/hermesagent/alist/sftpgo/beszel 连续被 V6 驳回：deb 内一切预编译
  ELF/DLL 无公开可审计来源即一票否决（坑 30a/31/32/43）；.NET 应用整树
  都是"预编译物"，比单二进制 Go 应用更撞枪口。
- 采用 alist 级"哈希 pin + 公开 CI"可审计性（弱于 sftpgo 的位级复现路线）；
  若仍被驳，升级到坑 32 配方（两次独立构建位级一致自证）。
**Consequences:**
- 构建依赖公开 GitHub Actions（免费 runner），本地 build.sh 只消费
  build-v<tag> Release 的自建产物；上游 tag 升级时先跑 CI 再回填锚点。
- Release notes 备审三链接：workflow 文件 / 公开 Actions run / build-v Release。

### D-011: 隐私政策随包双落盘 + nginx 精确路由直出（审核 C3，2026-09-19）
**Decision:** 双语 privacy-policy.html 落 /usr/local/kavita/ +
`location = /kavita/privacy-policy.html` alias 直出；webui 占位页加链接（可发现性）。
**Rationale:** C3 驳回实锤（坑 45）：凡涉及账号/用户数据/外部请求的应用
隐私政策是必备资产；Kavita 有账号体系 + 上游匿名统计端点
（stats.kavitareader.com，可在 Server Settings → Analytics 关闭）+ 可选 SMTP，
政策中全部披露。遥测默认值是上游 DB 层设置，不由 appsettings 控制，
故选择"披露 + 关闭指引"而非改默认（避免未知键冒险）。
**Consequences:** 提审表单填公开仓库同源 URL，三处可达。

### D-012: 署名分工——publisher/auth 填上游，Maintainer 填打包者（坑 49）
**Decision:** config.ini publisher 与 lang auth = `Kavita Team`（上游）；
control Maintainer = Moechz（打包者），Description 尾部注明
"Upstream author / Packaged for TOS by"。
**Consequences:** 应用中心"开发者"列显示上游团队（用户认知与版权诚实），
dpkg 语义上包问题仍指向打包者。

### D-013: webui.bz2 归档属主归一化 root:root（审核 S11，2026-09-19）
**Decision:** 嵌套归档用 python tarfile 重打：uid/gid=0、uname/gname=root、
mtime=0；verify 断言全部条目 uid=0（macOS bsdtar 无 --owner，曾把打包机
uid 501 写进归档被 S11 警告）。
**Consequences:** 跨平台无 gnu-tar 依赖；makedeb 主归档本就 root:root，
嵌套归档口径从今对齐。
