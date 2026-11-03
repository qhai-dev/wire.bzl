# wire.bzl 设计评审与改进方案

| 状态 | 评审日期 | 基于版本 |
| --- | --- | --- |
| 评审完成，待实施 | 2026-11-03 | wire/wire.bzl 当前实现 + wire-rules-api-design.md 草案 |

本文档对 `wire/wire.bzl` 当前实现进行设计评审，识别设计问题，
并提出经过讨论确认的改进方案和改造路径。

---

## 一、核心 API 设计决策

### 1.1 设计原则：`wire_gen` 只做一件事

经过多轮讨论，确定以下设计原则：

**`wire_gen` 是一个纯粹的代码生成规则——接收输入，执行 `wire gen`，输出一个 `.go` 文件。
不创建额外目标，不包装 `go_library`，不关心下游怎么使用产物。**

这与 `protoc` 生成 `.pb.go` 的设计哲学一致：生成器只管生成，
编译和链接由用户自行组合 `go_library` / `go_binary` 完成。

### 1.2 最终 API：`wire_gen`

```starlark
load("@wire.bzl//wire:defs.bzl", "wire_gen")

wire_gen(
    name = "wire_gen",
    srcs = ["wire.go"],
    deps = ["//internal/server", "@com_github_google_wire//wire"],
    importpath = "github.com/example/app/cmd",
)

go_library(
    name = "cmd",
    srcs = ["main.go", ":wire_gen"],
    deps = ["//internal/server", "@com_github_google_wire//wire"],
    importpath = "github.com/example/app/cmd",
)

go_binary(
    name = "app",
    embed = [":cmd"],
)
```

**属性表：**

| 属性 | 类型 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `name` | Name | 是 | | 目标名 |
| `srcs` | `.go` 文件列表 | 是 | | 注入器声明文件（带 `wireinject` build tag） |
| `deps` | Go 库列表 | 否 | `[]` | 提供类型信息给 Wire 做依赖解析的传递依赖 |
| `importpath` | String | 否 | `""` | 当前包的 Go import path；空时尝试从 deps 推断 |
| `header_file` | Label | 否 | `None` | 插入到生成文件头部的文件 |
| `wire_tags` | String 列表 | 否 | `[]` | 额外的 build tags，传给 `wire gen -tags` |
| `wire_tool` | Label | 否 | Wire 默认工具 | 可选覆盖 Wire 可执行文件 |

> **输出文件名固定为 `wire_gen.go`，不可配置。** 与 Wire 官方约定一致，
> 不提供 `output` / `out` 属性。

### 1.3 多入口项目布局（`cmd/` 多子目录）

Go 项目常见 `cmd/` 下有多个启动入口（`cmd/api`、`cmd/worker`、`cmd/cli`），
每个目录都有自己的 `wire.go` 和 `wire_gen.go`。

**对 Bazel 没有影响。** 每个目录是一个独立的 Bazel package，`wire_gen` 的输出
路径自动带上 package 前缀，不会冲突：

```text
cmd/
  api/
    BUILD.bazel     → wire_gen(name="wire_gen") → cmd/api/wire_gen.go
    main.go
    wire.go
  worker/
    BUILD.bazel     → wire_gen(name="wire_gen") → cmd/worker/wire_gen.go
    main.go
    wire.go
  cli/
    BUILD.bazel     → wire_gen(name="wire_gen") → cmd/cli/wire_gen.go
    main.go
    wire.go
```

Bazel 的 action 输出路径结构为 `bazel-out/<config>/bin/<package>/<filename>`，
因此三个 `wire_gen.go` 的实际存储路径完全不同：

```text
bazel-out/k8-fastbuild/bin/cmd/api/wire_gen.go
bazel-out/k8-fastbuild/bin/cmd/worker/wire_gen.go
bazel-out/k8-fastbuild/bin/cmd/cli/wire_gen.go
```

每个 `BUILD.bazel` 示例：

```starlark
# cmd/api/BUILD.bazel
load("@rules_go//go:def.bzl", "go_binary", "go_library")
load("@wire.bzl//wire:defs.bzl", "wire_gen")

wire_gen(
    name = "wire_gen",
    srcs = ["wire.go"],
    deps = ["//internal/api/server", "@com_github_google_wire//wire"],
    importpath = "github.com/example/app/cmd/api",
)

go_library(
    name = "go_default_library",
    srcs = ["main.go", ":wire_gen"],
    deps = ["//internal/api/server", "@com_github_google_wire//wire"],
    importpath = "github.com/example/app/cmd/api",
    visibility = ["//visibility:private"],
)

go_binary(
    name = "api",
    embed = [":go_default_library"],
    visibility = ["//visibility:public"],
)
```

### 1.4 与 `deps` 重复声明的处理

`wire_gen` 和 `go_library` 需要声明相同的 `deps`，这是 Bazel Go 代码生成的常态模式
（`go_proto_library` + `go_library` 也有同样的重复）。

设计决策：**接受这种重复，通过 Gazelle 扩展自动生成来消除手工维护的负担。**

不采用以下方案：

| 备选方案 | 不采用的原因 |
| --- | --- |
| `wire_gen` 接收 `library` 参数，从 `GoArchive` 继承 | 增加概念复杂度；生成规则不应依赖已编译的 Go 库 |
| `wire_library` 高层宏包装一切 | 创建影子规则，用户困惑"该用 `go_library` 还是 `wire_library`" |
| Starlark 变量消除重复 | 仅适用于小规模项目，不解决根本问题 |

### 1.5 命名体系统一

| 符号 | 说明 |
| --- | --- |
| `wire_gen` | 唯一的公共规则，输出 `.go` 文件 |
| `_wire_gen` | 内部 rule 实现（不公开） |

清理项：
- 删除根目录 `wire.bzl` 的 re-export
- 删除 `BUILD.bazel` 中不存在的 `@bazel_gowire` load 路径
- 删除 `gowire` 命名

---

## 二、Gazelle 扩展方案

### 2.1 目标

编写 Gazelle 语言扩展，在检测到包含 `wireinject` build tag 的 Go 文件时：

1. 自动生成 `wire_gen` 规则
2. 将 `:wire_gen` 引用自动添加到同目录 `go_library` 的 `srcs` 中
3. 从 `go_library` 中移除原始 `wire.go`（避免编译冲突）

### 2.2 检测逻辑

Gazelle 扩展扫描每个 Go package 目录时：

1. 解析所有 `.go` 文件的 build constraints
2. 识别带有 `wireinject` build tag 的文件（通常是 `wire.go`）
3. 如果存在这样的文件 → 该目录需要 Wire 代码生成

### 2.3 生成规则

对于检测到 `wireinject` 文件的包，Gazelle 扩展在 `BUILD.bazel` 中生成：

**输入（开发者写的源码）：**

```text
cmd/
  main.go
  wire.go          ← 带 //go:build wireinject
```

**Gazelle 生成的 BUILD.bazel：**

```starlark
load("@rules_go//go:def.bzl", "go_binary", "go_library")
load("@wire.bzl//wire:defs.bzl", "wire_gen")

# wire_gen: 自动生成，用户不需要手动编写
wire_gen(
    name = "wire_gen",
    srcs = ["wire.go"],
    deps = [
        "//internal/adapter",
        "//internal/infra",
        "//pkg/framework",
        "@com_github_google_wire//wire",
    ],
    importpath = "github.com/example/app/cmd",
)

# go_library: srcs 自动包含 :wire_gen，排除 wire.go
go_library(
    name = "go_default_library",
    srcs = [
        "main.go",
        ":wire_gen",       # ← 自动生成添加
    ],
    importpath = "github.com/example/app/cmd",
    visibility = ["//visibility:private"],
    deps = [
        "//internal/adapter",
        "//internal/infra",
        "//pkg/framework",
        "@com_github_google_wire//wire",
    ],
)

go_binary(
    name = "cmd",
    embed = [":go_default_library"],
    visibility = ["//visibility:public"],
)
```

### 2.4 扩展实现架构

```text
gazelle/
  wire/
    lang.go              # 实现 language.Language 接口
    generate.go          # 实现 GenerateRules 方法
    configure.go         # 实现 Configure 方法（读取指令）
    fix.go               # 实现 Fix 方法（清理旧规则）
    known_imports.go     # wire 相关的 import path 常量
    lang_test.go         # 单元测试
    BUILD.bazel
```

核心接口实现：

```go
// lang.go
package wire

import "github.com/bazelbuild/bazel-gazelle/language"

type wireLang struct{}

func NewLanguage() language.Language {
    return &wireLang{}
}

func (l *wireLang) Name() string { return "wire" }
```

```go
// generate.go
func (l *wireLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
    // 1. 扫描 args.Dir 中的 .go 文件
    // 2. 解析 build constraints，找出 wireinject 文件
    // 3. 如果没有 wireinject 文件，返回空结果
    // 4. 生成 wire_gen 规则
    // 5. 生成对 go_library 的 patch（添加 :wire_gen 到 srcs）

    var wireFiles []string
    for _, f := range args.RegularFiles {
        if hasWireinjectTag(filepath.Join(args.Dir, f)) {
            wireFiles = append(wireFiles, f)
        }
    }

    if len(wireFiles) == 0 {
        return language.GenerateResult{}
    }

    // 构建 wire_gen 规则
    wireGenRule := rule.NewRule("wire_gen", "wire_gen")
    wireGenRule.SetAttr("srcs", wireFiles)
    wireGenRule.SetAttr("deps", collectDeps(args))
    wireGenRule.SetAttr("importpath", args.Rel)

    // 构建对 go_library 的 patch
    genFiles := []string{":wire_gen"}

    return language.GenerateResult{
        Gen:     []*rule.Rule{wireGenRule},
        Imports: []interface{}{nil},
        Empty:   []*rule.Rule{},
    }
}
```

### 2.5 Gazelle 指令支持

```starlark
# BUILD.bazel 或 .bazelrc 中配置
# gazelle:wire_importpath github.com/example/app
```

| 指令 | 说明 |
| --- | --- |
| `gazelle:wire_importpath <path>` | 覆盖自动推断的 importpath |
| `gazelle:wire_tool <label>` | 覆盖默认的 Wire 工具 label |
| `gazelle:wire_tags <tags>` | 额外的 Wire build tags |

### 2.6 与 Gazelle Go 扩展的协作

Wire 扩展不替代 Gazelle 的 Go 语言扩展，而是与之协作：

1. **Go 扩展**负责生成 `go_library`、`go_binary` 等标准规则
2. **Wire 扩展**在 Go 扩展之后运行，检测到 `wireinject` 文件时：
   - 生成 `wire_gen` 规则
   - 通过 `GenerateResult` 中的 `Gen` 添加 patch，将 `:wire_gen`
     注入到已生成的 `go_library.srcs` 中
   - 从 `go_library.srcs` 中移除 `wire.go`（因为 `wireinject` tag
     的文件不应参与正常编译）

协作顺序：Gazelle 按语言注册顺序依次执行各扩展的 `GenerateRules`，
Wire 扩展通过 `language.GenerateResult.Gen` 返回的规则会合并到最终的 BUILD 文件中。

---

## 三、当前实现中的设计缺陷

### 3.1 Import Path 推断逻辑脆弱（严重）

**现状：** `_infer_import_path` 遍历所有传递依赖，寻找
"importpath 以 `/+package` 结尾"的候选，仅在恰好一个候选时返回结果，
否则返回 `bazelgowire.invalid/input`。

**问题：**

1. 依赖 Bazel package 路径与 Go import path 的镜像关系，仅在 Gazelle
   约定下可靠
2. fallback 值 `bazelgowire.invalid/input` 不是合法的 Go import path
3. 多候选歧义时直接放弃推断

**改造方案：**

```python
def _resolve_import_path(ctx):
    # 优先使用用户显式声明
    if ctx.attr.importpath:
        return ctx.attr.importpath

    # 从 deps 的 GoArchive 推断（改进版）
    candidates = {}
    for dep in ctx.attr.deps:
        for archive in dep[GoArchive].transitive.to_list():
            label = archive.label
            if label.workspace_root or label.repo_name:
                continue
            package = label.package
            if not package:
                continue
            importpath = archive.importmap or archive.importpath
            if not importpath.endswith("/" + package):
                continue
            module_prefix = importpath[:-len(package)]
            candidate = (module_prefix + ctx.label.package).rstrip("/")
            if candidate:
                candidates[candidate] = True

    if len(candidates) == 1:
        return list(candidates.keys())[0]

    # 改进的 fallback：尝试从 go.mod 或 MODULE.bazel 推断
    # 如果仍然失败，给出明确的错误信息而非无效路径
    if not candidates:
        fail(
            "{}: cannot infer importpath. ".format(ctx.label) +
            "Please set importpath explicitly, or ensure deps include " +
            "a same-repository package with a matching Go import path.",
        )

    fail(
        "{}: ambiguous importpath candidates: {}. ".format(
            ctx.label,
            ", ".join(sorted(candidates.keys())),
        ) +
        "Please set importpath explicitly.",
    )
```

### 3.2 Toolchain 抽象缺失（中等）

**现状：** `wire_tool` 属性默认硬编码为 `@com_github_google_wire//cmd/wire`。

**问题：**
1. 不同项目可能用不同的外部仓库名
2. 无法在组织级别统一管控 Wire 版本
3. 跨平台构建时无法按执行平台选择

**改造方案：**

```starlark
# wire/toolchain.bzl — 新增工具链定义

wire_toolchain = rule(
    implementation = _wire_toolchain_impl,
    attrs = {
        "wire": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "github.com/google/wire/cmd/wire 编译目标",
        ),
    },
    provides = [platform_common.ToolchainInfo],
)

def _wire_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        wire = ctx.executable.wire,
    )]
```

```starlark
# wire/extensions.bzl — Module extension

wire = module_extension(
    implementation = _wire_ext_impl,
    tag_classes = {
        "toolchain": tag_class(attrs = {
            "wire": attr.label(mandatory = True),
        }),
    },
)
```

用户配置方式：

```starlark
# MODULE.bazel
wire = use_extension("@wire.bzl//wire:extensions.bzl", "wire")
wire.toolchain(wire = "@com_github_google_wire//cmd/wire")
use_repo(wire, "wire_bzl_toolchain")
register_toolchains("@wire_bzl_toolchain//:all")
```

### 3.3 GOPATH 模式（`GO111MODULE=off`）过时（中等）

**现状：** action 环境变量中 `GO111MODULE=off`，在沙箱中构建 GOPATH 目录结构。

**问题：**
1. Go 1.22+ 已逐步弱化 GOPATH 模式支持
2. GOPATH 模式下的 `go/packages` 加载行为与 module mode 不同
3. 某些依赖 `go.mod` 信息的包可能无法正常工作

**改造方案：**

在沙箱中构建临时 Go module 环境，替代 GOPATH 布局：

```python
lines = [
    'export GO111MODULE=on',
    'export GOMODCACHE="$EXEC_ROOT/.gowire_modcache"',
    'mkdir -p "$GOMODCACHE"',
]

# 为当前包创建临时 go.mod
module_dir = paths.join(work_dir, import_path)
lines.append('echo "module ' + import_path + '" > "' + module_dir + '/go.mod"')
lines.append('echo "go 1.21" >> "' + module_dir + '/go.mod"')

# 传递依赖通过 replace 指令指向沙箱源码
for importpath in sorted(packages.keys()):
    dep_dir = paths.join(work_dir, importpath)
    lines.append('echo "require ' + importpath + ' v0.0.0" >> "' + module_dir + '/go.mod"')
    lines.append('echo "replace ' + importpath + ' => ' + dep_dir + '" >> "' + module_dir + '/go.mod"')
```

**注意事项：**
- 需要为每个传递依赖也创建最小化的 `go.mod`
- `replace` 路径必须是绝对路径或相对 `go.mod` 的路径
- 改造后可移除整个 GOPATH 目录结构

### 3.4 E2E 测试未实际使用 wire 规则（严重）

**现状：** `e2e/smoke/cmd/BUILD.bazel` 只有普通 `go_library` + `go_binary`，
完全没有调用 wire 规则。`wire.go` 存在但 `wire_gen.go` 从未被生成，
构建必然失败。

**改造方案（使用确定的 `wire_gen` API）：**

```starlark
# e2e/smoke/cmd/BUILD.bazel
load("@rules_go//go:def.bzl", "go_binary", "go_library")
load("@wire.bzl//wire:defs.bzl", "wire_gen")

wire_gen(
    name = "wire_gen",
    srcs = ["wire.go"],
    deps = [
        "//internal/adapter",
        "//internal/infra",
        "//pkg/framework",
        "@com_github_google_wire//wire",
    ],
    importpath = "github.com/qhai-dev/wire.bzl/e2e/smoke/cmd",
)

go_library(
    name = "go_default_library",
    srcs = [
        "main.go",
        ":wire_gen",
    ],
    importpath = "github.com/qhai-dev/wire.bzl/e2e/smoke/cmd",
    visibility = ["//visibility:private"],
    deps = [
        "//internal/adapter",
        "//internal/infra",
        "//pkg/framework",
        "@com_github_google_wire//wire",
    ],
)

go_binary(
    name = "app",
    embed = [":go_default_library"],
    visibility = ["//visibility:public"],
)
```

### 3.5 Shell 脚本健壮性不足（低）

**问题：**
1. 临时文件未清理，依赖 Bazel sandbox 自动清理
2. Wire 输出验证仅检查文件是否存在
3. 跨平台兼容性未验证

**改造方案：**

```python
lines = [
    "set -euo pipefail",
    'trap "rm -rf \\"$GOCACHE\\" \\"$TMPDIR\\" \\"$HOME\\"" EXIT',
    # ... Wire 执行 ...
    # 增强输出验证
    "if [ ! -s wire_gen.go ]; then",
    '  echo "wire_gen: output is empty or missing" >&2',
    "  exit 1",
    "fi",
    'if ! head -20 wire_gen.go | grep -q "^package "; then',
    '  echo "wire_gen: output does not contain a package declaration" >&2',
    "  exit 1",
    "fi",
]
```

### 3.6 `BUILD.bazel` 示例文件包含语法错误（低）

**现状：**
- load 路径 `@bazel_gowire` 不存在
- `go_binary` 缺少逗号
- `gowire` 宏名与实际 API 不匹配

**改造方案：** 清理根目录 `BUILD.bazel`，或删除（实际示例在 e2e 中维护）。

---

## 四、改造优先级与路线图

### Phase 1：核心规则重构 + E2E 修复（v0.1.0）

| 优先级 | 改造项 | 工作量 | 说明 |
| --- | --- | --- | --- |
| P0 | 重构 `wire_gen` 规则（统一 API） | 中 | 确定的最终 API |
| P0 | 修复 E2E 测试 | 小 | 使用 `wire_gen` + `go_library` 组合 |
| P0 | 清理 `BUILD.bazel` 语法错误 | 小 | 删除或修复根目录示例 |
| P0 | 统一命名，删除废弃别名 | 小 | 仅保留 `wire_gen` |
| P1 | 改进 import path 推断错误信息 | 小 | 推断失败时给出明确提示 |
| P1 | 实现 Toolchain 抽象 | 中 | Module extension 注册 |

### Phase 2：Gazelle 扩展（v0.2.0）

| 优先级 | 改造项 | 工作量 | 说明 |
| --- | --- | --- | --- |
| P1 | 实现 Wire Gazelle 语言扩展 | 大 | 自动生成 `wire_gen` + patch `go_library` |
| P2 | 支持 Gazelle 指令 | 中 | `gazelle:wire_importpath` 等 |

### Phase 3：稳健性提升（v0.3.0）

| 优先级 | 改造项 | 工作量 | 说明 |
| --- | --- | --- | --- |
| P2 | GOPATH → Module 模式迁移 | 大 | 沙箱布局重构 |
| P2 | Shell 脚本健壮性增强 | 小 | 清理、验证、跨平台 |
| P3 | `wire_check` / `wire_diff` test 规则 | 中 | CLI 语义映射扩展 |

---

## 五、文件结构改造建议

```text
# 当前
wire.bzl                          # 根目录 re-export（删除）
wire/
  wire.bzl                        # 全部实现（重构拆分）
  BUILD.bazel

# 目标
wire/
  defs.bzl                        # 公共 API 入口：wire_gen
  wire.bzl                        # _wire_gen 规则实现（内部）
  toolchain.bzl                   # wire_toolchain 定义
  extensions.bzl                  # Module extension（工具链注册）
  BUILD.bazel

gazelle/
  wire/
    lang.go                       # Gazelle 语言扩展
    generate.go                   # 规则生成逻辑
    configure.go                  # 指令解析
    fix.go                        # 旧规则清理
    lang_test.go                  # 单元测试
    BUILD.bazel

e2e/
  smoke/
    cmd/
      BUILD.bazel                 # 使用 wire_gen 的完整示例
```

---

## 六、用户视角的完整工作流

### 手工编写 BUILD（无 Gazelle）

```starlark
load("@rules_go//go:def.bzl", "go_binary", "go_library")
load("@wire.bzl//wire:defs.bzl", "wire_gen")

# 1. Wire 代码生成
wire_gen(
    name = "wire_gen",
    srcs = ["wire.go"],
    deps = [
        "//internal/server",
        "@com_github_google_wire//wire",
    ],
    importpath = "github.com/example/app/cmd",
)

# 2. Go 库（引用生成产物）
go_library(
    name = "go_default_library",
    srcs = [
        "main.go",
        ":wire_gen",     # ← 引用 wire_gen 的输出
    ],
    deps = [
        "//internal/server",
        "@com_github_google_wire//wire",
    ],
    importpath = "github.com/example/app/cmd",
    visibility = ["//visibility:private"],
)

# 3. 可执行文件
go_binary(
    name = "app",
    embed = [":go_default_library"],
    visibility = ["//visibility:public"],
)
```

### 使用 Gazelle 自动生成

开发者只需维护源码文件，`BUILD.bazel` 由 Gazelle 自动生成：

```bash
# 运行 Gazelle 更新 BUILD 文件
bazel run //:gazelle
```

Gazelle 扩展自动检测 `wire.go` 中的 `wireinject` tag，
生成 `wire_gen` 规则并 patch `go_library.srcs`。

### MODULE.bazel 配置

```starlark
# MODULE.bazel
bazel_dep(name = "rules_go", version = "0.65.0")
bazel_dep(name = "gazelle", version = "2.0.0-beta.2")
bazel_dep(name = "wire.bzl", version = "0.1.0")

# Go SDK 和依赖
go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")
go_sdk.from_file(go_mod = "//:go.mod")

go_deps = use_extension("@gazelle//:extensions.bzl", "go_deps")
go_deps.from_file(go_mod = "//:go.mod")
use_repo(go_deps, "com_github_google_wire")

# Wire 工具链（可选，有默认值）
wire = use_extension("@wire.bzl//wire:extensions.bzl", "wire")
wire.toolchain(wire = "@com_github_google_wire//cmd/wire")
use_repo(wire, "wire_bzl_toolchain")
register_toolchains("@wire_bzl_toolchain//:all")

# Gazelle
gazelle = use_extension("@gazelle//:extensions.bzl", "gazelle")
# Wire 语言扩展随 wire.bzl 自动注册
```

---

## 七、备选方案讨论记录

### 被否决的方案

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| `wire_library` 高层宏 | 不采用 | 创建影子规则，用户困惑"该用哪个" |
| `wire_gen` 接收 `library` 参数 | 不采用 | 增加概念复杂度，生成规则不应依赖已编译 Go 库 |
| `go_wire_compiler` + `go_wire_gen` 双规则 | 不采用 | 过度设计，Wire 不需要 compiler 级别的抽象 |
| `wire_go_library` 命名 | 不采用 | 暗示是特殊的 library，实际展开后就是 `go_library` |
| Starlark 变量消除 deps 重复 | 不作为方案 | 仅适用于小规模，不解决根本问题 |
| 高层宏 + 低层规则双层 API | 不采用 | 简单场景用 `wire_gen` 就够了 |
| `output` / `out` 可配置属性 | 不采用 | 输出永远固定为 `wire_gen.go`，与 Wire 官方约定一致 |

### 采纳的方案

| 方案 | 理由 |
| --- | --- |
| `wire_gen` 单一生成规则 | 职责单一，组合自由，概念最少 |
| Gazelle 扩展消除手工维护 | 自动化解决 deps 重复，与 Go 扩展协作 |
| Toolchain 抽象 | 支持组织级版本管控和跨平台 |
