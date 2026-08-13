cmake_minimum_required(VERSION 3.25)
project(godbrain_polygon_searcher VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(polygon_searcher_core
    src/core.cpp
    src/repository.cpp
)
target_include_directories(polygon_searcher_core
    PUBLIC include
    PRIVATE ../cpp_kernel
)
target_compile_definitions(
    polygon_searcher_core
    PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS
)

add_executable(polygon-searcher-replay src/replay.cpp)
target_link_libraries(polygon-searcher-replay PRIVATE polygon_searcher_core)
target_include_directories(polygon-searcher-replay PRIVATE ../cpp_kernel)
target_compile_definitions(
    polygon-searcher-replay
    PRIVATE POLYGON_SEARCHER_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
)

function(enable_strict_warnings target)
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX /permissive- /EHsc)
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
endfunction()

enable_strict_warnings(polygon_searcher_core)
enable_strict_warnings(polygon-searcher-replay)

include(CTest)
if(BUILD_TESTING)
    add_executable(polygon_searcher_tests tests/tests.cpp)
    target_link_libraries(polygon_searcher_tests PRIVATE polygon_searcher_core)
    target_include_directories(polygon_searcher_tests PRIVATE ../cpp_kernel)
    target_compile_definitions(
        polygon_searcher_tests
        PRIVATE POLYGON_SEARCHER_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    )
    enable_strict_warnings(polygon_searcher_tests)
    add_test(NAME polygon_searcher_tests COMMAND polygon_searcher_tests)
    add_test(
        NAME polygon_searcher_replay
        COMMAND polygon-searcher-replay
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/polygon_quotes.json"
            "${CMAKE_CURRENT_BINARY_DIR}/replay-output"
    )
endif()
