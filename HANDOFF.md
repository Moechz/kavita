# Project handoff — kavita（Kavita for TOS 7）

交接日期：2026-09-17
当前版本：0.9.1.4-2（双架构产物就绪，未发布）
分支/提交：git init 后首提交（main）

## 1. 必读顺序

`AGENTS.md` → 本文件 → `docs/TASK_STATE.md` → `docs/DESIGN_DECISIONS.md` → `docs/CHANGELOG.md`

## 2. 仓库布局说明

见 `AGENTS.md` §4。构建产物在 `build/`、`out/`（git 忽略）；一切可改源在
`config.env` + `assets/` + `build.sh`。

## 3. 当前状态速览

- 首包全流程已在 tnas-57 真机验证（安装/升级/卸载/路由/回环/API/OPDS 全绿，
  详见 `docs/TASK_STATE.md` §3）；机器上保留 0.9.1.4-2 运行中。
- 待办仅剩两个 GUI 闸门：浏览器首访向导冒烟、应用中心手动安装（坑 11）。

## 4. 最重要的开放问题

见 `docs/TASK_STATE.md` §5（GUI 冒烟 / App Center sideload / arm64 真机缺）。

## 5. 发布闸门

见 `docs/TASK_STATE.md` §6（剩两项未勾）。
上架资产：`kavita_x86_64.deb` / `kavita_aarch64.deb` + `.sha256`，
Release tag = `v0.9.1.4-2`，仓库必须公开（坑 20）。

## 6. 交接清理检查

- [x] 后台下载进程已结束（x64/arm64 tarball 均完整）。
- [x] `build/downloads/` 无 .part 残留。
- [x] 本机无 Kavita 测试进程；tnas-57 上留有正式安装（属预期）。

## 7. 构建与测试快速上手

```bash
cd ~/Documents/projects/kavita
make check
./build.sh                        # amd64
TARGET_ARCH=arm64 ./build.sh      # aarch64
./build.sh distclean              # 重置全部（含下载缓存，慎用）
```

真机部署/验证命令模板见 `docs/TASK_STATE.md` §8；
打包规范总库 `~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md`。

## 8. 版本同步清单

见 `AGENTS.md` §11（config.env / config.ini / control / lang 的 release_note /
CHANGELOG / TASK_STATE / Release tag 七处）。
