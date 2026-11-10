#!/usr/bin/env bash
# Build the HarmonyOS native libraries (every ABI in CADCRAFT_NATIVE_TARGETS) before hvigor/CMake.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/scripts/dev.local.env" ]]; then source "$ROOT/scripts/dev.local.env"; fi
SDK="${CADCRAFT_NATIVE_SDK:-${DEVECO_SDK_HOME:-${HOS_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}}/default/openharmony/native}"
# CI SDK locations may already point at openharmony, or at its native directory.
if [[ ! -d "$SDK/llvm" ]]; then
  for candidate in "${DEVECO_SDK_HOME:-}/openharmony/native" "${DEVECO_SDK_HOME:-}/native" "${DEVECO_SDK_HOME:-}"; do
    if [[ -d "$candidate/llvm" && -d "$candidate/sysroot" ]]; then SDK="$candidate"; break; fi
  done
fi
[[ -x "$SDK/llvm/bin/clang" ]] || { echo "HarmonyOS native SDK not found: $SDK" >&2; exit 1; }
# One list drives the build: CMake maps the same ABIs (entry/build-profile.json5 abiFilters), and
# verify_native.py checks the packaged set. Both ABIs ship by default so one HAP runs on ARM
# devices and on the x86_64 phone/PC emulator images.
TARGETS="${CADCRAFT_NATIVE_TARGETS:-aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos}"
PROFILE="${CADCRAFT_RUST_PROFILE:-release}"
case "$PROFILE" in release) ARGS+=(--release);; debug) ARGS+=(--profile dev);; *) echo 'Profile must be release or debug' >&2; exit 2;; esac
for target in $TARGETS; do
  case "$target" in
    aarch64-unknown-linux-ohos|x86_64-unknown-linux-ohos|armv7-unknown-linux-ohos) ;;
    *) echo "Unsupported target: $target" >&2; exit 2;;
  esac
  [[ -d "$(rustc --print sysroot)/lib/rustlib/$target" ]] || { echo "Install target with: rustup target add $target" >&2; exit 1; }
  suffix="${target//-/_}"
  upper="$(printf '%s' "$suffix" | tr '[:lower:]' '[:upper:]')"
  # On Windows the `*-unknown-linux-ohos-clang` wrappers are POSIX shell scripts and CANNOT be
  # spawned by rustc/cc-rs (error 193: "not a valid Win32 application"). Point CC/AR/LINKER at the
  # real Windows `clang.exe` / `llvm-ar.exe` instead; config.toml already passes --target + --sysroot
  # via rustflags, so plain `cargo build` (relying on config.toml [env]/[target]) is the supported path.
  cargo build --locked --manifest-path "$ROOT/native/rust/Cargo.toml" --target "$target" "${ARGS[@]}"
done
