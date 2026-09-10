cmake_minimum_required(VERSION 3.25)
project(godbrain_cpp_memory_store VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(MONGOC_ROOT "$ENV{MONGOC_ROOT}" CACHE PATH "mongo-c-driver install prefix")
if(NOT MONGOC_ROOT)
    set(MONGOC_ROOT "C:/Tools/mongo-c-driver")
endif()
# Driver is RelWithDebInfo; map our Release/Debug so IMPORTED_LOCATION resolves.
set(CMAKE_MAP_IMPORTED_CONFIG_RELEASE RelWithDebInfo Release)
set(CMAKE_MAP_IMPORTED_CONFIG_RELWITHDEBINFO RelWithDebInfo Release)
set(CMAKE_MAP_IMPORTED_CONFIG_MINSIZEREL RelWithDebInfo MinSizeRel Release)
set(CMAKE_MAP_IMPORTED_CONFIG_DEBUG RelWithDebInfo Release Debug)
list(APPEND CMAKE_PREFIX_PATH "${MONGOC_ROOT}")
find_package(mongoc-1.0 CONFIG QUIET)

add_library(cpp_memory_store_core
    src/json.cpp
    src/protocol.cpp
    src/state_machine.cpp
    src/store.cpp
    src/embedding.cpp
)
target_include_directories(cpp_memory_store_core
    PUBLIC include
    PRIVATE ../cpp_tools src
)
target_compile_definitions(
    cpp_memory_store_core
    PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS
)
if(MSVC)
    target_compile_options(cpp_memory_store_core PRIVATE /W4 /WX /permissive- /EHsc)
else()
    target_compile_options(cpp_memory_store_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()
if(WIN32)
    target_link_libraries(cpp_memory_store_core PUBLIC winhttp bcrypt Normaliz)
endif()
if(mongoc-1.0_FOUND)
    target_sources(cpp_memory_store_core PRIVATE src/projector.cpp)
    target_compile_definitions(cpp_memory_store_core PRIVATE GODBRAIN_HAVE_MONGOC)
    if(TARGET mongo::mongoc_static)
        target_link_libraries(cpp_memory_store_core PUBLIC mongo::mongoc_static)
    else()
        target_link_libraries(cpp_memory_store_core PUBLIC mongo::mongoc_shared)
    endif()
    if(WIN32)
        target_link_libraries(cpp_memory_store_core PUBLIC rpcrt4)
    endif()
    message(STATUS "cpp_memory_store: mongoc-1.0 at ${MONGOC_ROOT}")
else()
    message(STATUS "cpp_memory_store: mongoc-1.0 not found (protocol-only). Run scripts/Fetch-MongoCDriver.ps1")
endif()

add_executable(memory-store src/main.cpp)
target_link_libraries(memory-store PRIVATE cpp_memory_store_core)
target_include_directories(memory-store PRIVATE include ../cpp_tools)
if(MSVC)
    target_compile_options(memory-store PRIVATE /W4 /WX /permissive- /EHsc)
    set_target_properties(memory-store PROPERTIES OUTPUT_NAME memory-store)
endif()
if(mongoc-1.0_FOUND)
    add_executable(rag-rebuild src/rag_rebuild_main.cpp)
    target_link_libraries(rag-rebuild PRIVATE cpp_memory_store_core)
    target_include_directories(rag-rebuild PRIVATE include ../cpp_tools src)
    target_compile_definitions(rag-rebuild PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
    if(MSVC)
        target_compile_options(rag-rebuild PRIVATE /W4 /WX /permissive- /EHsc)
        set_target_properties(rag-rebuild PROPERTIES OUTPUT_NAME rag-rebuild)
    endif()
    add_executable(rag-service
        src/rag_service_main.cpp
        src/http_loopback.cpp
        src/rag_engine.cpp
    )
    target_link_libraries(rag-service PRIVATE cpp_memory_store_core)
    target_include_directories(rag-service PRIVATE include ../cpp_tools src)
    target_compile_definitions(rag-service PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
    if(WIN32)
        target_link_libraries(rag-service PRIVATE ws2_32)
    endif()
    if(MSVC)
        target_compile_options(rag-service PRIVATE /W4 /WX /permissive- /EHsc)
        set_target_properties(rag-service PROPERTIES OUTPUT_NAME rag-service)
    endif()
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(cpp_memory_store_tests tests/tests.cpp)
    target_link_libraries(cpp_memory_store_tests PRIVATE cpp_memory_store_core)
    target_include_directories(cpp_memory_store_tests PRIVATE include ../cpp_tools)
    if(MSVC)
        target_compile_options(cpp_memory_store_tests PRIVATE /W4 /WX /permissive- /EHsc)
    endif()
    add_test(NAME cpp_memory_store_protocol COMMAND cpp_memory_store_tests)
endif()
