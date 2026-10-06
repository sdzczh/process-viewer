# 进程查看器 (ProcessViewer)

一个 macOS 原生 SwiftUI 小工具，用来查看本机还在跑的开发类后台进程（node / python / java / go / ruby 等），按项目目录分组，显示监听端口，并可一键结束。

## 功能

- 扫描 `node / python / uv / java / go / deno / bun / ruby / npm / vite / uvicorn / gunicorn` 等解释器进程，自动排除系统应用、微信、Steam、Adobe、Qoder 自身等噪音。
- 用 `lsof` 读取每个进程的监听端口（TCP LISTEN）和工作目录（cwd）。
- 按项目根目录分组：从 cwd 向上查找 `.git / package.json / pyproject.toml / pom.xml / go.mod` 等标记文件定位项目根。
- 一键结束：`正常结束 (kill -15 / SIGTERM)` 或 `强制结束 (kill -9 / SIGKILL)`，带二次确认。
- 搜索（命令 / PID / 端口 / 项目名）、"仅显示监听端口" 过滤、5 秒自动刷新开关。
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

- 进程列表：`ps -axo pid=,ppid=,pcpu=,pmem=,command=`
- 端口：`lsof -nP -iTCP -sTCP:LISTEN -a -p <pid列表> -Fn`
- 工作目录：`lsof -a -d cwd -Fn -p <pid列表>`
- 结束：`/bin/kill -15|-9 <pid>`

应用未启用沙盒（需要调用 ps/lsof/kill），ad-hoc 签名，仅本机使用。

## 说明

- 首次运行若系统提示权限，允许即可（读取进程信息无需特殊授权，均为当前用户自己的进程）。
- 关闭窗口即退出应用（按需打开的工具，不常驻）。
