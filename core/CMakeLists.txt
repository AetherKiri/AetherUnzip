add_library(aetherunzip STATIC
    src/runtime.c src/io.c src/archive.c src/resource.c src/security.c src/extract.c
    ../modules/archive/libarchive/driver.c
    ../modules/archive/libarchive/write_archive.c
    ../modules/codecs/brotli.c
    ../modules/game_formats/xp3/driver.c
    ../modules/profiles/profile.c)
target_compile_features(aetherunzip PUBLIC c_std_17 PRIVATE cxx_std_17)
set_target_properties(aetherunzip PROPERTIES C_EXTENSIONS OFF POSITION_INDEPENDENT_CODE ON)
target_compile_definitions(aetherunzip PRIVATE _POSIX_C_SOURCE=200809L _FILE_OFFSET_BITS=64
    $<$<PLATFORM_ID:Darwin,iOS>:_DARWIN_C_SOURCE>)
target_include_directories(aetherunzip PUBLIC include PRIVATE src "${libarchive_SOURCE_DIR}/libarchive")
target_link_libraries(aetherunzip PRIVATE archive_static brotlidec ZLIB::ZLIB)
if(CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(aetherunzip PRIVATE -Wall -Wextra -Wpedantic)
endif()
