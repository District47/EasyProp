# ---------------------------------------------------------------------------
# Dependencies.cmake -- locate SPLAT!'s third-party libraries.
#
# splat itself needs only BZip2 (the original build linked just -lm -lbz2;
# libm is implicit on Windows/MSVC).  zlib is required only by the optional
# `fontdata` utility.  When building with the vcpkg toolchain these are
# provided by the vcpkg.json manifest; otherwise system/distro packages
# (e.g. apt's libbz2-dev / zlib1g-dev) are used via find_package.
# ---------------------------------------------------------------------------

find_package(BZip2 REQUIRED)

# zlib is optional here; only the utils need it. Don't hard-fail the core build.
find_package(ZLIB QUIET)
if(NOT ZLIB_FOUND)
  message(STATUS "zlib not found -- the 'fontdata' utility will be unavailable.")
endif()
