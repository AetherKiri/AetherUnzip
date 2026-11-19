include(FetchContent)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF)
set(XZ_NLS OFF)
set(XZ_DOC OFF)
set(XZ_TOOL_XZ OFF)
set(XZ_TOOL_XZDEC OFF)
set(XZ_TOOL_LZMADEC OFF)
set(XZ_TOOL_LZMAINFO OFF)
set(XZ_EXTERNAL_SHA256 OFF)
set(XZ_THREADS no CACHE STRING "" FORCE)
set(LZ4_BUILD_CLI OFF CACHE BOOL "" FORCE)
set(LZ4_BUILD_LEGACY_LZ4C OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_SHARED OFF)
set(ZSTD_BUILD_PROGRAMS OFF)
set(ZSTD_BUILD_TESTS OFF)
set(ZSTD_LEGACY_SUPPORT OFF)
set(ZSTD_MULTITHREAD_SUPPORT OFF)

FetchContent_Declare(xz
    URL https://codeload.github.com/tukaani-project/xz/tar.gz/refs/tags/v5.8.2
    URL_HASH SHA256=f21fdf2c1ee004de30ca40377a273e3369186e6b7ab7b50a410eaa2e2bbefafb)
FetchContent_Declare(lz4
    URL https://codeload.github.com/lz4/lz4/tar.gz/refs/tags/v1.10.0
    URL_HASH SHA256=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
    SOURCE_SUBDIR build/cmake)
FetchContent_Declare(zstd
    URL https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7
    URL_HASH SHA256=37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3
    SOURCE_SUBDIR build/cmake)
FetchContent_MakeAvailable(xz lz4 zstd)

set(BROTLI_BUNDLED_MODE ON)
set(BROTLI_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
FetchContent_Declare(brotli
    URL https://codeload.github.com/google/brotli/tar.gz/refs/tags/v1.2.1
    URL_HASH SHA256=98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f)
FetchContent_MakeAvailable(brotli)
set_target_properties(brotlienc PROPERTIES EXCLUDE_FROM_ALL TRUE)

# libarchive checks installed libraries by linking configure-time probes. The
# following targets are built in this same graph, so their APIs are known from
# the pinned sources and cannot be linked until build time.
configure_file("${CMAKE_CURRENT_LIST_DIR}/LibLZMAConfig.cmake"
    "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}/LibLZMAConfig.cmake" COPYONLY)
set(LZ4_INCLUDE_DIR "${lz4_SOURCE_DIR}/lib")
set(LZ4_LIBRARY lz4_static)
set(ZSTD_INCLUDE_DIR "${zstd_SOURCE_DIR}/lib")
set(ZSTD_LIBRARY libzstd_static)
set(HAVE_LIBZSTD 1)
set(HAVE_ZSTD_compressStream 1)
set(HAVE_ZSTD_minCLevel 1)

foreach(feature IN ITEMS ZLIB LZMA LZ4 ZSTD BZip2 ICONV)
    set(ENABLE_${feature} ON CACHE BOOL "" FORCE)
endforeach()
foreach(feature IN ITEMS MD LIBB2 LIBXML2 BSDXML EXPAT WIN32_XMLLITE
    PCREPOSIX PCRE2POSIX TAR CPIO CAT UNZIP XATTR ACL TEST INSTALL WERROR)
    set(ENABLE_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
if(APPLE)
    set(ENABLE_OPENSSL OFF CACHE BOOL "" FORCE)
else()
    find_package(OpenSSL REQUIRED COMPONENTS Crypto)
    set(ENABLE_OPENSSL ON CACHE BOOL "" FORCE)
endif()
find_package(ZLIB 1.2.1 REQUIRED)
find_package(BZip2 REQUIRED)
find_program(AETHER_UNZIP_PATCH_PROGRAM patch REQUIRED)
# A changed patch set needs a fresh copy of the original upstream source.
set(libarchive_patch_hashes "")
foreach(patch IN ITEMS libarchive-split-zip.patch libarchive-gzip-trailer.patch libarchive-7z-aes.patch)
    set(patch_path "${CMAKE_CURRENT_LIST_DIR}/patches/${patch}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${patch_path}")
    file(SHA256 "${patch_path}" patch_hash)
    string(APPEND libarchive_patch_hashes "${patch_hash}")
endforeach()
string(SHA256 libarchive_patch_set "${libarchive_patch_hashes}")
string(SUBSTRING "${libarchive_patch_set}" 0 12 libarchive_patch_set)
FetchContent_Declare(libarchive
    URL https://www.libarchive.org/downloads/libarchive-3.8.11.tar.xz
    URL_HASH SHA256=a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2
    SOURCE_DIR "${FETCHCONTENT_BASE_DIR}/libarchive-${libarchive_patch_set}-src"
    PATCH_COMMAND "${CMAKE_COMMAND}"
        "-DPATCH_PROGRAM=${AETHER_UNZIP_PATCH_PROGRAM}"
        "-DPATCH_DIRECTORY=${CMAKE_CURRENT_LIST_DIR}/patches"
        -P "${CMAKE_CURRENT_LIST_DIR}/ApplyLibarchivePatch.cmake")
FetchContent_MakeAvailable(libarchive)
