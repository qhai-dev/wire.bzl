# Wire 工具链设计：从 go.mod 依赖构建 `wire` 可执行文件

| 状态 | 设计日期 | 目标版本 |
| --- | --- | --- |
| Draft，等待评审 | 2026-11-04 | `v0.1.0` |

## 背景与问题

Google Wire **官方不发布预编译二进制**。仓库 [google/wire](https://github.com/google/wire)
只提供 Go 源码，历史上的安装方式是：

```bash
go install github.com/google/wire/cmd/wire@latest
```

这对 Bazel 集成来说是不可接受的：

1. `@latest` 不可复现，违反 hermetic 构建原则
2. 依赖网络访问和用户的 module cache
3. 与项目锁定的 Wire 版本可能不一致（生成器版本 ≠ 运行时库版本）
4. 无法参与 Bazel 的远程缓存和 action 图

**核心结论：`wire` 可执行文件必须由项目自己的构建系统从 Go module 源码编译出来，
且编译所用的源码版本必须与项目 `go.mod` 中锁定的 `github.com/google/wire` 版本一致。**

本项目 `go.mod` 已经具备这个条件：

```
require github.com/google/wire v0.7.0
tool github.com/google/wire/cmd/wire
```

`tool` 指令（Go 1.24+）把 `cmd/wire` 显式登记为项目工具依赖，使其版本被
`go.mod` / `go.sum` 锁定，不会被 `go mod tidy` 移除。这与 Bazel 侧的版本锁定
形成同一个事实来源。

---

## 一、源码获取链路

Bazel 侧不需要自己下载 Wire 源码，而是复用 Gazelle 的 `go_deps` 扩展：

```text
go.mod / go.sum（版本锁定的唯一来源）
    ↓  go_deps.from_file(go_mod = "//:go.mod")
下载 Go module zip（Bazel repository phase，非 action phase）
    ↓
生成外部仓库 @com_github_google_wire（含自动生成的 BUILD.bazel）
    ↓  rules_go 编译
@com_github_google_wire//cmd/wire  →  wire 可执行文件
    ↓  wire_gen action 的 exec 工具
执行 wire gen，产出 wire_gen.go
```

关键分工：

| 阶段 | 职责 | 是否访问网络 |
| --- | --- | --- |
| Repository phase（`go_deps`） | 下载 module 源码、生成 BUILD 元数据 | 是（一次性，进 Bazel repository cache） |
| Analysis phase | 解析工具链、构建 action 图 | 否 |
| Execution phase（`wire_gen` action） | 运行已编译的 `wire`，生成代码 | **否**（必须 `GOPROXY=off`） |

这符合 Bazel 的一贯设计：源码下载属于 repository rule，build action 只看到
已存在的声明输入。`wire_gen` 的 action 内部绝不允许触发下载。

### 为什么不用 `http_archive`

| 问题 | 说明 |
| --- | --- |
| 上游无 BUILD 文件 | Wire 仓库没有根级或 `cmd/wire` 的 `BUILD.bazel` |
| 传递依赖需要手工补齐 | `cmd/wire` 依赖 `x/tools`、`subcommands`、`go-difflib` 等 |
| 版本双轨 | `http_archive` 的版本与 `go.mod` 锁定的版本可能漂移 |
| 重复实现 module 解析 | 等于把 `go_deps` 的逻辑重写一遍 |

`go_deps` / `go_repository` 是 Bazel Go 生态处理"只有 Go 源码、没有 BUILD 文件"
仓库的标准入口，且天然与 `go.mod` 版本对齐。

### 仓库名映射

`go_deps` 按 Gazelle 约定把 module path 转成仓库名：

```text
github.com/google/wire  →  com_github_google_wire
```

因此工具目标是 `@com_github_google_wire//cmd/wire`。

**注意：** 仓库名由 `go_deps` 生成规则决定，不是 Wire 项目自己控制的。
若未来 Gazelle 改变命名约定，或用户使用了自定义 `repo_name`，硬编码的默认值
会失效。这是引入工具链抽象的主要动机之一（见第三节）。

必须在 `MODULE.bazel` 中显式 `use_repo`，否则仓库对当前模块不可见：

```starlark
use_repo(go_deps, "com_github_google_wire")
```

---

## 二、当前实现的问题

现状是 `wire_gen` 规则上有一个 `wire_tool` 属性，默认值硬编码：

```starlark
_DEFAULT_WIRE_TOOL = Label("@com_github_google_wire//cmd/wire")
```

| 问题 | 影响 |
| --- | --- |
| 默认值硬编码仓库名 | 用户若用自定义 `repo_name`，默认值直接失效 |
| 每个 target 都要能覆盖 | 多入口项目（`cmd/api`、`cmd/worker`…）需逐个写 `wire_tool` |
| 无平台感知 | 交叉编译场景下无法按 exec platform 选择工具 |
| 无组织级管控 | 无法在 monorepo 根统一锁定 Wire 版本 |
| 错误信息差 | 仓库不存在时报"label not found"，不指向真实原因 |

---

## 三、工具链设计方案

采用 Bazel 标准的 **toolchain type + toolchain rule + toolchain resolution** 三段式。

### 3.1 组件划分

```text
wire/BUILD.bazel
    └── toolchain_type(name = "wire_toolchain_type")     ← 抽象标识

wire/toolchain.bzl
    └── wire_toolchain rule                              ← 包装具体 wire 二进制
        provides: platform_common.ToolchainInfo(wire = <executable>)

用户仓库（或本仓库提供默认）
    └── toolchain(
            name = "wire_toolchain",
            toolchain_type = "@wire.bzl//wire:wire_toolchain_type",
            exec_compatible_with = [...],
            toolchain = ":wire_toolchain_impl",
        )

wire_gen rule
    └── toolchains = ["@wire.bzl//wire:wire_toolchain_type"]
        ctx.toolchains[...].wire  ← 解析得到可执行文件
```

### 3.2 `wire_toolchain` rule

```starlark
# wire/toolchain.bzl

def _wire_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        wire = ctx.executable.wire,
        wire_files = ctx.attr.wire[DefaultInfo].files,
    )]

wire_toolchain = rule(
    implementation = _wire_toolchain_impl,
    attrs = {
        "wire": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "`github.com/google/wire/cmd/wire` 的编译目标，" +
                  "通常由 go_deps 提供源码、rules_go 编译。",
        ),
    },
    doc = "包装一个 Wire 可执行文件，供 wire_gen 通过工具链解析获取。",
)
```

**`cfg = "exec"` 是关键**：Wire 是构建期工具，必须按执行平台编译，
而不是按目标平台。否则交叉编译（如 Linux 构建 → darwin/arm64 产物）时
会尝试运行一个目标平台的二进制而失败。

### 3.3 工具链注册

```starlark
# 用户仓库 BUILD.bazel
load("@wire.bzl//wire:toolchain.bzl", "wire_toolchain")

wire_toolchain(
    name = "wire_toolchain_impl",
    wire = "@com_github_google_wire//cmd/wire",
)

toolchain(
    name = "wire_toolchain",
    toolchain = ":wire_toolchain_impl",
    toolchain_type = "@wire.bzl//wire:wire_toolchain_type",
)
```

### 3.4 Module extension（推荐入口）

为降低用户配置成本，提供 module extension 自动生成注册仓库：

```starlark
# wire/extensions.bzl

def _wire_ext_impl(module_ctx):
    registrations = []
    for mod in module_ctx.modules:
        for tc in mod.tags.toolchain:
            # 生成一个包含 wire_toolchain + toolchain 的仓库
            ...
    ...

wire = module_extension(
    implementation = _wire_ext_impl,
    tag_classes = {
        "toolchain": tag_class(attrs = {
            "wire": attr.label(mandatory = True),
            "name": attr.string(default = "wire"),
            "exec_compatible_with": attr.label_list(default = []),
        }),
    },
)
```

用户配置简化为：

```starlark
# MODULE.bazel
wire = use_extension("@wire.bzl//wire:extensions.bzl", "wire")
wire.toolchain(wire = "@com_github_google_wire//cmd/wire")
use_repo(wire, "wire_bzl_toolchains")
register_toolchains("@wire_bzl_toolchains//:all")
```

### 3.5 `wire_gen` 侧的解析与降级

工具链解析失败时的行为必须明确。设计三级降级：

```text
1. ctx.toolchains[wire_toolchain_type] 解析成功
   → 使用该工具链的 wire

2. 未注册任何工具链，但 wire_tool 属性被显式设置
   → 使用 wire_tool（兼容路径，标记 deprecated）

3. 两者都不可用
   → analysis 阶段失败，错误信息包含：
     - 缺失的 toolchain type label
     - 完整的 MODULE.bazel 注册示例
     - 提示检查 use_repo(go_deps, "com_github_google_wire") 是否遗漏
```

保留 `wire_tool` 属性作为逃生舱：用于临时替换成本地 patch 过的 Wire
（例如调试生成器行为），但不作为主路径。

### 3.6 多版本共存

同一构建图中出现多个不兼容 Wire 版本时（monorepo 中不同子项目锁定不同版本）：

- 通过标准 Bazel toolchain resolution 按 `exec_compatible_with` /
  `target_compatible_with` 选择一个版本
- **不提供"最后注册者获胜"的隐式行为**
- 生成产物内容依赖 Wire 版本，因此远程缓存键必须包含 wire 可执行文件的
  action key（Bazel 自动覆盖，因为它是 action 的 tool 输入）

---

## 四、版本一致性保障

生成器版本与运行时库版本必须匹配，否则可能出现"生成代码引用了运行时库中
不存在的 API"。

| 保障手段 | 说明 |
| --- | --- |
| 单一 `go.mod` 来源 | `wire` 工具和 `github.com/google/wire` 库来自同一 module 版本 |
| `tool` 指令锁定 | `tool github.com/google/wire/cmd/wire` 防止 tidy 移除 |
| `go.sum` 校验 | module zip 完整性由 `go.sum` 保证 |
| 禁止 `@latest` | `go_deps.module(version = ...)` 只接受精确 Go module 版本 |

用户若尚未在 `go.mod` 中依赖 Wire，需显式声明：

```starlark
go_deps.module(
    module = "github.com/google/wire",
    version = "v0.7.0",
)
```

版本必须是精确的 Go module 版本，不接受 `latest` 或分支名。

---

## 五、备选方案对比

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| `go install ...@latest` 后引用宿主机二进制 | **不采用** | 不可复现、依赖网络和宿主机状态、无法远程缓存 |
| `http_archive` 下载 Wire 源码 + 手写 BUILD | **不采用** | 上游无 BUILD 文件，需手工补齐全部传递依赖，版本与 go.mod 双轨 |
| `go run github.com/google/wire/cmd/wire` | **不采用** | 等价于运行期解析，破坏 action 的声明式输入 |
| 在 Bazel 中重写 Wire 生成器 | **不采用** | 与官方算法漂移，维护成本极高 |
| 要求用户提交 `wire_gen.go` | **不作为主流程** | 容易过期，无法保证源码与生成结果一致 |
| `go_deps` 提供源码 + `rules_go` 编译 + toolchain 注册 | **采用** | 复用 Bazel Go 生态标准链路，版本由 go.mod 单一来源锁定 |
| rules_go `go_tool` 规则 | **不存在，已实测排除** | rules_go 0.65.0 未导出该符号，详见第六节 |
| `bazel run @rules_go//go -- tool wire` | **不作为 action 路径** | 实测会在运行期联网下载 module，非 hermetic，详见第六节 |

---

## 六、实测验证记录（2026-11-04）

为确认"go.mod 工具依赖如何变成 Bazel 可执行目标"，搭建最小工程实测。
环境：Bazel 9.2.0、rules_go 0.65.0、gazelle 2.0.0-beta.2、Go SDK 1.27.3，
`go.mod` 沿用本仓库锁定内容（`github.com/google/wire v0.7.0` + `tool` 指令）。

### 6.1 结论一：rules_go 0.65.0 没有 `go_tool` 规则

在 Bazel 实际下载的 rules_go 源码中检索：

```text
go/def.bzl 导出的 tool 相关符号仅有：
    go_toolchain        (//go/private:go_toolchain.bzl)
    go_tool_library     (go_tool_library)

全仓 grep "go_tool"（排除 go_toolchain / go_tool_library）：0 命中
```

**`go_tool` 不存在。** 之前文档中标注的"待评估"现已排除，不再作为候选方案。

### 6.2 结论二：真正的机制是 gazelle `go_deps` 解析 `tool` 指令

gazelle `internal/bzlmod/go_deps.bzl` 中确实实现了 go.mod `tool` 指令支持：

```python
# 解析 go.mod JSON 的 Tool 字段
tool_importpaths = [tool["Path"] for tool in go_mod_json.get("Tool") or []]

# 建立 tool import path → Bazel label 的映射
tool_targets, direct_deps, direct_dev_deps = _index_tool_targets(...)
```

其源码注释明确说明了用途与调用方式：

> A tool target is declared with a `tool` directive in a go.mod file from the
> root Bazel module. These targets may be run with
> `bazel run @rules_go//go -- tool <name>` where `<name>` is the last component
> of the tool's import path, ignoring major version suffixes.
> We build a map to write to `@bazel_gazelle_go_repository_config` so that
> `@rules_go//go` knows which target to run.

### 6.3 结论三：label 生成规则（已按源码确认）

`_index_tool_targets` 的 label 拼装逻辑：

| 组成部分 | 取值规则 | 对 wire 的实际取值 |
| --- | --- | --- |
| repo | go_deps 仓库名（`github.com/google/wire` → `com_github_google_wire`） | `@com_github_google_wire` |
| package | module path 之后的子目录 | `cmd/wire` |
| target name | **import path 的 basename**（即使 basename 与目录同名） | `wire` |

因此 `tool github.com/google/wire/cmd/wire` 对应的 label 是：

```text
@com_github_google_wire//cmd/wire:wire
```

注意 target 名是 `:wire` 而非目录隐式名——两者在此处恰好等价
（`//cmd/wire` 即 `//cmd/wire:wire`），但源码显式使用 basename，
说明当 Go 包目录名与 `go_binary` 名不一致时不能依赖隐式简写。
**本项目现有实现的默认值 `Label("@com_github_google_wire//cmd/wire")` 是正确的。**

源码注释还指出一个重要细节：Gazelle 按 import path 最后一段命名 `go_binary`，
即使该段是主版本后缀（如 `v2`），而工具调用名用后缀之前的名字。

### 6.4 结论四：从 go.mod 锁定源码编译 wire 二进制 — 成功

```text
$ bazel build @com_github_google_wire//cmd/wire:wire

INFO: Analyzed target @@gazelle++go_deps+com_github_google_wire//cmd/wire:wire
      (130 packages loaded, 8566 targets configured)
Target ... up-to-date:
  bazel-bin/external/gazelle++go_deps+com_github_google_wire/cmd/wire/wire_/wire
INFO: Elapsed time: 81.855s, Critical Path: 48.70s
INFO: 43 processes: 14 internal, 29 processwrapper-sandbox.
INFO: Build completed successfully, 43 total actions
```

产物验证为可执行的 x86-64 ELF，且子命令完整：

```text
$ ./wire help
Usage: wire <flags> <subcommand> <subcommand args>
Subcommands:
	check            print any Wire errors found
	diff             output a diff between existing wire_gen.go files ...
	gen              generate the wire_gen.go file for each package
	show             describe all top-level provider sets
```

**这证明本文第一节的源码获取链路完全可行**：go.mod 锁定版本 → `go_deps` 下载
module 源码并生成 BUILD → `rules_go` 编译出 `cmd/wire`。传递依赖
（`x/tools`、`subcommands`、`go-difflib` 等）由 go_deps 自动补齐，无需手工维护。

### 6.5 结论五：`bazel run @rules_go//go -- tool wire` 非 hermetic

实测该官方 tool 运行器：

```text
$ bazel run @rules_go//go -- tool wire help
...
go: downloading github.com/google/wire v0.7.0
github.com/google/wire/cmd/wire: read .../pkg/mod/cache/download/
    github.com/google/wire/@v/v0.7.0.zip....tmp: device or resource busy
```

关键观察：它**委托给真实的 `go` 工具执行 `go tool wire`**，因而在运行期
从 module proxy 下载源码，而不是复用 Bazel 已编译的产物。

（本次失败原因是环境特定的：GOMODCACHE 落在不支持该操作的 OSS 挂载上。
但失败本身恰好暴露了该路径的运行期下载行为。）

**设计结论：** `bazel run @rules_go//go -- tool wire` 只适合作为开发者
本地便利命令，**不能用于 `wire_gen` 的 build action**——它违反 hermetic、
可远程缓存、构建期零网络三条硬性要求。`wire_gen` 必须直接依赖
`@com_github_google_wire//cmd/wire:wire` 这个由 rules_go 编译的目标。

### 6.6 对设计的影响

| 设计条目 | 实测后的调整 |
| --- | --- |
| 第三节 toolchain 三段式 | **保持不变**，方案成立 |
| `wire_tool` 默认值 | 确认为 `@com_github_google_wire//cmd/wire:wire`（现有默认值正确） |
| `go_tool` 作为底层实现 | **移除该候选**，rules_go 无此规则 |
| 官方 tool 运行器 | 在文档中明确定位为"开发者便利命令"，禁止用于 action |
| 第七节验收标准第 1 条 | 增加：action 内不得出现 `go tool` / `go run` 调用路径 |

---

## 七、验收标准

工具链方案落地后，必须满足：

1. **零网络构建**：`bazel build` 在 `--sandbox_default_allow_network=false`
   下成功完成 Wire 生成
2. **版本一致性**：`wire` 工具与 `github.com/google/wire` 运行时库来自
   `go.mod` 中的同一版本；可通过 `bazel query` 验证两者指向同一外部仓库
3. **交叉编译可用**：`--platforms=//platforms:darwin_arm64` 构建 Linux
   宿主机上的产物时，`wire` 仍按 exec platform（Linux）编译执行
4. **远程缓存命中**：第二次构建 action 全部 cache hit；修改 `go.mod` 中
   Wire 版本必须使缓存失效
5. **错误可定位**：未注册工具链时，报错信息直接给出可复制的 `MODULE.bazel`
   注册片段，而非底层 label 解析错误
6. **多版本可控**：同一构建图中注册两个 Wire 版本时，resolution 结果确定
   且可解释，不出现静默的"最后注册者获胜"

---

## 八、待评审决策

1. 是否接受 toolchain type + module extension 作为主路径，`wire_tool` 降级为
   deprecated 逃生舱？
2. ~~是否由本仓库提供一个"默认工具链"？~~ **已决策：提供默认工具链。**
   本仓库内置默认工具链指向 `@com_github_google_wire//cmd/wire:wire`，
   用户零配置即可使用；需要换版本或自定义仓库名时再显式注册覆盖。
3. ~~是否先实测 rules_go `go_tool`，若可用则以其作为默认实现底层？~~
   **已实测关闭**：rules_go 0.65.0 无 `go_tool` 规则；官方 `tool` 运行器非
   hermetic。二者均不纳入实现，详见第六节。
4. 多版本共存是否需要在 `v0.1.0` 支持，还是仅保证"单版本 + 明确报错"？
5. `wire` 工具编译失败（例如 Wire 版本与项目 Go SDK 不兼容）时，错误信息
   是否需要额外包装，还是直接透传 rules_go 的编译错误？

---

## 九、实现状态（2026-11-12，已实测）

工具链已实现并在 Bazel 9.2.0 + rules_go 0.65.0 + gazelle 2.0.0-beta.2 上实测通过。

### 9.1 落地文件

| 文件 | 职责 |
| --- | --- |
| `wire/toolchain.bzl` | `wire_toolchain` rule，提供 `ToolchainInfo(wire, wire_files)`，`wire` 属性为 `cfg = "exec"` |
| `wire/BUILD.bazel` | `wire_toolchain_type` + 内置默认工具链 `default_wire_toolchain` |
| `wire/extensions.bzl` | module extension，供显式注册覆盖默认工具链 |
| `wire/defs.bzl` | 公共入口，导出 `wire_gen` / `wire_toolchain`（`wire` 保留为兼容别名） |
| `wire/wire.bzl` | 接入三级解析：工具链 → `wire_tool` 逃生舱 → 可操作报错 |
| `MODULE.bazel` | `register_toolchains("//wire:default_wire_toolchain")` |
| `BUILD.bazel` | 修掉原有语法错误（缺逗号、不存在的 `@bazel_gowire` load），否则 `//:go.mod` 无法加载会阻塞整个构建 |

### 9.2 关键实现细节

**可选工具链类型。** 用 `config_common.toolchain_type(..., mandatory = False)`
声明，这样未注册时由我们自己给出可操作报错，而不是 Bazel 的通用
"no matching toolchain found"；同时保证 `wire_tool` 逃生舱仍可用。

**`wire_tool` 默认值改为 `None`。** 原实现默认值硬编码，导致无法区分
"用户显式设置"与"沿用默认"，三级解析无法成立。

**extension 中的 canonical label。** 生成的仓库看不到其他模块的 apparent name，
因此：`str(Label("//wire:toolchain.bzl"))` 在本文件所属模块求值，得到 canonical
label；tag 的 `attr.label` 值由 Bazel 在声明该 tag 的模块上下文中解析，
`str(tag.wire)` 已自带 canonical 仓库名。实测生成结果：

```starlark
load("@@wire.bzl+//wire:toolchain.bzl", "wire_toolchain")

wire_toolchain(
    name = "tc_00_wire_impl",
    wire = "@@gazelle++go_deps+com_github_google_wire//cmd/wire:wire",
)

toolchain(
    name = "tc_00_wire",
    toolchain = ":tc_00_wire_impl",
    toolchain_type = "@@wire.bzl+//wire:wire_toolchain_type",
)
```

**注册顺序。** Bazel 按注册顺序解析工具链，且 `:all` 按字典序展开。
extension 把根模块的注册排在前面，并用零填充索引前缀（`tc_00_`、`tc_01_`）
让展开顺序与优先级一致，避免"最后注册者获胜"的隐式行为。

### 9.3 实测结果

| 场景 | 结果 |
| --- | --- |
| 零配置（消费方不写任何 `register_toolchains`） | 通过。`wire_gen` → `go_library` → `go_binary` 全链路构建成功，产物运行输出 `hello toolchain` |
| 生成产物正确性 | 通过。`wire_gen.go` 带 `//go:build !wireinject`，注入器实现正确 |
| 显式注册覆盖（移除内置默认，仅留用户注册） | 通过。构建成功，证明 extension 注册路径可独立工作 |
| 两者均未注册 | 通过。给出本文 3.5 节设计的可操作报错，含可复制的 `MODULE.bazel` 片段 |

### 9.4 实测中发现并修复的两个 Starlark 陷阱

| 问题 | 现象 | 修正 |
| --- | --- | --- |
| Starlark list 无 `.sort()` | `'list' value has no field or method 'sort'` | 改用 `sorted(entries, key = ...)` |
| Starlark `format()` 不支持宽度/补零说明符 | `Error in format: Missing argument ':02d'` | 手工补零后字符串拼接 |

### 9.5 尚未实现（后续阶段）

- 交叉编译实测（`cfg = "exec"` 已按设计声明，但未在跨平台 target 上实跑验证）
- GOPATH → Module 模式迁移
- Gazelle 语言扩展

> `wire_gen` 规则本体重构（移除 `out`、import path 报错）与 E2E 接入已于
> 2026-11-12 完成并实测，详见 `design-review-and-improvements.md` 第八节。

---

内容由 AI 生成
