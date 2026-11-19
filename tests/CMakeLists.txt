add_executable(aetherunzip_tests core_tests.c)
target_link_libraries(aetherunzip_tests PRIVATE aetherunzip)
target_compile_features(aetherunzip_tests PRIVATE c_std_17)
foreach(group IN ITEMS io formats security password resource profile)
    add_test(NAME core.${group} COMMAND aetherunzip_tests "${group}")
    set_tests_properties(core.${group} PROPERTIES WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
endforeach()

if(TARGET aether-unzip)
    add_test(NAME cli.verify COMMAND "${CMAKE_COMMAND}"
        "-DCLI=$<TARGET_FILE:aether-unzip>"
        "-DFIXTURES=${CMAKE_CURRENT_SOURCE_DIR}/fixtures"
        "-DSCRATCH=${CMAKE_CURRENT_BINARY_DIR}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/cli_tests.cmake")
endif()
