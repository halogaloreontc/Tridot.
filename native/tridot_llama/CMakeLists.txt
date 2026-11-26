# Обёртка llama.cpp для «Продвинутой» (ADR-046).
#   tool/fetch_llama.sh                 # исходники llama.cpp → third_party/llama.cpp
#   cmake -S native/tridot_llama -B build/tridot_llama -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/tridot_llama -j
cmake_minimum_required(VERSION 3.18)
project(tridot_llama CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(LLAMA_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../third_party/llama.cpp" CACHE PATH "исходники llama.cpp")
if(NOT EXISTS "${LLAMA_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "нет исходников llama.cpp в ${LLAMA_SOURCE_DIR}: запустите tool/fetch_llama.sh")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
add_subdirectory("${LLAMA_SOURCE_DIR}" llama.cpp EXCLUDE_FROM_ALL)

add_library(tridot_llama SHARED tridot_llama.cpp)
target_link_libraries(tridot_llama PRIVATE llama)
set_target_properties(tridot_llama PROPERTIES CXX_VISIBILITY_PRESET hidden)
