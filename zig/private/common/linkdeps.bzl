"""Handle prebuilt library dependencies."""

def zig_linkdeps(*, linkdeps, inputs, args):
    """Handle prebuilt library dependencies.

    Sets the appropriate command-line flags for the Zig compiler to link
    against the provided libraries.

    Args:
      linkdeps: List of Target, Must provide `CcInfo`.
      inputs: List of File; mutable, Append the needed inputs to this list.
      args: Args; mutable, Append the Zig command-line flags to this object.
    """
    cc_info = cc_common.merge_cc_infos(direct_cc_infos = [cdep[CcInfo] for cdep in linkdeps])
    for link in cc_info.linking_context.linker_inputs.to_list():
        args.add_all(link.user_link_flags)
        inputs.extend(link.additional_inputs)
        for lib in link.libraries:
            file = None
            if lib.static_library != None:
                file = lib.static_library
            elif lib.pic_static_library != None:
                file = lib.pic_static_library
            elif lib.interface_library != None:
                file = lib.interface_library
            elif lib.dynamic_library != None:
                file = lib.dynamic_library

            # TODO[AH] Handle the remaining fields of LibraryToLink as needed:
            #   alwayslink
            #   lto_bitcode_files
            #   objects
            #   pic_lto_bitcode_files
            #   pic_objects
            #   resolved_symlink_dynamic_library
            #   resolved_symlink_interface_library

            if file:
                inputs.append(file)
                args.add(file)
