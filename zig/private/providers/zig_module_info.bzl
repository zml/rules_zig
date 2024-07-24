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
    "transitive_cdeps": "depset of CcInfo, All dependencies required when depending on the module, including transitive dependencies.",
}

ZigModuleInfo = provider(
    fields = FIELDS,
    doc = DOC,
)

def zig_module_info(*, name, canonical_name, main, srcs = [], extra_srcs = [], copts = [], linkopts = [], deps = [], cdeps = []):
    module = ZigModuleInfo(
        name = name,
        canonical_name = canonical_name,
        main = main,
        srcs = tuple(srcs),
        extra_srcs = tuple(extra_srcs),
        copts = tuple(copts),
        linkopts = tuple(linkopts),
        deps = tuple(deps),
        cdeps = tuple(cdeps),
        transitive_deps = depset(direct = deps, transitive = [dep.transitive_deps for dep in deps], order = "postorder"),
        transitive_cdeps = depset(direct = tuple(cdeps), transitive = [dep.transitive_cdeps for dep in deps]),
    )

    return module

def _render_dep(dep):
    return dep.name + "=" + dep.canonical_name

def add_module_files(inputs, module):
    inputs.append(depset(direct = tuple((module.main,)) + module.srcs + module.extra_srcs))

def zig_module_render_args(*, module, inputs, c_module, args):
    args.add_all(module.deps, before_each = "--dep", map_each = _render_dep)
    if module.cdeps:
        args.add("--dep", _render_dep(c_module))
    args.add_all(module.copts)

    args.add(module.main, format = "-M{}=%s".format(module.canonical_name))
    add_module_files(inputs, module)

def zig_module_specifications(*, root_module, inputs, c_module, args):
    need_c_module = (len(root_module.cdeps) > 0)
    zig_module_render_args(
        module = root_module,
        inputs = inputs,
        c_module = c_module,
        args = args,
    )
    for dep in root_module.transitive_deps.to_list():
        need_c_module = need_c_module or (len(dep.cdeps) > 0)
        zig_module_render_args(
            module = dep,
            inputs = inputs,
            c_module = c_module,
            args = args,
        )
    if (need_c_module):
        zig_module_render_args(
            module = c_module,
            inputs = inputs,
            c_module = None,
            args = args,
        )
