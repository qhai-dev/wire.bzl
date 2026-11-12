"""Analysis tests for the wire_gen rule."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _output_is_wire_gen_go_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    asserts.equals(env, "wire_gen.go", files[0].basename)
    return analysistest.end(env)

output_is_wire_gen_go_test = analysistest.make(_output_is_wire_gen_go_impl)

def _uninferable_importpath_fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "cannot infer importpath")
    return analysistest.end(env)

uninferable_importpath_fails_test = analysistest.make(
    _uninferable_importpath_fails_impl,
    expect_failure = True,
)

def _ambiguous_importpath_fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "ambiguous importpath")
    return analysistest.end(env)

ambiguous_importpath_fails_test = analysistest.make(
    _ambiguous_importpath_fails_impl,
    expect_failure = True,
)
