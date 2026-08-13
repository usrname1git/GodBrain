cmake_minimum_required(VERSION 3.25)
project(godbrain_polygon_observer VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(polygon_observer_core
    src/core.cpp
    src/registry.cpp
)
target_include_directories(polygon_observer_core
    PUBLIC include
    PRIVATE ../cpp_kernel
)
target_compile_definitions(
    polygon_observer_core
    PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS
)

function(godbrain_strict_warnings target)
    target_compile_definitions(
        ${target}
        PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS
    )
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX /permissive- /EHsc)
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
endfunction()

godbrain_strict_warnings(polygon_observer_core)

add_executable(godbrain-polygon-observer
    src/main.cpp
    src/winhttp_transport.cpp
)
target_link_libraries(godbrain-polygon-observer PRIVATE polygon_observer_core)
target_include_directories(godbrain-polygon-observer PRIVATE ../cpp_kernel)
godbrain_strict_warnings(godbrain-polygon-observer)
if(WIN32)
    target_link_libraries(godbrain-polygon-observer PRIVATE winhttp)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(polygon_observer_tests tests/tests.cpp)
    target_link_libraries(polygon_observer_tests PRIVATE polygon_observer_core)
    target_include_directories(polygon_observer_tests PRIVATE ../cpp_kernel)
    godbrain_strict_warnings(polygon_observer_tests)
    add_test(NAME polygon_observer_tests COMMAND polygon_observer_tests)
endif()
