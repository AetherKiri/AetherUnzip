cmake_minimum_required(VERSION 3.24)
project(AetherUnzip VERSION 0.1.0 LANGUAGES C CXX)

option(AETHER_UNZIP_BUILD_CLI "Build the C archive verification CLI" ON)
option(AETHER_UNZIP_BUILD_TESTS "Build the Core tests" ON)

if(NOT UNIX)
    message(FATAL_ERROR "Core currently requires a POSIX filesystem implementation")
endif()

include(cmake/Dependencies.cmake)
add_subdirectory(core)

if(AETHER_UNZIP_BUILD_CLI)
    add_executable(aether-unzip examples/cli/main.c)
    target_link_libraries(aether-unzip PRIVATE aetherunzip)
    target_compile_features(aether-unzip PRIVATE c_std_17)
endif()

if(AETHER_UNZIP_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
