cmake_minimum_required(VERSION 3.24)
project(AetherUnzip VERSION 0.1.0 LANGUAGES C CXX)

option(AETHER_UNZIP_BUILD_CLI "Build the plain C example" ON)
option(AETHER_UNZIP_BUILD_TESTS "Build the Core tests" ON)

if(NOT UNIX)
    message(FATAL_ERROR "Core currently requires a POSIX filesystem implementation")
endif()

include(cmake/Dependencies.cmake)
add_subdirectory(core)

if(AETHER_UNZIP_BUILD_CLI)
    add_executable(aether-unzip examples/cli/main.c)
    target_link_libraries(aether-unzip PRIVATE aetherunzip)
endif()

if(AETHER_UNZIP_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
