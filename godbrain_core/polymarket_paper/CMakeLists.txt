cmake_minimum_required(VERSION 3.25)
project(godbrain_polymarket_paper VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(polymarket_paper_core
    src/core.cpp
    src/public_api.cpp
    src/repository.cpp
)
target_include_directories(polymarket_paper_core
    PUBLIC include
    PRIVATE ../cpp_kernel
)
target_compile_definitions(
    polymarket_paper_core
    PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS
)
if(MSVC)
    target_compile_options(polymarket_paper_core PRIVATE /W4 /WX /permissive- /EHsc)
else()
    target_compile_options(polymarket_paper_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

add_executable(godbrain-polymarket-paper src/main.cpp src/winhttp_transport.cpp)
target_link_libraries(godbrain-polymarket-paper PRIVATE polymarket_paper_core)
target_include_directories(godbrain-polymarket-paper PRIVATE ../cpp_kernel)
if(WIN32)
    target_link_libraries(godbrain-polymarket-paper PRIVATE winhttp)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(polymarket_paper_tests tests/tests.cpp)
    target_link_libraries(polymarket_paper_tests PRIVATE polymarket_paper_core)
    target_include_directories(polymarket_paper_tests PRIVATE ../cpp_kernel)
    if(MSVC)
        target_compile_options(polymarket_paper_tests PRIVATE /W4 /WX /permissive- /EHsc)
    else()
        target_compile_options(polymarket_paper_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    add_test(NAME polymarket_paper_tests COMMAND polymarket_paper_tests)
endif()
