cmake_minimum_required(VERSION 3.25)
project(godbrain_polygon_pipeline VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(POLYGON_PIPELINE_BUILD_TESTING "${BUILD_TESTING}")
set(BUILD_TESTING OFF)
if(NOT TARGET polygon_observer_core)
    add_subdirectory(
        "${CMAKE_CURRENT_SOURCE_DIR}/../polygon_observer"
        "${CMAKE_CURRENT_BINARY_DIR}/polygon_observer"
    )
endif()
if(NOT TARGET polygon_searcher_core)
    add_subdirectory(
        "${CMAKE_CURRENT_SOURCE_DIR}/../polygon_searcher"
        "${CMAKE_CURRENT_BINARY_DIR}/polygon_searcher"
    )
endif()
set(BUILD_TESTING "${POLYGON_PIPELINE_BUILD_TESTING}")

function(polygon_pipeline_strict target)
    target_compile_definitions(
        ${target} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS
    )
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX /permissive- /EHsc)
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
endfunction()

add_library(polygon_pipeline_core
    src/pipeline.cpp
    src/sha256.cpp
)
target_include_directories(polygon_pipeline_core PUBLIC include)
target_link_libraries(
    polygon_pipeline_core PUBLIC polygon_observer_core polygon_searcher_core
)
polygon_pipeline_strict(polygon_pipeline_core)

add_executable(godbrain-polygon-pipeline
    src/main.cpp
    ../polygon_observer/src/winhttp_transport.cpp
)
target_link_libraries(godbrain-polygon-pipeline PRIVATE polygon_pipeline_core)
polygon_pipeline_strict(godbrain-polygon-pipeline)
if(WIN32)
    target_link_libraries(godbrain-polygon-pipeline PRIVATE winhttp)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(polygon_pipeline_tests tests/tests.cpp)
    target_link_libraries(polygon_pipeline_tests PRIVATE polygon_pipeline_core)
    target_compile_definitions(
        polygon_pipeline_tests
        PRIVATE POLYGON_PIPELINE_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    )
    polygon_pipeline_strict(polygon_pipeline_tests)
    add_test(NAME polygon_pipeline_tests COMMAND polygon_pipeline_tests)
    add_test(
        NAME polygon_pipeline_fixture_replay
        COMMAND godbrain-polygon-pipeline replay
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/pipeline_config.json"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/rpc_replay.json"
            polygon-pipeline-fixture-replay
    )
endif()
