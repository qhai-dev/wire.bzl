"""Rules for running Wire's dependency injection code generator.

The public entry point is the `gowire` macro. It takes the files that declare
the injectors (normally a single `wire.go` guarded by the `wireinject` build
tag) and the Go libraries they depend on, runs the official Wire CLI, and
exposes the generated `wire_gen.go` as a source file that can be listed in a
`go_binary` or `go_library`'s `srcs`.

Wire has no equivalent of `mockgen -archive`: `wire gen` always loads and
type-checks Go source with `go/packages`. The action therefore materializes a
GOPATH containing the package under generation plus the source of every
transitive dependency, which is collected from the `GoArchive` providers of
`deps`. Nothing is fetched from the network and the user's module cache is
never read.
"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_go//go:def.bzl", "GoArchive", "go_context")

_GO_TOOLCHAIN = Label("@rules_go//go:toolchain")

_DEFAULT_WIRE_TOOL = Label("@com_github_google_wire//cmd/wire")

# Fallback import path for the package under generation. Dependencies are
# placed at their real import paths and every import in the generated file
# refers to those, so the current package's own path is never visible in the
# output. It still has to live under the right module prefix when the package
# imports `internal` packages, which is why we try to infer the real path
# below.
_FALLBACK_IMPORT_PATH = "bazelgowire.invalid/input"

def _infer_import_path(ctx, packages):
    """Infers the Go import path of the package being generated.

    The package is specified as raw files, so Bazel has no `GoInfo` from which
    to read the import path. In repositories where the Bazel package layout
    mirrors the Go import layout (the Gazelle convention), the import path of
    any same-repository dependency determines the module prefix:

        importpath(tool/internal/a) == prefix + "tool/internal/a"

    Applying that prefix to this rule's Bazel package gives a path that is
    under the same module root. That is what `go` checks when allowing
    imports of `internal` packages. The exact value does not matter otherwise.
    """
    if ctx.attr.importpath:
        return ctx.attr.importpath

    prefix = ctx.label.package
    candidates = {}
    for dep in ctx.attr.deps:
        for archive in dep[GoArchive].transitive.to_list():
            label = archive.label
            if label.workspace_root or label.repo_name:
                # Only packages from the main repository follow this
                # workspace's Bazel package layout.
                continue
            package = label.package
            if not package:
                continue
            importpath = archive.importmap or archive.importpath
            if not importpath.endswith("/" + package):
                continue
            module_prefix = importpath[:-len(package)]
            candidate = (module_prefix + prefix).rstrip("/")
            if not candidate or candidate in packages:
                continue
            candidates[candidate] = True

    if len(candidates) == 1:
        return list(candidates.keys())[0]
    return _FALLBACK_IMPORT_PATH

def _collect_dependency_sources(ctx):
    """Returns {importpath: {"srcs": {path: File}, "embedsrcs": {path: File}}}.

    The source files of every transitive dependency are needed because Wire
    type-checks the whole provider graph from source.
    """
    packages = {}
    for dep in ctx.attr.deps:
        for archive in dep[GoArchive].transitive.to_list():
            importpath = archive.importmap or archive.importpath
            if not importpath:
                # Synthetic archives (for example testmain) have no sources
                # that can be laid out in a GOPATH.
                continue
            if getattr(archive, "_cgo", False):
                fail(
                    "{}: dependency {} uses cgo, which gowire does not support yet".format(
                        ctx.label,
                        importpath,
                    ),
                )
            package = packages.get(importpath)
            if package == None:
                package = {"srcs": {}, "embedsrcs": {}}
                packages[importpath] = package
            for src in archive.srcs:
                if src.extension == "go":
                    package["srcs"][src.path] = src
            for src in getattr(archive, "_embedsrcs", ()):
                package["embedsrcs"][src.path] = src
    return packages

def _copy_commands(dest_dir, files):
    commands = ["mkdir -p " + shell.quote(dest_dir)]
    for path in sorted(files.keys()):
        commands.append(
            "cp -fL {} {}".format(
                shell.quote(files[path].path),
                shell.quote(dest_dir + "/"),
            ),
        )
    return commands

def _wire_impl(ctx):
    go = go_context(ctx, include_deprecated_properties = False)
    sdk = go.sdk

    if ctx.outputs.out.basename in [src.basename for src in ctx.files.srcs]:
        fail(
            "{}: output file {} is also listed in srcs; remove the checked-in " +
            "wire_gen.go from srcs".format(ctx.label, ctx.outputs.out.basename),
        )

    packages = _collect_dependency_sources(ctx)
    import_path = _infer_import_path(ctx, packages)

    input_files = list(ctx.files.srcs)
    for importpath in sorted(packages.keys()):
        package = packages[importpath]
        input_files.extend(package["srcs"].values())
        input_files.extend(package["embedsrcs"].values())
    if ctx.file.header_file:
        input_files.append(ctx.file.header_file)

    gopath = "gowire_gopath"
    lines = [
        "set -e",
        'EXEC_ROOT="$(pwd)"',
        'export GOPATH="$EXEC_ROOT/' + gopath + '"',
        'export GOCACHE="$EXEC_ROOT/.gowire_cache"',
        'export TMPDIR="$EXEC_ROOT/.gowire_tmp"',
        'export HOME="$EXEC_ROOT/.gowire_home"',
        # The Go SDK shipped by rules_go is laid out at this path in the
        # sandbox; `go list` is invoked by Wire through go/packages.
        'export GOROOT="$EXEC_ROOT/' + sdk.root_file.dirname + '"',
        'export PATH="$EXEC_ROOT/' + sdk.go.dirname + ':${PATH:-}"',
        'export WIRE="$EXEC_ROOT/' + ctx.executable.wire_tool.path + '"',
        'mkdir -p "$GOPATH" "$GOCACHE" "$TMPDIR" "$HOME"',
    ]

    # Transitive dependencies, at the import paths used by the source.
    for importpath in sorted(packages.keys()):
        package = packages[importpath]
        dest_dir = paths.join(gopath, "src", importpath)
        lines.extend(_copy_commands(dest_dir, package["srcs"]))
        lines.extend(_copy_commands(dest_dir, package["embedsrcs"]))

    # The package whose injectors are being generated.
    current_dir = paths.join(gopath, "src", import_path)
    current_srcs = {src.path: src for src in ctx.files.srcs}
    lines.extend(_copy_commands(current_dir, current_srcs))

    wire_args = ["gen"]
    if ctx.file.header_file:
        wire_args.extend(["-header_file", '"$EXEC_ROOT/' + ctx.file.header_file.path + '"'])
    if ctx.attr.wire_tags:
        wire_args.extend(["-tags", shell.quote(" ".join(ctx.attr.wire_tags))])
    wire_args.append(".")

    lines.append('cd "$GOPATH/src/' + import_path + '"')
    lines.append('"$WIRE" ' + " ".join(wire_args))
    lines.extend([
        "if [ ! -f wire_gen.go ]; then",
        '  echo "GoWireGen: Wire produced no output for ' + str(ctx.label) +
        '; the package must contain an injector and be buildable with the wireinject tag" >&2',
        "  exit 1",
        "fi",
        'mkdir -p "$(dirname "$EXEC_ROOT/' + ctx.outputs.out.path + '")"',
        'cp -f wire_gen.go "$EXEC_ROOT/' + ctx.outputs.out.path + '"',
    ])

    env = {key: value for key, value in go.env.items()}
    env.update({
        # Wire always adds the `wireinject` tag itself. GOPATH mode keeps the
        # action self-contained: no go.mod resolution, no module cache.
        "GO111MODULE": "off",
        "GOENV": "off",
        "GOWORK": "off",
        "GOPROXY": "off",
        "GOFLAGS": "",
        "GOTOOLCHAIN": "local",
        "GOTELEMETRY": "off",
        "CGO_ENABLED": "0",
    })

    ctx.actions.run_shell(
        outputs = [ctx.outputs.out],
        inputs = depset(
            direct = input_files,
            transitive = [sdk.srcs, sdk.headers, sdk.tools],
        ),
        tools = [ctx.executable.wire_tool, sdk.go],
        command = "\n".join(lines),
        env = env,
        mnemonic = "GoWireGen",
        progress_message = "Generating Wire code for %{label}",
    )

    return [DefaultInfo(files = depset([ctx.outputs.out]))]

_wire = rule(
    implementation = _wire_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".go"],
            mandatory = True,
            doc = "Go source files of the package, including the injector file " +
                  "guarded by `//go:build wireinject`.",
        ),
        "deps": attr.label_list(
            providers = [GoArchive],
            doc = "Go libraries imported by `srcs`. The transitive sources of " +
                  "these libraries are made available to Wire.",
        ),
        "out": attr.output(
            mandatory = True,
            doc = "Generated Go file.",
        ),
        "importpath": attr.string(
            doc = "Import path of the package under generation. Only needed " +
                  "when it cannot be inferred from the Bazel package layout, " +
                  "for example when the package imports `internal` packages " +
                  "and the repository does not mirror Go paths in Bazel paths.",
        ),
        "header_file": attr.label(
            allow_single_file = True,
            doc = "File inserted at the top of the generated file, passed to " +
                  "`wire gen -header_file`.",
        ),
        "wire_tags": attr.string_list(
            doc = "Extra build tags for loading packages with Wire, passed to " +
                  "`wire gen -tags`. `wireinject` is added automatically.",
        ),
        "wire_tool": attr.label(
            default = _DEFAULT_WIRE_TOOL,
            executable = True,
            cfg = "exec",
            doc = "The `wire` command to run. Defaults to the CLI built from " +
                  "`@com_github_google_wire//cmd/wire`.",
        ),
        "_go_context_data": attr.label(
            default = Label("@rules_go//:go_context_data"),
        ),
    },
    toolchains = [_GO_TOOLCHAIN],
)

def wire(name, srcs, deps = [], out = "wire_gen.go", header_file = None, importpath = "", wire_tags = [], wire_tool = None, **kwargs):
    """Generates `wire_gen.go` from the injectors declared in `srcs`.

    The generated file is exposed as the default output of this target, so it
    can be listed directly in `go_binary.srcs` / `go_library.srcs`:

    ```starlark
    gowire(
        name = "wire",
        srcs = ["wire.go"],
        deps = [
            "//internal/server",
            "@com_github_google_wire//wire",
        ],
    )

    go_binary(
        name = "app",
        srcs = ["main.go", ":wire"],
        deps = [
            "//internal/server",
            "@com_github_google_wire//wire",
        ],
    )
    ```

    Args:
        name: the target name.
        srcs: Go source files of the package, including the file with the
            `wireinject` build tag. A checked-in `wire_gen.go` must not be
            listed.
        deps: Go libraries imported by `srcs`.
        out: name of the generated Go file. Must be a file name in the current
            Bazel package, not a path.
        header_file: optional file inserted at the top of the generated file.
        importpath: import path of the package under generation. Usually
            inferred from the Bazel package layout; set it explicitly if the
            package imports `internal` packages and inference picks the wrong
            module prefix.
        wire_tags: additional build tags passed to `wire gen -tags`.
        wire_tool: optional override for the Wire executable.
        **kwargs: common attributes such as `visibility` and `testonly`.
    """
    if not out.endswith(".go"):
        fail("gowire: out must end in .go, got {}".format(out))
    if "/" in out or "\\" in out:
        fail("gowire: out must be a file in the current package, got {}".format(out))
    if wire_tool == None:
        wire_tool = _DEFAULT_WIRE_TOOL
    _wire(
        name = name,
        srcs = srcs,
        deps = deps,
        out = out,
        header_file = header_file,
        importpath = importpath,
        wire_tags = wire_tags,
        wire_tool = wire_tool,
        **kwargs
    )
