# CMake build of the wfdb-x C++ library, command-line tools and unit tests
# (see README.md).  Part of wfdb-x.

cmake_minimum_required(VERSION 3.14)

project(wfdbx VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(WFDBX_BUILD_TOOLS "Build the command-line tools" ON)
option(WFDBX_BUILD_TESTS "Build the unit tests" ON)

# Floating-point expressions are evaluated as written, one rounding per
# operation, as in the reference results: compilers that contract a*b+c into
# a fused multiply-add by default (Clang, e.g. Apple Clang on ARM) round
# differently, which changes values such as the baselines written by edf2mit.
if(MSVC)
  add_compile_options(/W3 /utf-8 /fp:precise)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS)
else()
  add_compile_options(-Wall -Wextra -Wpedantic -ffp-contract=off)
endif()

# The library
file(GLOB WFDBX_LIB_SOURCES CONFIGURE_DEPENDS src/*.cpp)
add_library(wfdbx ${WFDBX_LIB_SOURCES})
target_include_directories(wfdbx
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
         $<INSTALL_INTERFACE:include>
  PRIVATE src)
set_target_properties(wfdbx PROPERTIES VERSION ${PROJECT_VERSION}
  WINDOWS_EXPORT_ALL_SYMBOLS ON)
add_library(wfdbx::wfdbx ALIAS wfdbx)

# The command-line tools: one executable per file in apps/ (files whose
# names begin with '_' are shared helpers).
if(WFDBX_BUILD_TOOLS)
  file(GLOB WFDBX_APP_SOURCES CONFIGURE_DEPENDS apps/*.cpp)
  file(GLOB WFDBX_APP_HELPERS CONFIGURE_DEPENDS apps/_*.cpp)
  if(WFDBX_APP_HELPERS)
    list(REMOVE_ITEM WFDBX_APP_SOURCES ${WFDBX_APP_HELPERS})
  endif()
  set(WFDBX_TOOLS)
  foreach(src ${WFDBX_APP_SOURCES})
    get_filename_component(tool ${src} NAME_WE)
    add_executable(${tool} ${src} ${WFDBX_APP_HELPERS})
    target_link_libraries(${tool} PRIVATE wfdbx)
    target_include_directories(${tool} PRIVATE apps)
    set_target_properties(${tool} PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
    list(APPEND WFDBX_TOOLS ${tool})
  endforeach()
endif()

if(WFDBX_BUILD_TESTS)
  enable_testing()
  file(GLOB WFDBX_TEST_SOURCES CONFIGURE_DEPENDS tests/*.cpp)
  if(WFDBX_TEST_SOURCES)
    add_executable(wfdbx_tests ${WFDBX_TEST_SOURCES})
    target_link_libraries(wfdbx_tests PRIVATE wfdbx)
    target_compile_definitions(wfdbx_tests PRIVATE
      WFDBX_TEST_DATA="${CMAKE_CURRENT_SOURCE_DIR}/../tests/data")
    add_test(NAME unit COMMAND wfdbx_tests)
    if(WFDBX_BUILD_TOOLS)
      # (the legacy annotation sorting tests run the sortann tool)
      target_compile_definitions(wfdbx_tests PRIVATE
        WFDBX_TOOLS_DIR="${CMAKE_BINARY_DIR}/bin")
      add_dependencies(wfdbx_tests sortann)
    endif()
  endif()
endif()

include(GNUInstallDirs)
install(TARGETS wfdbx ${WFDBX_TOOLS}
  EXPORT wfdbxTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/wfdbx DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT wfdbxTargets NAMESPACE wfdbx:: FILE wfdbxConfig.cmake
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/wfdbx)
