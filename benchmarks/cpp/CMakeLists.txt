# CMake build of the benchmark driver of the C++ implementation of WFDB-x:
# the executable wfdbx_bench, at the top of the build directory (see
# benchmarks/run.py).
#
#     cmake -S benchmarks/cpp -B benchmarks/build/cpp -DCMAKE_BUILD_TYPE=Release
#     cmake --build benchmarks/build/cpp
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

cmake_minimum_required(VERSION 3.14)

project(wfdbx_bench LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# The library only: no tools, no unit tests.
set(WFDBX_BUILD_TOOLS OFF CACHE BOOL "Build the command-line tools" FORCE)
set(WFDBX_BUILD_TESTS OFF CACHE BOOL "Build the unit tests" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../cpp
                 ${CMAKE_CURRENT_BINARY_DIR}/wfdbx EXCLUDE_FROM_ALL)

# The compiler options of the library (cpp/CMakeLists.txt).
if(MSVC)
  add_compile_options(/W3 /utf-8 /fp:precise)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS)
else()
  add_compile_options(-Wall -Wextra -Wpedantic -ffp-contract=off)
endif()

add_executable(wfdbx_bench bench.cpp)
target_link_libraries(wfdbx_bench PRIVATE wfdbx::wfdbx)
set_target_properties(wfdbx_bench PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
