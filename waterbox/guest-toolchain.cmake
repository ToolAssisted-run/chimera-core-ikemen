# The miniBox guest as a CMake toolchain, for LLVM (build-llvm.sh): musl and
# its libstdc++ from the guest sysroot, the large code model, no PIC, no host
# libraries. MINIBOX_SYSROOT names the sysroot (build-llvm.sh sets it).
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

if(NOT DEFINED ENV{MINIBOX_SYSROOT})
  message(FATAL_ERROR "set MINIBOX_SYSROOT to miniBox's build/meson-cpp/guest-sysroot")
endif()
set(SR "$ENV{MINIBOX_SYSROOT}")
execute_process(COMMAND gcc -dumpfullversion OUTPUT_VARIABLE GCCVER OUTPUT_STRIP_TRAILING_WHITESPACE)

set(CMAKE_C_COMPILER gcc)
set(CMAKE_CXX_COMPILER g++)

set(WB "-specs=${SR}/lib/musl-gcc.specs -mcmodel=large -mno-red-zone -mstack-protector-guard=global -fno-stack-protector -fno-pic -fno-pie -fcf-protection=none")
set(CMAKE_C_FLAGS_INIT "${WB}")
set(CMAKE_CXX_FLAGS_INIT "${WB} -I${SR}/include/c++/${GCCVER} -I${SR}/include/c++/${GCCVER}/x86_64-linux-musl")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")

# probes compile and archive; they cannot run a guest
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_FIND_ROOT_PATH "${SR}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
