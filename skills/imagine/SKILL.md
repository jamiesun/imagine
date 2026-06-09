---
name: imagine
description: 使用 imagine CLI 调用多种图像生成模型 API（首批 Azure gpt-image-1.5 / gpt-image-2 / FLUX.2-pro）。用于文生图、批量生成、按模型名路由后端、同模型多端点并发生成，以及通过 --json 让 agent 解析结果。检测 imagine 二进制是否安装，未安装时引导用户一键安装。
---

# imagine — 通用图像生成 CLI 技能

`imagine` 是一个面向 AI agent 的通用图像生成命令行工具：统一前端参数，按**模型名**路由到不同后端，
同一模型可配置多个端点（URL+KEY）做并发调度。输出单一静态二进制，不依赖 curl/jq/base64。

## 何时使用本技能

- 文生图：给定 prompt 生成一张或多张图片并落盘。
- 批量生成：从 JSON manifest 一次跑多个任务（不同模型/尺寸/数量）。
- 需要 agent 解析结果：用 `--json` 得到结构化输出。
- 查看 / 初始化配置，或排查"模型未配置 / 缺 key"。

支持的模型由 `~/.imagine/config.json` 决定；首批内置模板含 `gpt-image-1.5`、`gpt-image-2`、`FLUX.2-pro`。

## 第 0 步（必做）：检测二进制是否安装

调用任何功能前，先确认 `imagine` 是否可用：

```bash
command -v imagine && imagine version
```

- **若命中**（打印出路径和版本）→ 直接进入"使用方法"。
- **若未命中**（command not found）→ **不要**直接尝试生成。先告知用户尚未安装，
  并征求同意后协助安装（见下）。

### 引导安装（需用户批准后再执行）

向用户说明将要做什么（安装二进制到 `~/.local/bin`，安装技能到 `~/.agents/skills/imagine`），
征得同意后选其一：

```bash
# 方式 A：一键安装（推荐，自动判断系统类型，缺二进制时用 Zig 从源码构建）
curl -fsSL https://raw.githubusercontent.com/terateams/imagine/main/install.sh | sh

# 方式 B：在源码仓库内开发安装
make install
```

安装后让用户确认 PATH 包含 `~/.local/bin`（脚本会在缺失时提示）。
再次 `imagine version` 验证成功。

> 从源码构建需要 Zig ≥ 0.16.0。若用户机器没有 Zig，提示其安装（macOS: `brew install zig`，
> 或 https://ziglang.org/download/），或等待预编译 release。

## 第 1 步：配置

默认配置路径 `~/.imagine/config.json`，可用 `$IMAGINE_CONFIG` 或 `--config <path>` 覆盖。

```bash
imagine config path          # 打印解析后的配置路径
imagine config init          # 写入起始模板（含 3 个 Azure 模型）；--force 覆盖
imagine config show          # 打印生效配置（key 自动脱敏）
imagine models               # 列出已配置模型及就绪状态
imagine models --json        # 机器可读
```

密钥来源（优先级从高到低）：端点 `api_key` 字面值 > 端点 `api_key_env` 指向的环境变量。
模板默认从 `AZURE_API_KEY` 读取：

```bash
export AZURE_API_KEY="your-azure-key"
```

**同模型多端点并发**：在某个模型的 `endpoints` 数组里配置多个 `{base_url, api_key_env}`，
imagine 会在生成多张图时把请求并发分摊到各端点（绕过单端点限流）。

## 第 2 步：生成

```bash
# 单张（gpt-image-1.5）
imagine generate -m gpt-image-1.5 -p "A photograph of a red fox in an autumn forest" -o fox.png

# FLUX（用 width/height）
imagine generate -m FLUX.2-pro -p "a city at dusk" --width 1024 --height 1024 -o city.png

# 多张 + 并发（文件名自动加 -1 -2 …）
imagine generate -m gpt-image-2 -p "logo concept" -n 4 -o logo.png -c 4

# 只看请求体、不真正调用（排查参数）
imagine generate -m gpt-image-1.5 -p "test" --dry-run

# 结构化输出供 agent 解析
imagine generate -m gpt-image-1.5 -p "a red fox" -o fox.png --json
```

常用选项：

| 选项 | 说明 |
|------|------|
| `-m, --model` | 模型名（必填，路由后端） |
| `-p, --prompt` | 提示词（必填，也可作位置参数） |
| `-o, --output` | 输出文件（单张）或文件名前缀（多张） |
| `-n, --n` | 生成数量（默认 1） |
| `-s, --size` | 尺寸（gpt-image 系，见下方"模型尺寸支持"） |
| `--width / --height` | 宽高（FLUX 系，替代 `--size`） |
| `--format` | `png` / `jpeg`（gpt-image 系；不支持 webp） |
| `--compression` | `0-100`（gpt-image 系） |
| `--quality` | `low` / `medium` / `high` / `auto`（gpt-image 系） |
| `--seed` | 随机种子（部分模型） |
| `-c, --concurrency` | 并发请求数（默认=端点数） |
| `--config` | 指定配置文件 |
| `--json` | 输出 JSON 结果对象 |
| `--dry-run` | 只打印请求体 |
| `-q, --quiet` | 静默进度 |

### 模型尺寸支持（Azure，已对端点实测）

| 模型 | 尺寸约束 |
|------|----------|
| `gpt-image-1.5` | `--size` 仅限 `1024x1024`、`1536x1024`（横）、`1024x1536`（竖）、`auto` |
| `gpt-image-2` | `--size` 任意 `宽x高`，但宽高都须为 **16 的倍数**，最长边 ≤ **3840**（还有最小像素下限） |
| `FLUX.2-pro` | 用 `--width/--height`，每边 ≥ **64**，且 `宽×高 ≤ 4 MP`（即 ≤ `2048x2048`），无 16 整除要求 |

> 传入不支持的尺寸时，API 会返回明确的错误信息（例如 `Supported sizes are 1024x1024, 1024x1536, 1536x1024, and auto.`）。先 `--dry-run` 或读 `--json` 的 `errors[]` 可快速定位。

## 第 3 步：批量（manifest）

```bash
imagine batch jobs.json -c 4
```

`jobs.json` 格式：

```json
{
  "jobs": [
    { "model": "gpt-image-1.5", "prompt": "a fox",  "output": "out/fox.png" },
    { "model": "FLUX.2-pro",    "prompt": "a city", "output": "out/city.png", "width": 1024, "height": 1024, "n": 2 },
    { "model": "gpt-image-2",   "prompt": "a tree", "output": "out/tree.png", "size": "512x512" }
  ]
}
```

每个 job 支持：`model, prompt, output, size, width, height, n, format, compression, quality, seed`。

## agent 集成约定

- **退出码**：`0` 成功；`1` 运行失败（含部分失败）；`2` 用法错误。据此判断是否需重试/上报。
- **`--json` 结果对象**：
  ```json
  { "ok": true, "model": "...", "backend": "azure_image",
    "requested": 1, "succeeded": 1, "failed": 0,
    "images": [ { "path": "fox.png", "bytes": 12345 } ], "errors": [] }
  ```
  解析 `images[].path` 拿到落盘文件；`ok=false` 时读 `errors[]`。
- 先 `imagine models --json` 确认目标模型 `ready=true`（key 已就绪）再生成。
- 不确定参数时先 `--dry-run` 校验请求体。

## 环境变量

| 变量 | 作用 |
|------|------|
| `IMAGINE_CONFIG` | 覆盖配置文件路径（默认 `~/.imagine/config.json`） |
| `AZURE_API_KEY` | 模板默认的 Azure 密钥来源（可在配置中改 `api_key_env`） |

## 排错

- `model 'X' not found` → 跑 `imagine models` 看已配置模型，或 `imagine config init` 写模板。
- `missing credential` → 设置对应环境变量（默认 `AZURE_API_KEY`）或在端点写 `api_key`。
- `HTTP 4xx/5xx` → 错误信息来自上游 API（内容策略、配额、鉴权等），按提示处理。
- 生成慢 / 限流 → 给模型配多个 `endpoints` 并加大 `-c`。
