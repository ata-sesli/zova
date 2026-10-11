cmake_minimum_required(VERSION 3.20)
project(zova_networkit_pagerank LANGUAGES CXX)
include(FetchContent)
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()
if(POLICY CMP0169)
    cmake_policy(SET CMP0169 OLD)
endif()
# Only populate the fixed archives; do not configure NetworKit's full toolkit.
FetchContent_Declare(networkit
    URL https://codeload.github.com/networkit/networkit/tar.gz/6b3878ee00a6eadd50be3b3047fbcae56bcac685
    URL_HASH SHA256=2b85d656c423b43d4381ea499239065496fd00353f82614372555bb3a21d7674)
FetchContent_Declare(tlx
    URL https://codeload.github.com/tlx/tlx/tar.gz/2dd63ab839909f0b43cd02108a1869c4670b2c8e
    URL_HASH SHA256=8bb17f2ffeba55d270ca37913dc0c0110b322f471fc05ee23c3f748c4030ff23)
FetchContent_Populate(networkit)
FetchContent_Populate(tlx)
find_package(OpenMP REQUIRED)
find_package(Threads REQUIRED)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
add_library(networkit_rank STATIC
    ${networkit_SOURCE_DIR}/networkit/cpp/GlobalState.cpp
    ${networkit_SOURCE_DIR}/networkit/cpp/graph/Graph.cpp
    ${networkit_SOURCE_DIR}/networkit/cpp/centrality/Centrality.cpp
    ${networkit_SOURCE_DIR}/networkit/cpp/centrality/PageRank.cpp
    ${networkit_SOURCE_DIR}/networkit/cpp/auxiliary/Log.cpp
    ${networkit_SOURCE_DIR}/networkit/cpp/auxiliary/Random.cpp
    ${networkit_SOURCE_DIR}/networkit/cpp/auxiliary/NumericTools.cpp
    ${networkit_SOURCE_DIR}/networkit/cpp/auxiliary/SignalHandling.cpp
    ${networkit_SOURCE_DIR}/networkit/cpp/auxiliary/Timer.cpp)
target_include_directories(networkit_rank PUBLIC ${networkit_SOURCE_DIR}/include ${tlx_SOURCE_DIR})
target_compile_definitions(networkit_rank PUBLIC NETWORKIT_BUILDING_STATELIB NETWORKIT_QUIET_LOGGING NETWORKIT_RELEASE_LOGGING)
target_link_libraries(networkit_rank PUBLIC OpenMP::OpenMP_CXX Threads::Threads)
if(MSVC)
    target_compile_definitions(networkit_rank PUBLIC NETWORKIT_OMP2 NETWORKIT_WINDOWS)
else()
    target_compile_options(networkit_rank PRIVATE -ffunction-sections -fdata-sections)
endif()
add_library(zova_networkit SHARED pagerank.cpp)
target_include_directories(zova_networkit PRIVATE ../../include)
target_link_libraries(zova_networkit PRIVATE networkit_rank)
if(APPLE)
    target_link_options(zova_networkit PRIVATE -Wl,-dead_strip)
elseif(UNIX)
    target_link_options(zova_networkit PRIVATE -Wl,--gc-sections -Wl,--no-undefined)
endif()
install(TARGETS zova_networkit LIBRARY DESTINATION networkit.zovaext RUNTIME DESTINATION networkit.zovaext)
file(GENERATE OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/extension.json CONTENT
    "{\"name\":\"networkit\",\"version\":\"1.0.0\",\"storage_prefix\":\"_zova_ext_networkit_\",\"zova_abi_min\":\"1.1.0\",\"capabilities\":\"\",\"library\":\"$<TARGET_FILE_NAME:zova_networkit>\",\"entrypoint\":\"zova_plugin_entry_v1\"}\n")
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/extension.json DESTINATION networkit.zovaext)
install(FILES ${networkit_SOURCE_DIR}/License.txt DESTINATION networkit.zovaext RENAME LICENSE-NetworKit)
install(FILES ${tlx_SOURCE_DIR}/LICENSE DESTINATION networkit.zovaext RENAME LICENSE-TLX)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../LICENSE DESTINATION networkit.zovaext RENAME LICENSE-Zova)
install(FILES README.md DESTINATION networkit.zovaext)

set(ZOVA_C_ABI_LIBRARY "" CACHE FILEPATH "Zova static C ABI for the external behavior test")
set(ZOVA_COMPILER_RT_LIBRARY "" CACHE FILEPATH "Compiler runtime needed by a generated-C test host with a system linker")
if(ZOVA_C_ABI_LIBRARY)
    add_executable(pagerank_test ../../tests/networkit_pagerank.cpp)
    target_include_directories(pagerank_test PRIVATE ../../include)
    target_link_libraries(pagerank_test PRIVATE ${ZOVA_C_ABI_LIBRARY} Threads::Threads ${CMAKE_DL_LIBS})
    if(ZOVA_COMPILER_RT_LIBRARY)
        target_link_libraries(pagerank_test PRIVATE ${ZOVA_COMPILER_RT_LIBRARY})
    endif()
    if(WIN32)
        target_link_libraries(pagerank_test PRIVATE ntdll)
    else()
        target_link_libraries(pagerank_test PRIVATE m)
    endif()
    add_executable(pagerank_faults ../../tests/networkit_pagerank_faults.cpp)
    target_include_directories(pagerank_faults PRIVATE ../../include)
    target_link_libraries(pagerank_faults PRIVATE OpenMP::OpenMP_CXX ${CMAKE_DL_LIBS})
endif()
