# Trellis HUD

> 面向 **macOS 14+ (Sonoma)** 的纯 **Swift 6 + AppKit + SwiftUI** 原生桌面控制中心，围绕现代 Trellis 的完整四维工作流（`task` + `spec` + `channel` + `mem`）打造，零外部远程依赖、极低内存与冷启动开销。

---

## 核心定位

终端擅长线性执行，但在多 Agent 并行、规范门禁与跨会话记忆检索上天然存在认知盲区。**Trellis HUD** 不是静态任务贴纸，而是常驻屏幕边缘的**空间化控制面**：

- **双态环境感知（Dual Ambient Modes）**：支持 **True Notch HUD**（贴合刘海屏黑区）与 **Edge-Docked Floating Pill**（贴靠屏幕左/右/左下/右下边缘的悬浮胶囊），按 **`⌘⇧M`** 实时热切换。
- **非抢占焦点面板（Non-Activating `NSPanel`）**：悬停或点击即可展开工作台，不会打断当前 IDE 或终端焦点；按 **`⌘⇧T`** 随时唤出 / 收起工作台，**`Esc`** 快速折叠。
- **原生 macOS 视觉体系**：采用系统 `.ultraThinMaterial` 毛玻璃与自动适配明暗模式（Light/Dark Vibrancy），无冗余花哨皮肤与伪造进度条。

---

## 四大工作台视图（4-Tab Workbench）

| Tab | 定位 | 核心能力 |
| --- | --- | --- |
| **1. Flow** | 真实任务执行与门禁驾驶舱 | 5 阶段工作流管线（`Explore → Plan → Implement → Check → Archive`）；直接解析 `implement.md` / `prd.md` 中的真实 Markdown `- [x]` / `- [ ]` 进度；Git 脏文件与 `.trellis/spec/` `paths:` glob 覆盖率治理；时间序工具调用轨迹（保留真实文件与命令）；安全人工门禁操作栏（`Jump to Terminal` / `Validate` / `Start` / `Archive`，内置 `--no-commit --skip-branch-validation` 兼容回退）。 |
| **2. Live** | 多 Agent 注意力收件箱 & Channel 监控 | 跨项目/多 Worktree 汇总所有活跃 Agent 会话，将 **`Waiting on You`**（权限审批 / 提问阻塞）与 **`Failed`** 置顶并支持一键跳转终端；直接解析 `~/.trellis/channels/**/events.jsonl`，实时监控 `trellis channel` 中的 Worker 生命周期（`running` / `idle` / `mid-turn` / `error`）、Threads 与消息流。 |
| **3. Docs & Specs** | 任务文档 & 3 级 Monorepo 规范浏览器 | 原生 SwiftUI GFM 渲染器（支持 H2 折叠、代码块一键复制、表格与任务清单），快速切换 `PRD` / `Design` / `Implement` / `Research`；递归扫描 2 级与 3 级 Monorepo `.trellis/spec/<package>/<layer>/*.md`，标识空模板健康状态、引用次数与命中当前修改文件的规范数。 |
| **4. History** | 跨平台项目记忆检索 | 统一搜索栏与来源筛选，聚合 **Archived Tasks**（按年月分组）、`.trellis/workspace/<dev>/journal-*.md` 个人工作日志，以及 **`trellis mem`** 跨平台历史会话（支持 Antigravity、Claude Code、Codex、Pi、OpenCode、Grok、Devin、ZCode）。 |

---

## 协议兼容与 Hook 架构

Trellis HUD 与既有 **Trellis Card** 生态保持配置与线协议完全兼容，无需重新配置即可平滑切换：

- **配置与队列兼容**：直接复用 macOS 默认配置目录 `~/Library/Application Support/trellis-card/config.json`（若不存在则回退读取 `~/.config/trellis-card/config.json`），新 HUD 偏好字段带默认值向下兼容。
- **Unix Domain Socket + 原子队列**：沿用一致的 FNV-1a 64-bit Socket 路径（`/tmp/trellis-card-<fnv1a>.sock`）与 `inbox/` 原子 JSON 兜底队列。
- **独立轻量 CLI（`trellis-card-hook`）**：零 AppKit / SwiftUI 依赖，冷启动 **< 10ms**，支持 `hook`、`install-hooks`、`status` 子命令。
- **全平台 Agent 观察支持**：内置 7 个平台的一键 Hook/桥接安装与卸载：
  - **Claude Code**（`~/.claude/settings.json`）
  - **Codex**（`~/.codex/hooks.json` + `~/.codex/config.toml`）
  - **Cursor**（`~/.cursor/hooks.json`）
  - **Pi**（`~/.pi/agent/extensions/trellis-card.ts`）
  - **OpenCode**（`~/.config/opencode/plugins/trellis-card.js`）
  - **DeepSeek Harness / DSH**（`dsh-trellis-bridge`）
  - **Antigravity**（`~/.agents/hooks.json`）

---

## 构建、测试与打包

### 要求
- macOS 14.0+ (Apple Silicon / Intel)
- Swift 6.0+（Xcode 或 Apple Command Line Tools）

### 1. 构建并运行测试
```bash
./scripts/build-and-test.sh
```
脚本优先调用 `swift test`；若检测到宿主机 CLT 的 `PackageDescription` manifest 链接问题，会自动回退至 `swiftc -swift-version 6` 直接编译全部目标与测试套件。

### 2. 打包为 macOS `.app`
```bash
./scripts/bundle-app.sh
```
构建产物位于 `build/TrellisHUD.app`，自动组装：
- `Contents/MacOS/TrellisHUD`（主程序）
- `Contents/Helpers/trellis-card-hook`（独立 Hook CLI）
- `Contents/Resources/{AppIcon.icns,templates/}` 与 `Contents/Info.plist`
- 自动执行 ad-hoc 签名（`codesign --force --deep --sign -`）

启动应用：
```bash
open build/TrellisHUD.app
```

### 3. CLI 常用命令
```bash
# 查看各 Agent Hook 安装状态与 Socket/Inbox 路径
./build/TrellisHUD.app/Contents/Helpers/trellis-card-hook status

# 一键安装指定或全部 Agent 的观察 Hook
./build/TrellisHUD.app/Contents/Helpers/trellis-card-hook install-hooks --agent claude
./build/TrellisHUD.app/Contents/Helpers/trellis-card-hook install-hooks --agent antigravity
./build/TrellisHUD.app/Contents/Helpers/trellis-card-hook install-hooks --agent all
```

### 故障排查：宿主机 `swift build` 报 `PackageDescription` 链接错误
部分从旧版升级而来的 macOS Command Line Tools 会在 `/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/` 残留旧版 `.private.swiftinterface` 文件，导致所有 `swift build` / `swift test` 在 manifest 阶段报 `Undefined symbols: Package.__allocating_init(..., swiftLanguageVersions: [SwiftVersion]?)`。

- **临时方案**：直接使用仓库自带的 `./scripts/build-and-test.sh` 与 `./scripts/bundle-app.sh`（内置自动回退，开箱即用）。
- **彻底修复**（需管理员权限）：
  ```bash
  sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface
  ```
  或重新安装 Command Line Tools（`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`）。

---

## 目录结构

```text
trellis-hud/
├── Package.swift
├── Resources/                  # Info.plist, AppIcon.icns, Agent bridge templates
├── scripts/
│   ├── build-and-test.sh       # 构建与测试（支持 CLT manifest 故障自愈回退）
│   └── bundle-app.sh           # 生成并签名 build/TrellisHUD.app
├── Sources/
│   ├── TrellisCore/            # 纯 Swift 6 核心库（Models / Scanner / IPC / Runtime）
│   ├── TrellisHookCLI/         # 轻量零 UI 的 trellis-card-hook CLI
│   └── TrellisHUDApp/          # AppKit 窗口/菜单栏/快捷键 + SwiftUI 4-Tab 工作台
└── Tests/
    └── TrellisCoreTests/       # 核心单元测试
```
