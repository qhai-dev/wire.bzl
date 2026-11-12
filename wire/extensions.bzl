"""Module extension for registering Wire toolchains.

The repository ships a default toolchain (see `wire/BUILD.bazel`), so this
extension is only needed to override it: a different Wire version, a custom
`go_deps` repository name, or a locally patched Wire.

    wire = use_extension("@wire.bzl//wire:extensions.bzl", "wire")
    wire.toolchain(wire = "@com_github_google_wire//cmd/wire:wire")
    use_repo(wire, "wire_bzl_toolchains")
    register_toolchains("@wire_bzl_toolchains//:all")

Two details make the generated repository work:

* `str(Label(...))` is evaluated in this file's own module, so it yields the
  canonical label of `toolchain.bzl` and the toolchain type. A generated
  repository cannot see other modules by their apparent names, so canonical
  labels are required in its BUILD file.
* Tag attributes of type `attr.label` are resolved by Bazel in the context of
  the module that declared the tag. `str(tag.wire)` therefore already carries
  the canonical repository name of the user's Wire target.
"""

_TOOLCHAIN_BZL = str(Label("//wire:toolchain.bzl"))
_TOOLCHAIN_TYPE = str(Label("//wire:wire_toolchain_type"))

_TOOLCHAINS_REPO = "wire_bzl_toolchains"

def _toolchains_repo_impl(rctx):
    rctx.file("BUILD.bazel", rctx.attr.build_content)
    rctx.file("WORKSPACE", "")

_toolchains_repo = repository_rule(
    implementation = _toolchains_repo_impl,
    attrs = {
        "build_content": attr.string(mandatory = True),
    },
)

def _format_constraints(values):
    return "[" + ", ".join(['"{}"'.format(v) for v in values]) + "]"

def _wire_ext_impl(module_ctx):
    # Root module registrations must win toolchain resolution. Bazel expands
    # `//:all` in lexicographic order and resolves toolchains in registration
    # order, so a zero-padded index prefix makes the order deterministic.
    entries = []
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            entries.append(struct(
                is_root = mod.is_root,
                name = tag.name,
                wire = str(tag.wire),
                exec_compatible_with = [str(v) for v in tag.exec_compatible_with],
                target_compatible_with = [str(v) for v in tag.target_compatible_with],
            ))

    entries = sorted(entries, key = lambda e: not e.is_root)

    seen = {}
    blocks = []
    for index, entry in enumerate(entries):
        if entry.name in seen:
            fail(
                "Duplicate Wire toolchain name '{}'. Give each wire.toolchain() " +
                "tag a distinct `name`.".format(entry.name),
            )
        seen[entry.name] = True

        # Index prefix keeps `:all` expansion order aligned with priority.
        # Starlark's format() has no width/padding specifiers, so pad manually.
        index_str = str(index)
        if index < 10:
            index_str = "0" + index_str
        target_name = "tc_" + index_str + "_" + entry.name
        impl_name = target_name + "_impl"
        blocks.append(
            "\n".join([
                "wire_toolchain(",
                '    name = "{}",'.format(impl_name),
                '    wire = "{}",'.format(entry.wire),
                ")",
                "",
                "toolchain(",
                '    name = "{}",'.format(target_name),
                '    toolchain = ":{}",'.format(impl_name),
                '    toolchain_type = "{}",'.format(_TOOLCHAIN_TYPE),
                "    exec_compatible_with = {},".format(
                    _format_constraints(entry.exec_compatible_with),
                ),
                "    target_compatible_with = {},".format(
                    _format_constraints(entry.target_compatible_with),
                ),
                ")",
            ]),
        )

    content = "\n".join([
        'load("{}", "wire_toolchain")'.format(_TOOLCHAIN_BZL),
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
        "\n\n".join(blocks),
        "",
    ])

    _toolchains_repo(
        name = _TOOLCHAINS_REPO,
        build_content = content,
    )

wire = module_extension(
    implementation = _wire_ext_impl,
    tag_classes = {
        "toolchain": tag_class(attrs = {
            "wire": attr.label(
                mandatory = True,
                doc = "The `cmd/wire` build target, e.g. " +
                      "`@com_github_google_wire//cmd/wire:wire`.",
            ),
            "name": attr.string(
                default = "wire",
                doc = "Unique name for this toolchain registration.",
            ),
            "exec_compatible_with": attr.label_list(
                doc = "Execution platform constraints for this toolchain.",
            ),
            "target_compatible_with": attr.label_list(
                doc = "Target platform constraints for this toolchain.",
            ),
        }),
    },
    doc = "Registers Wire toolchains that override the built-in default.",
)
