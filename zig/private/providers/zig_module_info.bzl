"""Defines providers for the zig_module rule."""

DOC = """\
Information about a Zig module.

A Zig module is a collection of Zig sources
with a main file that serves as an entry point.

Zig modules are not pre-compiled,
instead the Zig compiler performs whole program compilation.
"""

FIELDS = {
    "name": "string, The import name of the module.",
    "canonical_name": "string, The canonical name may differ from the import name via remapping.",
    "main": "File, The main source file of the module.",
    "srcs": "list of File, Other Zig source files that belong to the module.",
    "extra_srcs": "list of File, Other files that belong to the module.",
    "copts": "list of string, Extra compiler options for the module.",
    "linkopts": "list of string, Extra linker options for the module.",
    "deps": "list of ZigModuleInfo, Import dependencies of this module.",
    "cdeps": "CcInfo, All C dependencies required when depending on the module, including transitive dependencies.",
    "transitive_deps": "depset of ZigModuleInfo, All dependencies required when depending on the module, including transitive dependencies.",
}

ZigModuleInfo = provider(
    fields = FIELDS,
    doc = DOC,
)

def zig_module_info(*, name, canonical_name, main, srcs, extra_srcs, copts, linkopts, deps, cdeps):
    module = ZigModuleInfo(
        name = name,
        canonical_name = canonical_name or name,
        main = main,
        srcs = tuple(srcs),
        extra_srcs = tuple(extra_srcs),
        copts = tuple(copts),
        linkopts = tuple(linkopts),
        deps = tuple(deps),
        cdeps = tuple(cdeps),
        transitive_deps = depset(direct = deps, transitive = [dep.transitive_deps for dep in deps], order = "postorder"),
    )

    return module

def _render_dep(dep):
    return dep.name + "=" + dep.canonical_name

def zig_module_render_args(*, module, inputs, cc_infos, args):
    args.add_all(module.deps, before_each = "--dep", map_each = _render_dep)
    args.add_all(module.copts)

    cc_info = cc_common.merge_cc_infos(direct_cc_infos = module.cdeps)
    cc_infos.append(cc_info)
    compilation_context = cc_info.compilation_context
    inputs.append(compilation_context.headers)
    args.add_all(compilation_context.defines, format_each = "-D%s")
    args.add_all(compilation_context.includes, format_each = "-I%s")

    # Note, Zig does not support `-iquote` as of Zig 0.11.0
    # args.add_all(compilation_context.quote_includes, format_each = "-iquote%s")
    args.add_all(compilation_context.quote_includes, format_each = "-I%s")
    args.add_all(compilation_context.system_includes, before_each = "-isystem")
    if hasattr(compilation_context, "external_includes"):
        # Added in Bazel 7, see https://github.com/bazelbuild/bazel/commit/a6ef0b341a8ffe8ab27e5ace79d8eaae158c422b
        args.add_all(compilation_context.external_includes, before_each = "-isystem")
    args.add_all(compilation_context.framework_includes, format_each = "-F%s")

    args.add(module.main, format = "-M{}=%s".format(module.canonical_name))
    inputs.append(depset(direct = tuple((module.main,)) + module.srcs + module.extra_srcs))

def zig_module_specifications(*, root_module, inputs, cc_infos, args):
    zig_module_render_args(
        module = root_module,
        inputs = inputs,
        cc_infos = cc_infos,
        args = args,
    )
    for dep in root_module.transitive_deps.to_list():
        zig_module_render_args(
            module = dep,
            inputs = inputs,
            cc_infos = cc_infos,
            args = args,
        )
