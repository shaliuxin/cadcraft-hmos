cmake_minimum_required(VERSION 3.5.0)
project(cadcraft_native)
set(CMAKE_CXX_STANDARD 17)
get_filename_component(CADCRAFT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." ABSOLUTE)
# OHOS_ARCH is the ABI hvigor is building (abiFilters in entry/build-profile.json5). This mapping
# is the only place in the C++ layer that knows about architectures: adding an ABI means adding a
# line here plus the corresponding triple in scripts/build_native.sh and scripts/verify_native.py.
if(OHOS_ARCH STREQUAL "arm64-v8a")
  set(RUST_TARGET aarch64-unknown-linux-ohos)
elseif(OHOS_ARCH STREQUAL "x86_64")
  set(RUST_TARGET x86_64-unknown-linux-ohos)
elseif(OHOS_ARCH STREQUAL "armeabi-v7a")
  set(RUST_TARGET armv7-unknown-linux-ohos)
else()
  message(FATAL_ERROR "CADCraft does not support OHOS_ARCH=${OHOS_ARCH}")
endif()
if(NOT DEFINED CADCRAFT_RUST_PROFILE)
  set(CADCRAFT_RUST_PROFILE release)
endif()
# CADCRAFT_RUST_TARGET_DIR points at a target directory outside the workspace (CI caches it); it
# must contain <triple>/<profile>/libcadcraft_hmos.a for the ABI being built.
if(DEFINED CADCRAFT_RUST_TARGET_DIR AND NOT CADCRAFT_RUST_TARGET_DIR STREQUAL "")
  set(RUST_LIBRARY "${CADCRAFT_RUST_TARGET_DIR}/${RUST_TARGET}/${CADCRAFT_RUST_PROFILE}/libcadcraft_hmos.a")
else()
  set(RUST_LIBRARY "${CADCRAFT_ROOT}/native/rust/target/${RUST_TARGET}/${CADCRAFT_RUST_PROFILE}/libcadcraft_hmos.a")
endif()
if(NOT EXISTS "${RUST_LIBRARY}")
  message(FATAL_ERROR "Run scripts/build_native.sh before building HAP: ${RUST_LIBRARY}")
endif()
add_library(cadcraft SHARED bridge.cpp)
target_link_libraries(cadcraft PRIVATE "${RUST_LIBRARY}" ace_napi.z ace_ndk.z native_window native_vsync hilog_ndk.z EGL GLESv3 dl m pthread)

target_link_options(cadcraft PRIVATE "-Wl,--gc-sections" "-Wl,--exclude-libs,ALL")
