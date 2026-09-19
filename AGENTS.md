# Agent Instructions — kavita（Kavita for TOS 7 应用中心封装）

## 1. 项目是什么

把上游 **Kavita**（https://github.com/Kareadita/Kavita ，.NET 自包含发布的
数字图书馆/阅读服务器，漫画·Manga·电子书·杂志）封装成 **TOS 7 应用中心
规范的 deb 包**，供 TerraMaster NAS 应用中心上架/手动安装。

- 目标平台：TOS 7（Ubuntu 22.04 基座，systemd 249 / dpkg amd64|arm64）
- 模式：**WebUI External Open（新标签页）+ 回环监听 + 平台 nginx 保留前缀反代**
- 当前版本指向：`config.env`（KAVITA_VERSION + PKG_RELEASE，三处一致见 §11）
- 打包规范与硬坑总库：`~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md`（动手前通读）

## 2. 新会话阅读顺序

```
AGENTS.md → HANDOFF.md → docs/TASK_STATE.md → docs/DESIGN_DECISIONS.md
         → docs/CHANGELOG.md → README.md
```

## 3. 架构摘要

1. **二进制来源（审核 V6）**：公开仓库 `Moechz/kavita` 的 Actions 从上游源码
   tag 自建（`build-upstream.yml`，步骤与上游 release-workflow.yml 逐字对齐：
   Node 24 编 WebUI + monorepo-build.sh dotnet publish），产出 build-v<tag>
   Release（含 SHA256SUMS）。fetch 双层互验（Release 清单 × config.env 锚点）；
   tarball 自带 BUILD-INFO，verify 断言 built_from=source。
2. 自建 tarball 解包，整个运行时树（Kavita 二进制 + wwwroot + I18N + Assets +
   EmailTemplates…）进 `/usr/local/kavita/bin/`。
2. Kavita 以 **进程 CWD** 解析一切：状态在 `$(CWD)/config/*`、静态资源在 `$(CWD)/wwwroot`。
   故 systemd `WorkingDirectory=/usr/local/kavita/bin`，其中 `bin/config` 是指向
   `/var/lib/kavita` 的**符号链接**（deb 随包分发 + postinst 自愈），状态全落数据卷。
3. 子路径：上游原生 `BaseUrl=/kavita/`（Startup.UsePathBase + SPA `<base href>`，
   base href 由构建期预写 + 应用启动自写双保险）；nginx `proxy_pass …/kavita/` 保留前缀。
4. 无 CLI 参数、无环境变量覆盖（上游 `config.Sources.Clear()` 只读 JSON 配置）——
   端口/监听地址/前缀的安全兜底在 `appsettings-init.json` 模板，verify 阶段断言。
5. 首装引导：postinst 投放 `appsettings-init.json`（仅当两者都不存在），Kavita 首启自行
   重命名为 `appsettings.json` 并自动生成 JWT TokenKey；上游 X-Frame-Options/CSP
   禁 iframe，故必须 External Open。
6. systemd 沙箱：NoNewPrivileges/ProtectSystem=strict/ProtectHome，
   `ReadWritePaths=/var/lib/kavita` + 单文件 `/usr/local/kavita/bin/wwwroot/index.html`
   （应用启动时会写回 base href）。
7. 构建四阶段：`fetch`（下载自建产物+SHA256SUMS 双层校验）→ `stage`（组装+清洗+
   base href 重写）→ `verify`（规范断言+ELF 架构防呆+V6/S11/零网络红线）→
   `deb`（makedeb.sh 纯标准库打包）。

## 4. 目录布局与禁止触碰路径

```
kavita/
├── config.env            # 唯一版本/端口/架构配置来源
├── build.sh              # 四阶段构建主脚本
├── makedeb.sh            # 无 dpkg 依赖的 deb 打包器（navidrome 同款）
├── Makefile              # check = 语法/资产自检
├── assets/               # 全部随包资产（模板/脚本/多语言/图标）
│   ├── config.ini.in control.in
│   ├── init.d/kavita.service  nginx/kavita.conf
│   ├── appsettings-init.json  kavita.env  kavita.lang
│   ├── webui/index.html  preinst postinst prerm postrm
│   └── images/icons/kavita.svg
├── scripts/check_assets.py
├── build/                # 构建产物（git 忽略；downloads/ 是下载缓存）
└── out/                  # deb 产物（git 忽略）
```

**禁止触碰**：`build/downloads/`（缓存锚点，删了要重下 115MB×N）、
`makedeb.sh` 的 tar 归档逻辑（PAX 头坑，见指南坑 8）、`assets/init.d/` 下
不得新增第二个 service（坑 11）。

## 5. 开发约定

- 改配置只改 `config.env` + `assets/`，产物目录一律再生成，不手改 `build/pkgroot`。
- 所有文本资产 LF + 无 BOM；构建期 normalize_text 统一清洗，不要引入 CRLF。
- appid/用户/路径已定死 `kavita`（十处一致），**永不改名**（坑 18）。
- 上游升级：改 `KAVITA_VERSION` + 递增 `PKG_RELEASE`，先跑 `make check` 再 `./build.sh`。

## 6. 如何跑测试/自检

```bash
cd ~/Documents/projects/kavita
make check        # 语法 + 资产静态自检（不联网）
./build.sh        # fetch → stage → verify → deb 全流程（首次需下载 ~115MB）
./build.sh info   # 查看当前版本/架构/产物路径
```

真机验证清单见 `~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md` §五，
测试机 ssh 别名见 `~/Documents/projects/SSH-MACHINES.md`（tnas-57 为 TOS 真机）。

## 7. 如何构建/打包

```bash
# amd64（默认）
TARGET_ARCH=amd64 ./build.sh
# arm64（aarch64 NAS）
TARGET_ARCH=arm64 ./build.sh   # 或改 config.env 后重跑
```

产物：`out/kavita_<版本>_<arch>.deb`（本地测试）+ `out/kavita_{x86_64,aarch64}.deb(.sha256)`（上架资产）。

## 8. Git 规则

- 提交信息格式：`<类型>: <摘要>`（feat/fix/build/docs/chore）。
- 上架仓库公开；**内网 IP/主机名/凭据不入库**（坑 20），内部记录只写本文件树中的
  交接文档且不含地址密码。

## 9. 硬性技术约束

- 端口 **8500** 仅回环（`IpAddresses=127.0.0.1`），TOS web 为 8181，经 `/kavita/` 路由访问。
- systemd 单元**禁止 Restart/RestartSec**（商店审核项）、**ExecStart 禁止 `$` 变量**（坑 1）。
- prerm 升级路径**不得 disable**（坑 3）；配置首装**只在缺失时投放**（坑 2 conffile）。
- `init.d/` 只允许 1 个与 system_id 同名的 service（坑 11）。
- 构建机为 macOS：产物须过 AppleDouble/Mach-O/xattr 断言（坑 8/28）；
  嵌套归档（webui.bz2）必须 python tarfile root:root 重打（坑 46/S11）。
- **审核红线**：
  - V6：deb 内一切二进制必须公开可审计源（本包=CI 自建+BUILD-INFO+PROVENANCE，
    禁止回退到上游预编译 tarball，verify 有断言）；
  - C3：隐私政策三处可达（包内 + /kavita/privacy-policy.html 路由 + 提审表单）；
  - V11：lang 全文禁 `\bbeta\b`（check_assets 门禁）；
  - S8/零网络：包内脚本禁在线安装令牌（verify 有扫描）；
  - 坑 49：publisher/auth=上游 Kavita Team，control Maintainer=打包者。

## 10. 已定决策要点索引

详见 `docs/DESIGN_DECISIONS.md`：D-001 External Open、D-002 前缀保留+BaseUrl、
D-003 CWD+config 符号链接、D-004 端口 8500、D-005 appsettings-init 首装链、
D-006 无 env 覆盖、D-007 sha256 锚点机制、D-008 23 语超集。

## 11. 版本同步清单（一次用户可见改动必须全部更新）

1. `config.env`：KAVITA_VERSION / PKG_RELEASE（完整版本 = 上游-迭代）
2. `assets/config.ini.in`：由 build 渲染 @@VERSION@@（无需手改）
3. `assets/control.in`：同上（@VERSION@）
4. `assets/kavita.lang`：同上（@@VERSION@@；release_note 里的版本号**要手改**）
5. `docs/CHANGELOG.md`：新版本条目
6. `docs/TASK_STATE.md`：快照更新
7. Release tag = `v<完整版本>`，资产名不带版本（`kavita_x86_64.deb` + `.sha256`）
