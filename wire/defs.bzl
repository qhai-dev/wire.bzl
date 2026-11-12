"""Public entry point for wire.bzl.

    load("@wire.bzl//wire:defs.bzl", "wire_gen")

    wire_gen(
        name = "wire_gen",
        srcs = ["wire.go"],
        deps = ["//internal/server", "@com_github_google_wire//wire"],
        importpath = "github.com/example/app/cmd",
    )

`wire_gen` only generates `wire_gen.go`. Compose it with `go_library` /
`go_binary` yourself; the generated file is the target's default output.

The Wire executable comes from toolchain resolution. A default toolchain is
registered by this module, so no configuration is required. To pin a different
Wire version, register your own toolchain via `wire/extensions.bzl`.
"""

load("//wire:toolchain.bzl", _wire_toolchain = "wire_toolchain")
load("//wire:wire.bzl", _wire_gen = "wire")

wire_toolchain = _wire_toolchain

# Canonical public name.
wire_gen = _wire_gen

# Backwards-compatible alias for the original macro name. Prefer `wire_gen`.
wire = _wire_gen
