cmake_minimum_required(VERSION 4.0)

find_package(cmake-fetch REQUIRED PATHS node_modules/cmake-fetch)

project(musl_sysroot C CXX)

include(ExternalProject)

# Must match the release that `llvm-runtime` builds its musl builtins against.
set(MUSL_SYSROOT_MUSL_VERSION "1.2.6" CACHE STRING "The musl release to build")

set(MUSL_SYSROOT_KERNEL_VERSION "6.12.112" CACHE STRING "The Linux kernel release to install the headers of")

# Must match the release of the `llvm-runtime` compiler, as libc++ depends on
# the exact compiler it is built with.
set(MUSL_SYSROOT_LLVM_VERSION "23.1.2" CACHE STRING "The LLVM release to build the C++ libraries from")

set(
  MUSL_SYSROOT_TARGETS
    aarch64-linux-musl
    arm-linux-musleabi
    i386-linux-musl
    mips-linux-musl
    mips-linux-muslsf
    mipsel-linux-musl
    mipsel-linux-muslsf
    x86_64-linux-musl
  CACHE STRING "The targets to build a sysroot for"
)

# The kernel builds tools that need a Linux host before generating its headers.
if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "The Linux kernel headers can only be generated on a Linux host")
endif()

fetch_package(
  "https://musl.libc.org/releases/musl-${MUSL_SYSROOT_MUSL_VERSION}.tar.gz"
  SOURCE_DIR libc_source
  SOURCE_SUBDIR fetch-only
)

string(REGEX MATCH "^[0-9]+" kernel_major "${MUSL_SYSROOT_KERNEL_VERSION}")

fetch_package(
  "https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}.x/linux-${MUSL_SYSROOT_KERNEL_VERSION}.tar.xz"
  SOURCE_DIR kernel_source
  SOURCE_SUBDIR fetch-only
)

fetch_package(
  "github:llvm/llvm-project#llvmorg-${MUSL_SYSROOT_LLVM_VERSION}"
  SOURCE_DIR llvm_source
  SOURCE_SUBDIR fetch-only
)

find_program(make NAMES gmake make REQUIRED)

cmake_host_system_information(RESULT jobs QUERY NUMBER_OF_LOGICAL_CORES)

# The host's archiver may not understand every target, so use the tools that
# ship with the compiler.
cmake_path(GET CMAKE_C_COMPILER PARENT_PATH tools)

foreach(tool IN ITEMS ar nm ranlib)
  find_program(llvm_${tool} NAMES llvm-${tool} HINTS "${tools}" NO_DEFAULT_PATH REQUIRED)
endforeach()

set(stage "${CMAKE_CURRENT_BINARY_DIR}/stage")

# The host toolchain passes the resource directory and linker as compiler flags,
# which every sub-build needs as well.
separate_arguments(flags UNIX_COMMAND "${CMAKE_C_FLAGS}")

foreach(target IN LISTS MUSL_SYSROOT_TARGETS)
  set(sysroot "${stage}/${target}")

  string(REGEX MATCH "^[^-]+" processor "${target}")

  # The kernel has one MIPS architecture for both byte orders and float ABIs.
  if(processor STREQUAL "aarch64")
    set(kernel_arch arm64)
  elseif(processor MATCHES "^(i386|x86_64)$")
    set(kernel_arch x86)
  elseif(processor MATCHES "^mips")
    set(kernel_arch mips)
  else()
    set(kernel_arch ${processor})
  endif()

  set(kernel_headers "${CMAKE_CURRENT_BINARY_DIR}/kernel-headers-${kernel_arch}")

  if(NOT TARGET kernel-headers-${kernel_arch})
    ExternalProject_Add(
      kernel-headers-${kernel_arch}
      SOURCE_DIR "${kernel_source}"
      BINARY_DIR "${kernel_headers}"
      DOWNLOAD_COMMAND ""
      UPDATE_COMMAND ""
      CONFIGURE_COMMAND ""
      BUILD_COMMAND "${make}" -C "${kernel_source}" "O=${kernel_headers}" "ARCH=${kernel_arch}" -j${jobs} headers
      INSTALL_COMMAND ""
      USES_TERMINAL_BUILD ON
    )
  endif()

  set(target_flags --rtlib=compiler-rt)

  # Match the Armv7-A baseline of the toolchain and the `llvm-runtime` builtins.
  if(processor STREQUAL "arm")
    list(APPEND target_flags -march=armv7-a)
  endif()

  # clang ignores the float ABI implied by `muslsf`, so pass it explicitly.
  if(target MATCHES "-muslsf$")
    list(APPEND target_flags -msoft-float)
  endif()

  execute_process(
    COMMAND "${CMAKE_C_COMPILER}" ${flags} "--target=${target}" ${target_flags} --print-libgcc-file-name
    OUTPUT_VARIABLE builtins
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
  )

  # The driver prints the expected path even when nothing is there.
  if(NOT EXISTS "${builtins}")
    message(FATAL_ERROR
      "'llvm-runtime' has no compiler runtime builtins for '${target}'. The "
      "driver expects them at '${builtins}'.\n"
    )
  endif()

  set(cc "${CMAKE_C_COMPILER}" ${flags} "--target=${target}" ${target_flags} -fuse-ld=lld)

  list(JOIN cc " " cc)

  ExternalProject_Add(
    libc-${target}
    DEPENDS kernel-headers-${kernel_arch}
    SOURCE_DIR "${libc_source}"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/libc-${target}"
    DOWNLOAD_COMMAND ""
    UPDATE_COMMAND ""
    CONFIGURE_COMMAND
      ${CMAKE_COMMAND} -E env "CC=${cc}" "AR=${llvm_ar}" "RANLIB=${llvm_ranlib}"
        "${libc_source}/configure" "--target=${target}" --prefix=/usr --syslibdir=/lib
    BUILD_COMMAND "${make}" -j${jobs}
    INSTALL_COMMAND "${make}" "DESTDIR=${sysroot}" install
    # The dynamic loader is an absolute symlink that only works on the target.
    COMMAND
      ${CMAKE_COMMAND}
        -D "directory=${sysroot}/lib"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/remove-loader.cmake"
    COMMAND
      ${CMAKE_COMMAND}
        -D "source=${kernel_headers}/usr/include"
        -D "destination=${sysroot}/usr"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/install-headers.cmake"
    USES_TERMINAL_CONFIGURE ON
    USES_TERMINAL_BUILD ON
    USES_TERMINAL_INSTALL ON
  )

  list(JOIN target_flags " " target_flags)

  # The unwinder is built here, so nothing can link one in yet.
  set(libcxx_flags "${CMAKE_CXX_FLAGS} ${target_flags} --unwindlib=none")

  ExternalProject_Add(
    libcxx-${target}
    DEPENDS libc-${target}
    SOURCE_DIR "${llvm_source}/runtimes"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/libcxx-${target}"
    DOWNLOAD_COMMAND ""
    UPDATE_COMMAND ""
    LIST_SEPARATOR "|"
    CMAKE_ARGS
      "-DCMAKE_BUILD_TYPE=Release"
      "-DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}"
      "-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
      "-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}"
      "-DCMAKE_ASM_COMPILER=${CMAKE_C_COMPILER}"
      "-DCMAKE_AR=${llvm_ar}"
      "-DCMAKE_NM=${llvm_nm}"
      "-DCMAKE_RANLIB=${llvm_ranlib}"
      "-DCMAKE_C_FLAGS=${libcxx_flags}"
      "-DCMAKE_CXX_FLAGS=${libcxx_flags}"
      "-DCMAKE_ASM_FLAGS=${libcxx_flags}"
      -DCMAKE_LINKER_TYPE=LLD
      "-DCMAKE_INSTALL_PREFIX=${sysroot}/usr"
      "-DCMAKE_SYSROOT=${sysroot}"
      -DCMAKE_SYSTEM_NAME=Linux
      "-DCMAKE_SYSTEM_PROCESSOR=${processor}"
      "-DCMAKE_C_COMPILER_TARGET=${target}"
      "-DCMAKE_CXX_COMPILER_TARGET=${target}"
      "-DCMAKE_ASM_COMPILER_TARGET=${target}"
      # The libraries also end up in shared objects such as addons.
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      # Nothing can link C++ before these libraries exist.
      -DCMAKE_CXX_COMPILER_WORKS=ON
      -DLLVM_COMPILER_CHECKED=ON
      "-DLLVM_ENABLE_RUNTIMES=libunwind|libcxxabi|libcxx"
      -DLIBCXX_CXX_ABI=libcxxabi
      -DLIBCXX_ENABLE_SHARED=OFF
      -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON
      -DLIBCXX_HAS_MUSL_LIBC=ON
      -DLIBCXX_INCLUDE_BENCHMARKS=OFF
      -DLIBCXX_INCLUDE_TESTS=OFF
      -DLIBCXX_USE_COMPILER_RT=ON
      -DLIBCXXABI_ENABLE_SHARED=OFF
      -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON
      -DLIBCXXABI_INCLUDE_TESTS=OFF
      -DLIBCXXABI_USE_COMPILER_RT=ON
      -DLIBCXXABI_USE_LLVM_UNWINDER=ON
      -DLIBUNWIND_ENABLE_SHARED=OFF
      -DLIBUNWIND_INCLUDE_TESTS=OFF
      -DLIBUNWIND_USE_COMPILER_RT=ON
    USES_TERMINAL_CONFIGURE ON
    USES_TERMINAL_BUILD ON
    USES_TERMINAL_INSTALL ON
  )

  add_custom_target(musl_sysroot_${target} ALL DEPENDS libcxx-${target})

  install(
    DIRECTORY "${sysroot}/"
    DESTINATION "${target}"
    USE_SOURCE_PERMISSIONS
  )
endforeach()
