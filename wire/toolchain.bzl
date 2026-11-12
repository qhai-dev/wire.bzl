"""Wire toolchain definition.

Wire ships no prebuilt binary, so the `wire` executable is compiled from the
Go module source pinned in the project's `go.mod` (see
`docs/wire-toolchain-design.md`). This file defines the toolchain that carries
that executable to `wire_gen`.

The `wire` attribute uses `cfg = "exec"`: Wire is a build-time tool and must be
built for the execution platform, not the target platform. Without this,
cross-compilation would try to run a target-platform binary and fail.
"""

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
            doc = "The `github.com/google/wire/cmd/wire` build target. Normally " +
                  "provided as Go module source by `go_deps` and compiled by " +
                  "`rules_go`, e.g. `@com_github_google_wire//cmd/wire:wire`.",
        ),
    },
    provides = [platform_common.ToolchainInfo],
    doc = "Wraps a Wire executable so `wire_gen` can obtain it through " +
          "Bazel toolchain resolution.",
)
