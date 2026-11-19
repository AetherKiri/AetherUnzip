cmake_minimum_required(VERSION 3.24)

string(RANDOM LENGTH 12 suffix)
set(work "${SCRATCH}/cli-${suffix}")
file(MAKE_DIRECTORY "${work}/output")
file(WRITE "${work}/correct" "fixture-pass\n")
file(WRITE "${work}/incorrect" "wrong-password\n")

function(run_cli expected)
    cmake_parse_arguments(PARSE_ARGV 1 RUN "" "INPUT;OUTPUT_MATCH;ERROR_MATCH" "ARGS")
    set(stdin)
    if(DEFINED RUN_INPUT)
        set(stdin INPUT_FILE "${work}/${RUN_INPUT}")
    endif()
    execute_process(COMMAND "${CLI}" ${RUN_ARGS} ${stdin}
        RESULT_VARIABLE code OUTPUT_VARIABLE output ERROR_VARIABLE error)
    if(NOT "${code}" STREQUAL "${expected}" OR
       (DEFINED RUN_OUTPUT_MATCH AND NOT output MATCHES "${RUN_OUTPUT_MATCH}") OR
       (DEFINED RUN_ERROR_MATCH AND NOT error MATCHES "${RUN_ERROR_MATCH}"))
        message(FATAL_ERROR "CLI ${RUN_ARGS}\nExit: ${code}\n${output}${error}")
    endif()
endfunction()

run_cli(0 ARGS --probe "${FIXTURES}/sample.tar.gz"
    OUTPUT_MATCH "format=TAR\nfilter=GZIP\nkind=container")
run_cli(0 ARGS --cat "${FIXTURES}/sample.zip" "docs/readme.txt"
    OUTPUT_MATCH "^Nested document\n$")
run_cli(0 ARGS --ls "${FIXTURES}/sample.zip" docs
    OUTPUT_MATCH "readme[.]txt")
run_cli(0 ARGS "${FIXTURES}/rar5-aes-solid.rar"
    OUTPUT_MATCH "2 +120409 +third[.]txt [[]encrypted[]]")

set(encrypted "${FIXTURES}/rar5-aes-solid-header.rar")
run_cli(0 INPUT correct ARGS --verify --entry 2 --password-stdin "${encrypted}"
    OUTPUT_MATCH "verified_files=1\nverified_bytes=120409")
run_cli(1 INPUT incorrect ARGS --verify --password-stdin "${encrypted}"
    ERROR_MATCH "status=-13")
run_cli(1 INPUT correct ARGS --verify --entry 2 --max-total-bytes 300000 --password-stdin "${encrypted}"
    ERROR_MATCH "status=-8")
run_cli(0 INPUT correct ARGS --entry 2 --password-stdin "${encrypted}" "${work}/output")
file(GLOB extracted RELATIVE "${work}/output" "${work}/output/*")
if(NOT extracted STREQUAL "third.txt")
    message(FATAL_ERROR "Unexpected extracted paths: ${extracted}")
endif()
file(SIZE "${work}/output/third.txt" length)
file(READ "${work}/output/third.txt" ending OFFSET 120400 LIMIT 9)
if(NOT length EQUAL 120409 OR NOT ending STREQUAL "tertiary\n")
    message(FATAL_ERROR "Unexpected output from selected extraction")
endif()

run_cli(1 ARGS --verify "${FIXTURES}/gzip-crc.gz" ERROR_MATCH "status=-5")
run_cli(1 ARGS --verify --entry 999 "${FIXTURES}/sample.zip" ERROR_MATCH "status=-11")
run_cli(2 ARGS --verify --entry 2 --entry 1 "${FIXTURES}/sample.zip" ERROR_MATCH "Usage:")
run_cli(0 ARGS --verify --volume "${FIXTURES}/volumes/sample.7z.002"
    --volume "${FIXTURES}/volumes/sample.7z.003" "${FIXTURES}/volumes/sample.7z.001"
    OUTPUT_MATCH "verified_files=[1-9][0-9]*")
file(REMOVE_RECURSE "${work}")
