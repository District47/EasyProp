cmake_minimum_required(VERSION 3.21)

# If a vcpkg toolchain is available and the caller didn't specify one, pick it
# up automatically from the VCPKG_ROOT environment variable. (Must run before
# project().)
if(NOT DEFINED CMAKE_TOOLCHAIN_FILE AND DEFINED ENV{VCPKG_ROOT})
  set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
      CACHE STRING "Vcpkg toolchain file")
endif()

project(splat
  VERSION 1.4.2
  DESCRIPTION "RF signal propagation, loss, and terrain analysis tool"
  LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# ---------------------------------------------------------------------------
# Configuration (replaces the legacy interactive ./configure bash script)
# ---------------------------------------------------------------------------
set(SPLAT_HD_MODE 0 CACHE STRING
    "Resolution mode: 0 = standard (3 arc-sec), 1 = HD (1 arc-sec)")
set(SPLAT_MAXPAGES 9 CACHE STRING
    "Max analysis region in square degrees (perfect square: 1/4/9/16/25/36/49/64)")
option(SPLAT_BUILD_UTILS
    "Build the legacy companion utilities (srtm2sdf, usgs2sdf, citydecoder, bearing, fontdata)" OFF)

set(_splat_valid_pages 1 4 9 16 25 36 49 64)
if(NOT SPLAT_MAXPAGES IN_LIST _splat_valid_pages)
  message(FATAL_ERROR
    "SPLAT_MAXPAGES is '${SPLAT_MAXPAGES}'; must be one of: ${_splat_valid_pages}")
endif()
if(NOT (SPLAT_HD_MODE STREQUAL "0" OR SPLAT_HD_MODE STREQUAL "1"))
  message(FATAL_ERROR "SPLAT_HD_MODE must be 0 or 1 (got '${SPLAT_HD_MODE}')")
endif()

configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/src/splat_config.h.in"
  "${CMAKE_CURRENT_BINARY_DIR}/splat_config.h"
  @ONLY)

include(cmake/Dependencies.cmake)

# OpenMP -- used to parallelize the 4 edge loops in PlotLRMap and to give
# each worker thread its own thread_local path/elev scratch + thread_local
# itwom static caches. MSVC ships OpenMP 2.0 (sufficient for our static-
# schedule int-counted loops); gcc/clang ship newer. Required, not optional:
# the splat.cpp pragmas degrade to serial without it but the build flag
# also defines _OPENMP which we use to gate omp_get_max_threads() calls.
find_package(OpenMP REQUIRED)

# ---------------------------------------------------------------------------
# splat executable
# ---------------------------------------------------------------------------
add_executable(splat
  src/splat.cpp
  src/itwom3.0.cpp
  src/compat/platform.cpp
  src/render/PngWriter.cpp
  src/render/GeoTiffWriter.cpp)

target_include_directories(splat PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}"   # generated splat_config.h
  "${CMAKE_CURRENT_SOURCE_DIR}/src")

target_link_libraries(splat PRIVATE BZip2::BZip2 TIFF::TIFF OpenMP::OpenMP_CXX)

if(MSVC)
  target_compile_definitions(splat PRIVATE
    _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS)
  target_compile_options(splat PRIVATE /fp:fast $<$<CONFIG:Release>:/O2>)
  # SPLAT!'s deep ITWOM propagation call chain uses far more stack than MSVC's
  # 1 MB default allows (Linux defaults to 8 MB, which is why upstream never
  # hit this). Reserve 16 MB so the analysis routines don't overflow.
  target_link_options(splat PRIVATE /STACK:16777216)
else()
  target_compile_options(splat PRIVATE
    -ffast-math $<$<CONFIG:Release>:-O2>)
endif()

# Name the HD build "splat-hd" to mirror the original convention.
if(SPLAT_HD_MODE STREQUAL "1")
  set_target_properties(splat PROPERTIES OUTPUT_NAME "splat-hd")
endif()

if(SPLAT_BUILD_UTILS)
  add_subdirectory(utils)
endif()

message(STATUS "SPLAT! configured: HD_MODE=${SPLAT_HD_MODE}, MAXPAGES=${SPLAT_MAXPAGES}, utils=${SPLAT_BUILD_UTILS}")
