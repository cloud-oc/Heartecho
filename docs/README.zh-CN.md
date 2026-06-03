# Heartecho

[English](../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

Heartecho 是一个原生 macOS 音频路由工作台，用来创建虚拟音频设备、把应用或硬件输入映射到输出通道、监看电平，并打包真实系统集成所需的 Core Audio HAL 驱动相关组件。

产品方向参考 Rogue Amoeba Loopback 一类工具，但当前仓库仍是工程预览版本：SwiftUI 应用、路由模型、诊断、Helper 运行时、安装器脚本和 C HAL 驱动骨架已经具备；要成为可正式分发的产品，还需要 Developer ID 签名、公证以及完整的已安装驱动验证。

## 产品概览

- 原生 macOS SwiftUI/AppKit 路由图配置应用。
- 支持虚拟设备、音频源、通道映射、监听、增益、静音、预设和路由图校验的核心模型。
- 包含应用音频采集、硬件输入采集、采样率转换、监听播放、电平表和 HAL 共享内存发布的运行时脚手架。
- 包含 C HAL Audio Server Driver 骨架、Swift 桥接、bundle 生成、验证、安装、卸载和诊断脚本。
- 包含 app bundle、HAL driver bundle、Helper LaunchAgent、安装包、卸载包、distribution package 和 JSON release manifest 的发布流水线。

更深入的实现说明见 [architecture.md](architecture.md)、[feature-map.md](feature-map.md)、[hal-driver.md](hal-driver.md) 和 [implementation-plan.md](implementation-plan.md)。

## 环境要求

- macOS 14 或更新版本。
- Swift 6 工具链。
- Release 构建、签名、打包和 HAL 驱动相关工作建议使用 Xcode 16 或更新版本。部分本地 SwiftPM 开发任务可以只使用 Command Line Tools。
- 图标生成需要 Python 和 Pillow。GitHub Actions workflow 会自动创建本地虚拟环境。

## 快速开始

运行应用：

```sh
swift run Heartecho
```

运行不会修改系统的诊断：

```sh
CLANG_MODULE_CACHE_PATH=.build/clang-module-cache \
swift run --disable-sandbox HeartechoDiagnostics --skip-shared-memory
```

构建并验证本地 app bundle：

```sh
scripts/build-icons.sh
scripts/build-app-bundle.sh debug
scripts/verify-app-bundle.sh
```

本地构建 release artifacts：

```sh
scripts/build-release-artifacts.sh --configuration release
```

release artifact 命令会把安装包写入 `build/pkg/`，并把发布清单写入 `build/release-manifest.json`。

## GitHub Release 自动化

`VERSION` 是 GitHub Release 版本号的单一来源。[release.yml](../.github/workflows/release.yml) 会在推送到 `main` 和手动触发时运行。

发布 job 现在运行在 `macos-15`，并显式选择 Xcode 16.4，因此能够支持 [Package.swift](../Package.swift) 中的 Swift 6 tools version。`scripts/check-swift-toolchain.sh` 会在 runner 使用旧 Swift 工具链时提前给出清晰错误。

成功运行后，workflow 会：

1. 读取 `VERSION`。
2. 安装 Python 图标构建依赖。
3. 构建 app、HAL 驱动、安装包、卸载包、distribution package 和 manifest。
4. 如果 `v$(cat VERSION)` 不存在就创建 Release；如果已存在，就用 `--clobber` 更新 assets。

本地发布需要先完成 GitHub CLI 登录：

```sh
scripts/build-release-artifacts.sh --configuration release
scripts/publish-github-release.sh
```

## 系统集成说明

Heartecho 不能只作为普通沙盒应用就实现 Loopback 等价能力。虚拟设备需要把 Core Audio HAL Audio Server Driver 安装到系统或用户插件目录。按应用采集音频需要 macOS process taps 和用户授权的音频采集权限。硬件输入采集需要麦克风权限。

先以 dry run 方式使用安装、卸载、验证和恢复脚本：

```sh
scripts/install-heartecho.sh --wait 30
scripts/uninstall-heartecho.sh --unload-helper --reload-core-audio
scripts/validate-installation.sh --wait 30
scripts/validate-installed-audio.sh --iterations 3 --wait 30
```

只有在签名、公证、安装位置和本机系统影响都确认后，再添加 `--execute`。

## 项目结构

- `Sources/HeartechoApp`：原生配置和监听应用。
- `Sources/HeartechoCore`：产品模型、预设、持久化和路由图校验。
- `Sources/HeartechoAudio`：设备发现、采集脚手架、路由运行时、混音器、监听播放、HAL 发布和诊断辅助。
- `Sources/HeartechoHelper`：用于初始化路由图并发布 HAL 配置/音频的命令行 Helper。
- `Sources/HALDriverStub` 和 `Sources/HALDriverC`：Swift 桥接和 C HAL 驱动骨架。
- `scripts`：构建、验证、签名、公证、安装、卸载、发布和恢复自动化。
- `docs`：架构、HAL、功能和实现计划文档。

## 维护方式

把根目录 README 保持为产品入口；详细工程说明放到 `docs/`；发布逻辑保留在脚本中；当面向用户的产品行为变化时，同步更新英文、中文和日文 README。
