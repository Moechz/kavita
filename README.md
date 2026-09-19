# Kavita for TOS 7（应用中心 deb 封装）

把 [Kavita](https://github.com/Kareadita/Kavita) —— 自托管数字图书馆
（漫画 / Manga / 电子书 / 杂志，Web 阅读器 + 管理后台）—— 打包成
TerraMaster TOS 7 应用中心规范的 deb。

## 特性

- **源码自建二进制**：公开 CI 从上游源码 tag 构建 linux-x64 / linux-arm64 自包含 .NET（V6 可审计：BUILD-INFO + PROVENANCE + SHA256SUMS 双层锚定），零运行时依赖
- **新标签页打开**：TOS 桌面图标 → `http://<NAS>:8181/kavita/`（WebUI External Open）
- **仅回环监听**：`127.0.0.1:8500`，不对外暴露端口，流量走 TOS nginx 标准路由
- **原生子路径**：上游 `BaseUrl=/kavita/` + SPA base href 预写，OPDS / SignalR 全兼容
- **数据安全**：状态（数据库/封面/缓存/日志）在 `/var/lib/kavita`，`apt remove` 保留
- **沙箱运行**：专用低权用户 + systemd 加固（NoNewPrivileges / ProtectSystem=strict）
- **双架构**：amd64（x86_64）与 arm64（aarch64）

## 使用

1. TOS 桌面打开 Kavita 图标，首访向导创建管理员账号
2. Server Settings → Libraries → 添加库目录（默认 `/var/lib/kavita/library`，
   或任意 kavita 用户可读的目录，如共享文件夹）
3. 阅读类 App 通过 OPDS 订阅：`http://<NAS>:8181/kavita/opds`

## 构建

```bash
make check               # 语法 + 资产自检
./build.sh               # amd64 全流程（fetch → stage → verify → deb）
TARGET_ARCH=arm64 ./build.sh   # aarch64
```

产物：`out/kavita_<版本>_<arch>.deb`（本地测试）、`out/kavita_{x86_64,aarch64}.deb(.sha256)`（上架资产）。

## 文档

- `AGENTS.md` 项目约束与开发指南（新会话先读）
- `docs/TASK_STATE.md` 当前进度与验证状态
- `docs/DESIGN_DECISIONS.md` 已定决策台账
- 打包规范与硬坑总库：`~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md`

## 许可

Kavita 上游为 GPLv3（随包 `copyright`）。本封装脚本无额外限制。
