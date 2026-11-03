# wire.bzl 设计评审与改进方案

| 状态 | 评审日期 | 基于版本 |
| --- | --- | --- |
| 评审完成，待实施 | 2026-11-03 | wire/wire.bzl 当前实现 + wire-rules-api-design.md 草案 |

本文档对 `wire/wire.bzl` 当前实现进行设计评审，识别与 `wire-rules-api-design.md`
设计文档之间的差距和实现中的设计问题，并提出具体的改进方案和改造路径。

---

## 一、当前实现与设计文档的核心差距

### 1.1 缺失 `wire_library` 高层宏（严重）

**现状：** 当前实现只提供一个低层 `wire` 宏（包裹 `_wire` 规则），用户必须手动组合
`wire()` 和 `go_library()` 两个目标。

**设计文档要求：** `wire_library` 宏作为推荐入口，一个目标同时完成：
- 创建 Wire 输入库（带 `wireinject` build tag）
- 调用 Wire 生成 `wire_gen.go`
- 创建最终的 `go_library`（不包含 `wireinject` tag）

**影响：** 用户体验与 `go_library` 不一致，使用门槛高，容易出错（遗漏依赖、
importpath 不一致等）。

**改造方案：**

```starlark
# wire/defs.bzl — 新增 wire_library 宏

def wire_library(
        name,
        srcs = [],
        deps = [],
        embed = [],
        gotags = [],
        importpath = "",
        header_file = None,
        wire_tags = [],
        visibility = None,
        testonly = False):
    """推荐入口。展开为 wire 输入库 + 生成目标 + 最终 go_library。"""

    input_name = name + "_wire_input"
    gen_name = name + "_wire_gen"

    # 1. 输入库：带 wireinject tag，让 Wire 能看到注入器声明
    all_input_tags = list(gotags)
    for tag in ["wireinject"] + wire_tags:
        if tag not in all_input_tags:
            all_input_tags.append(tag)

    native_go_library(
        name = input_name,
        srcs = srcs,
        deps = deps,
        embed = embed,
        gotags = all_input_tags,
        importpath = importpath,
        visibility = ["//visibility:private"],
        testonly = testonly,
    )

    # 2. 生成目标：从输入库执行 wire gen
    wire_gen(
        name = gen_name,
        library = ":" + input_name,
        header_file = header_file,
        wire_tags = wire_tags,
        visibility = ["//visibility:private"],
        testonly = testonly,
    )

    # 3. 最终 go_library：不带 wireinject tag
    native_go_library(
        name = name,
        srcs = srcs + [":" + gen_name],
        deps = deps,
        embed = embed,
        gotags = gotags,
        importpath = importpath,
        visibility = visibility,
        testonly = testonly,
    )
```

用户使用方式变为：

```starlark
load("@rules_go_wire//wire:defs.bzl", "wire_library")

wire_library(
    name = "app",
    srcs = ["app.go", "wire.go"],
    deps = [
        "//internal/config",
        "//internal/server",
        "@com_github_google_wire//wire",
    ],
    importpath = "example.com/demo/app",
)

go_binary(
    name = "server",
    embed = [":app"],
)
```

### 1.2 `wire_gen` 规则输入模型不一致（严重）

**现状：** `_wire` 规则直接接收 `srcs`（原始文件列表）和 `deps`（GoArchive 列表）。
Wire 的输入是一堆裸文件，不是已构建的 Go 库。

**设计文档要求：** `wire_gen` 接收一个 `library` 参数（已完成 build-constraint 选择的
`go_library` 目标），从 `GoInfo`/`GoArchive` provider 中提取源码和依赖信息。

**影响：**
- 当前实现无法利用 `go_library` 已完成的 build tag 过滤
- 用户需要重复声明 `srcs` 和 `deps`（wire 和 go_library 各写一遍）
- 无法与 `embed` 属性配合使用

**改造方案：**

将 `_wire` 规则的输入从裸文件改为接受 `go_library` 目标：

```starlark
_wire_gen = rule(
    implementation = _wire_gen_impl,
    attrs = {
        "library": attr.label(
            providers = [GoArchive],  # 或 GoInfo
            mandatory = True,
            doc = "Wire 输入包，必须是带 wireinject tag 的 go_library",
        ),
        "out": attr.output(mandatory = True),
        "header_file": attr.label(allow_single_file = True),
        "wire_tags": attr.string_list(),
        "wire_tool": attr.label(
            default = _DEFAULT_WIRE_TOOL,
            executable = True,
            cfg = "exec",
        ),
        # ...
    },
)
```

实现中从 `library[GoArchive]` 提取 `importpath`、`srcs`、传递依赖等信息，
消除 `_infer_import_path` 的猜测逻辑。

### 1.3 命名混乱（中等）

**现状：** 存在多个不一致的命名：

| 位置 | 名称 | 说明 |
| --- | --- | --- |
| 根 `wire.bzl` | `wire` | 重新导出的宏 |
| `wire/wire.bzl` 规则 | `_wire` | 内部规则 |
| `wire/wire.bzl` 宏 | `wire` | 公共宏 |
| 设计文档 | `wire_library` | 推荐高层宏（未实现） |
| 设计文档 | `wire_gen` | 低层生成规则（未实现） |
| API 设计文档 | `gowire` | 又一个别名 |
| `BUILD.bazel` 示例 | `gowire` | load 自不存在的 `@bazel_gowire//rules:gowire.bzl` |

**改造方案：** 统一命名体系：

- `wire_library` — 推荐高层宏（新增）
- `wire_gen` — 低层生成规则（从 `_wire` 重命名）
- `wire` — 保留为 `wire_gen` 的兼容别名，标记 deprecated
- 删除 `gowire` 命名，清理 `BUILD.bazel` 中不存在的 load 路径

---

## 二、当前实现中的设计缺陷

### 2.1 Import Path 推断逻辑脆弱（严重）

**现状分析：**

```python
def _infer_import_path(ctx, packages):
    # 遍历所有传递依赖，寻找 "importpath 以 /+package 结尾" 的候选
    # 仅在恰好一个候选时返回结果
    # 否则返回 "bazelgowire.invalid/input"
```

**问题：**

1. **脆弱性：** 依赖 Bazel package 路径与 Go import path 的镜像关系，仅在 Gazelle
   约定下可靠。一旦布局不匹配（自定义 `importpath`、多模块仓库），推断失败。
2. **fallback 无意义：** `bazelgowire.invalid/input` 不是一个合法的 Go import path，
   Wire 在处理 `internal` 包导入时会因此报错。
3. **多候选歧义：** 当依赖来自多个同仓库不同子包时，可能产生多个候选，函数直接
   放弃推断。

**改造方案：**

```python
def _resolve_import_path(ctx, go_archive):
    """从 go_library 的 GoArchive 中直接读取 importpath，无需推断。"""

    # 方案 A：如果 wire_gen 接收 library 参数，直接从 GoArchive 读取
    if hasattr(ctx.attr, "library"):
        archive = ctx.attr.library[GoArchive]
        return archive.importmap or archive.importpath

    # 方案 B：如果仍然使用裸文件，增加 module_path 属性
    if ctx.attr.importpath:
        return ctx.attr.importpath

    if ctx.attr.module_path:
        # module_path = "github.com/user/project"
        # package = "internal/server"
        # importpath = module_path + "/" + package
        return ctx.attr.module_path.rstrip("/") + "/" + ctx.label.package

    # 最后的 fallback：尝试从 deps 推断（保留现有逻辑但改进）
    return _infer_import_path_improved(ctx)
```

核心改进：**当 `wire_gen` 接收 `library` 参数时，importpath 可以从 `GoArchive`
直接获取，完全消除推断逻辑。**

### 2.2 Toolchain 抽象缺失（中等）

**现状：** `wire_tool` 属性默认硬编码为 `@com_github_google_wire//cmd/wire`。

**问题：**
1. 不同项目可能用不同的外部仓库名（取决于 `go_deps` 的配置）
2. 无法在组织级别统一管控 Wire 版本
3. 跨平台构建时无法按执行平台选择不同版本的 Wire

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

def _wire_ext_impl(module_ctx):
    for mod in module_ctx.modules:
        for tc in mod.tags.toolchain:
            # 注册工具链
            ...

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
wire = use_extension("@rules_go_wire//wire:extensions.bzl", "wire")
wire.toolchain(wire = "@com_github_google_wire//cmd/wire")
use_repo(wire, "rules_go_wire_toolchain")
register_toolchains("@rules_go_wire_toolchain//:all")
```

### 2.3 GOPATH 模式（`GO111MODULE=off`）过时（中等）

**现状：**

```python
env = {
    "GO111MODULE": "off",
    # ...
}
```

**问题：**
1. Go 1.22+ 已逐步弱化 GOPATH 模式支持，未来版本可能移除
2. GOPATH 模式下的 `go/packages` 加载行为与 module mode 不同
3. 某些依赖 `go.mod` 信息的包（如 `embed` 指令引用模块资源）可能无法正常工作

**改造方案：**

在沙箱中构建临时 Go module 环境：

```python
# 在沙箱中创建临时 module
lines = [
    # ... 环境变量设置 ...
    'export GO111MODULE=on',
    'export GOMODCACHE="$EXEC_ROOT/.gowire_modcache"',
    'mkdir -p "$GOMODCACHE"',
]

# 为当前包创建临时 go.mod
module_dir = paths.join(gopath, "src", import_path)
lines.append('echo "module ' + import_path + '" > "' + module_dir + '/go.mod"')
lines.append('echo "go 1.21" >> "' + module_dir + '/go.mod"')

# 将所有传递依赖以 replace 指令指向沙箱中的源码
for importpath in sorted(packages.keys()):
    dep_dir = paths.join(gopath, "src", importpath)
    lines.append('echo "require ' + importpath + ' v0.0.0" >> "' + module_dir + '/go.mod"')
    lines.append('echo "replace ' + importpath + ' => ' + dep_dir + '" >> "' + module_dir + '/go.mod"')
```

**注意事项：**
- 需要为每个传递依赖也创建最小化的 `go.mod`
- `replace` 路径必须是绝对路径或相对 `go.mod` 的路径
- 改造后可移除整个 GOPATH 目录结构，改用 module-aware 的沙箱布局

### 2.4 E2E 测试未实际使用 wire 规则（严重）

**现状：** `e2e/smoke/cmd/BUILD.bazel` 中只有普通的 `go_library` + `go_binary`，
完全没有调用 `wire()` 或 `wire_library()`：

```starlark
# 当前 e2e/smoke/cmd/BUILD.bazel
go_library(
    name = "go_default_library",
    srcs = ["main.go"],
    importpath = "github.com/qhai-dev/wire.bzl/e2e/smoke/cmd",
    visibility = ["//visibility:private"],
)
```

但 `wire.go` 文件确实存在且包含 `InitializeApp` 注入器声明。这意味着：
- E2E 测试无法验证 wire 规则是否正常工作
- `main.go` 调用了 `InitializeApp()` 但 `wire_gen.go` 从未被生成
- 构建一定会失败（`InitializeApp` 未定义）

**改造方案：**

```starlark
# e2e/smoke/cmd/BUILD.bazel — 改造后
load("@rules_go//go:def.bzl", "go_binary")
load("@wire.bzl//wire:defs.bzl", "wire_library")

wire_library(
    name = "cmd",
    srcs = [
        "main.go",
        "wire.go",
    ],
    deps = [
        "//internal/adapter",
        "//internal/infra",
        "//pkg/framework",
        "@com_github_google_wire//wire",
    ],
    importpath = "github.com/qhai-dev/wire.bzl/e2e/smoke/cmd",
)

go_binary(
    name = "app",
    embed = [":cmd"],
    visibility = ["//visibility:public"],
)
```

如果 `wire_library` 尚未实现，可先用低层 API：

```starlark
load("@rules_go//go:def.bzl", "go_binary", "go_library")
load("@wire.bzl//wire:defs.bzl", "wire_gen")

go_library(
    name = "cmd_wire_input",
    srcs = ["main.go", "wire.go"],
    deps = [
        "//internal/adapter",
        "//internal/infra",
        "//pkg/framework",
        "@com_github_google_wire//wire",
    ],
    gotags = ["wireinject"],
    importpath = "github.com/qhai-dev/wire.bzl/e2e/smoke/cmd",
    visibility = ["//visibility:private"],
)

wire_gen(
    name = "cmd_wire_gen",
    library = ":cmd_wire_input",
)

go_library(
    name = "cmd",
    srcs = [
        "main.go",
        ":cmd_wire_gen",
    ],
    deps = [
        "//internal/adapter",
        "//internal/infra",
        "//pkg/framework",
        "@com_github_google_wire//wire",
    ],
    importpath = "github.com/qhai-dev/wire.bzl/e2e/smoke/cmd",
)

go_binary(
    name = "app",
    embed = [":cmd"],
    visibility = ["//visibility:public"],
)
```

### 2.5 Shell 脚本健壮性不足（低）

**现状问题：**

1. **临时文件未清理：** `.gowire_cache`、`.gowire_tmp`、`.gowire_home` 创建在
   执行根目录，依赖 Bazel sandbox 自动清理
2. **Wire 输出验证不足：** 仅检查 `wire_gen.go` 是否存在，不验证内容有效性
3. **跨平台兼容性：** `cp -fL` 在 Windows 上的行为不确定

**改造方案：**

```python
lines = [
    "set -euo pipefail",  # 增加 -u (未定义变量报错) 和 -o pipefail
    # ...
    # 添加 trap 清理
    'trap "rm -rf \\"$GOCACHE\\" \\"$TMPDIR\\" \\"$HOME\\"" EXIT',
    # ...
    # 增强输出验证
    "if [ ! -s wire_gen.go ]; then",
    '  echo "GoWireGen: wire_gen.go is empty or missing" >&2',
    "  exit 1",
    "fi",
    # 验证生成文件是合法 Go 源码（至少包含 package 声明）
    'if ! head -20 wire_gen.go | grep -q "^package "; then',
    '  echo "GoWireGen: wire_gen.go does not contain a package declaration" >&2',
    "  exit 1",
    "fi",
]
```

### 2.6 `BUILD.bazel` 示例文件包含语法错误（低）

**现状：** 根目录 `BUILD.bazel` 存在多处语法问题：

```starlark
# 问题 1：load 路径不存在
load("@bazel_gowire//rules:gowire.bzl", "gowire")

# 问题 2：go_binary 缺少逗号
go_binary(
    name = "app"        # ← 缺少逗号
    srcs = [
        "main.go",
        ":wire"
    ]
)

# 问题 3：load 了不存在的 @bazel_gowire 仓库
```

**改造方案：** 清理根目录 `BUILD.bazel`，或将其替换为可工作的示例。

---

## 三、建议的改造优先级与路线图

### Phase 1：修复关键问题（v0.1.0 前必须完成）

| 优先级 | 改造项 | 工作量 | 说明 |
| --- | --- | --- | --- |
| P0 | 修复 E2E 测试 | 小 | 让测试真正调用 wire 规则并构建通过 |
| P0 | 清理 `BUILD.bazel` 语法错误 | 小 | 删除或修复根目录示例 |
| P0 | 实现 `wire_gen` 规则（基于 `library` 输入） | 中 | 核心规则重构 |
| P0 | 实现 `wire_library` 高层宏 | 中 | 用户体验关键 |

### Phase 2：架构改进（v0.1.0）

| 优先级 | 改造项 | 工作量 | 说明 |
| --- | --- | --- | --- |
| P1 | 消除 import path 推断（改用 `GoArchive` 读取） | 小 | 随 Phase 1 自然解决 |
| P1 | 统一命名体系 | 小 | `wire_library` / `wire_gen` / `wire` |
| P1 | 实现 Toolchain 抽象 | 中 | 支持 Bzlmod extension 注册 |

### Phase 3：稳健性提升（v0.2.0）

| 优先级 | 改造项 | 工作量 | 说明 |
| --- | --- | --- | --- |
| P2 | 从 GOPATH 模式迁移到 Module 模式 | 大 | 沙箱布局重构 |
| P2 | Shell 脚本健壮性增强 | 小 | 清理、验证、跨平台 |
| P2 | 添加 `wire_check` test 规则 | 中 | 支持 wire check/diff 语义 |
| P3 | Gazelle 扩展（自动生成 BUILD） | 大 | 非目标版本范围 |

---

## 四、文件结构改造建议

当前结构 → 目标结构：

```text
# 当前
wire.bzl                          # 根目录 re-export（删除）
wire/
  wire.bzl                        # 全部实现（重构拆分）
  BUILD.bazel

# 目标
wire/
  defs.bzl                        # 公共 API：wire_library + wire_gen + wire（兼容别名）
  wire.bzl                        # 低层 _wire_gen 规则实现
  toolchain.bzl                   # wire_toolchain 定义
  extensions.bzl                  # Module extension（工具链注册）
  BUILD.bazel
  private/
    gopath.bzl                    # GOPATH/Module 沙箱构建逻辑
    imports.bzl                   # import path 解析逻辑
```

`defs.bzl` 成为唯一公共入口：

```starlark
# wire/defs.bzl
load("//wire:wire.bzl", _wire_gen = "wire_gen")
load("//wire:toolchain.bzl", _wire_toolchain = "wire_toolchain")

wire_gen = _wire_gen
wire_toolchain = _wire_toolchain

def wire_library(...):
    ...

# 兼容别名（deprecated）
def wire(...):
    # buildifier: disable=print
    print("WARNING: wire() is deprecated, use wire_library() or wire_gen()")
    wire_gen(...)
```

---

## 五、迁移指南（面向现有用户）

### 从旧 `wire()` 宏迁移

**旧代码：**

```starlark
load("@wire.bzl//:wire.bzl", "wire")

wire(
    name = "wire",
    srcs = ["wire.go"],
    deps = ["//internal/server", "@com_github_google_wire//wire"],
)

go_binary(
    name = "app",
    srcs = ["main.go", ":wire"],
    deps = ["//internal/server", "@com_github_google_wire//wire"],
)
```

**新代码（推荐）：**

```starlark
load("@rules_go_wire//wire:defs.bzl", "wire_library")

wire_library(
    name = "app_lib",
    srcs = ["main.go", "wire.go"],
    deps = ["//internal/server", "@com_github_google_wire//wire"],
    importpath = "example.com/myapp",
)

go_binary(
    name = "app",
    embed = [":app_lib"],
)
```

**新代码（低层 API）：**

```starlark
load("@rules_go//go:def.bzl", "go_binary", "go_library")
load("@rules_go_wire//wire:defs.bzl", "wire_gen")

go_library(
    name = "app_wire_input",
    srcs = ["main.go", "wire.go"],
    deps = ["//internal/server", "@com_github_google_wire//wire"],
    gotags = ["wireinject"],
    importpath = "example.com/myapp",
)

wire_gen(
    name = "app_wire_gen",
    library = ":app_wire_input",
)

go_library(
    name = "app_lib",
    srcs = ["main.go", ":app_wire_gen"],
    deps = ["//internal/server", "@com_github_google_wire//wire"],
    importpath = "example.com/myapp",
)

go_binary(
    name = "app",
    embed = [":app_lib"],
)
```
