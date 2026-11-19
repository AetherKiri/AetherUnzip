foreach(patch IN ITEMS libarchive-split-zip.patch libarchive-gzip-trailer.patch)
    set(patch_file "${PATCH_DIRECTORY}/${patch}")
    # FetchContent can revisit the patch step for an existing source tree.
    execute_process(
        COMMAND "${PATCH_PROGRAM}" --dry-run -R -f -p1 -F0 -i "${patch_file}"
        RESULT_VARIABLE already_applied
        OUTPUT_QUIET ERROR_QUIET)
    if(NOT already_applied EQUAL 0)
        execute_process(
            COMMAND "${PATCH_PROGRAM}" -f -p1 -F0 -i "${patch_file}"
            COMMAND_ERROR_IS_FATAL ANY)
    endif()
endforeach()
