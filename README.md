# 进程查看器 (ProcessViewer)

一个 macOS 原生 SwiftUI 小工具，用来查看本机还在跑的开发类后台进程（node / python / java / go / ruby 等）以及任何正在监听 TCP 端口的自建进程，按项目目录分组，显示监听端口，并可一键结束。

## 功能

- 扫描 `node / python / uv / java / go / deno / bun / ruby / npm / vite / uvicorn / gunicorn` 等解释器进程，自动排除系统应用、微信、Steam、Adobe、Qoder 自身等噪音。
- **端口兜底规则**：凡是当前用户进程有 TCP LISTEN 端口的，即使不匹配任何解释器前缀（例如自己编译的独立二进制 `./copytrade-local`）也会被收进来，family 标记为 `other`。可用底栏「含其他监听进程」开关隐藏。
- 用 `lsof` 读取每个进程的监听端口（TCP LISTEN）和工作目录（cwd）。
- 按项目根目录分组：从 cwd 向上查找 `.git / package.json / pyproject.toml / pom.xml / go.mod` 等标记文件定位项目根。
- 一键结束：`正常结束 (kill -15 / SIGTERM)` 或 `强制结束 (kill -9 / SIGKILL)`，带二次确认。
- 搜索（命令 / PID / 端口 / 项目名）、"含其他监听进程" / "仅显示监听端口" 过滤、5 秒自动刷新开关。
- 右键 / 菜单可复制命令、在访达中显示 cwd。

## 构建

依赖 Xcode Command Line Tools（`xcode-select --install`）。

```bash
./build.sh          # 编译并打包成 build/ProcessViewer.app（ad-hoc 签名）
open build/ProcessViewer.app
```

安装到应用程序目录：

```bash
cp -R build/ProcessViewer.app "/Applications/进程查看器.app"
```

## 原理

- 进程列表：`ps -axo pid=,ppid=,pcpu=,pmem=,uid=,command=`（只保留 `uid == 当前用户` 且不在排除名单里的行）
- 端口：`lsof -nP -iTCP -sTCP:LISTEN -Fn`（**全机一次取回**，不按 pid 过滤，这样非解释器类的监听进程也能被发现）
- 候选集：命中解释器白名单的进程 ∪ 出现在上面端口表里的进程
- 工作目录：`lsof -a -d cwd -Fn -p <候选pid列表>`
- 结束：`/bin/kill -15|-9 <pid>`

一次完整扫描约 360 ms（全量 lsof 占大头），5 秒自动刷新无压力。

应用未启用沙盒（需要调用 ps/lsof/kill），ad-hoc 签名，仅本机使用。

## 说明

- 首次运行若系统提示权限，允许即可（读取进程信息无需特殊授权，均为当前用户自己的进程）。
- 关闭窗口即退出应用（按需打开的工具，不常驻）。
