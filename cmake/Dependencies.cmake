include(FetchContent)

set(aether_source_pins "${CMAKE_CURRENT_LIST_DIR}/source-archives.tsv")
set(aether_source_archives "${CMAKE_CURRENT_LIST_DIR}/../third_party/source-archives")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${aether_source_pins}")
file(STRINGS "${aether_source_pins}" aether_source_rows REGEX "^[a-z0-9]+	")
foreach(row IN LISTS aether_source_rows)
    string(REPLACE "	" ";" fields "${row}")
    list(GET fields 0 dependency)
    list(GET fields 1 filename)
    list(GET fields 2 url)
    list(GET fields 3 sha256)
    if(IS_DIRECTORY "${aether_source_archives}")
        set(url "${aether_source_archives}/${filename}")
        if(NOT EXISTS "${url}")
            message(FATAL_ERROR "Missing bundled source archive: ${filename}")
        endif()
    endif()
    set("aether_${dependency}_url" "${url}")
    set("aether_${dependency}_sha256" "${sha256}")
endforeach()
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
    URL "${aether_xz_url}"
    URL_HASH "SHA256=${aether_xz_sha256}")
FetchContent_Declare(lz4
    URL "${aether_lz4_url}"
    URL_HASH "SHA256=${aether_lz4_sha256}"
    SOURCE_SUBDIR build/cmake)
FetchContent_Declare(zstd
    URL "${aether_zstd_url}"
    URL_HASH "SHA256=${aether_zstd_sha256}"
    SOURCE_SUBDIR build/cmake)
FetchContent_MakeAvailable(xz lz4 zstd)

set(BROTLI_BUNDLED_MODE ON)
set(BROTLI_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
FetchContent_Declare(brotli
    URL "${aether_brotli_url}"
    URL_HASH "SHA256=${aether_brotli_sha256}")
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
foreach(patch IN ITEMS libarchive-split-zip.patch libarchive-gzip-trailer.patch
    libarchive-7z-aes.patch libarchive-rar5-aes.patch)
    set(patch_path "${CMAKE_CURRENT_LIST_DIR}/patches/${patch}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${patch_path}")
    file(SHA256 "${patch_path}" patch_hash)
    string(APPEND libarchive_patch_hashes "${patch_hash}")
endforeach()
string(SHA256 libarchive_patch_set "${libarchive_patch_hashes}")
string(SUBSTRING "${libarchive_patch_set}" 0 12 libarchive_patch_set)
FetchContent_Declare(libarchive
    URL "${aether_libarchive_url}"
    URL_HASH "SHA256=${aether_libarchive_sha256}"
    SOURCE_DIR "${FETCHCONTENT_BASE_DIR}/libarchive-${libarchive_patch_set}-src"
    PATCH_COMMAND "${CMAKE_COMMAND}"
        "-DPATCH_PROGRAM=${AETHER_UNZIP_PATCH_PROGRAM}"
        "-DPATCH_DIRECTORY=${CMAKE_CURRENT_LIST_DIR}/patches"
        -P "${CMAKE_CURRENT_LIST_DIR}/ApplyLibarchivePatch.cmake")
FetchContent_MakeAvailable(libarchive)
