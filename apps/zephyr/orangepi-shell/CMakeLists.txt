cmake_minimum_required(VERSION 3.20.0)

set(AKA_RK3588_SOURCE_DIR "" CACHE PATH "AKA checkout providing the Zephyr controller")
set(KCONFIG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/Kconfig")
if(AKA_RK3588_SOURCE_DIR)
  set(aka_app "${AKA_RK3588_SOURCE_DIR}/zephyr/orangepi_robot_control")
  if(NOT EXISTS "${aka_app}/CMakeLists.txt")
    message(FATAL_ERROR "AKA controller source not found: ${aka_app}")
  endif()
  set(KCONFIG_ROOT "${aka_app}/Kconfig")
  list(APPEND EXTRA_CONF_FILE "${aka_app}/prj.conf" "${CMAKE_CURRENT_SOURCE_DIR}/aka-shell.conf")
  set(DTC_OVERLAY_FILE "${aka_app}/app.overlay;${CMAKE_CURRENT_SOURCE_DIR}/boards/orangepi_5_plus_rk3588.overlay" CACHE STRING "Unified shell device tree overlays" FORCE)
else()
  set(DTC_OVERLAY_FILE "${CMAKE_CURRENT_SOURCE_DIR}/boards/orangepi_5_plus_rk3588.overlay" CACHE STRING "Unified shell device tree overlays" FORCE)
endif()
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(orangepi_ivc_shell)

target_sources(app PRIVATE src/main.cpp src/axivc_tests.cpp src/ivc_benchmark.cpp src/aka_adapter.cpp src/irq_latency.cpp)
target_include_directories(app PRIVATE include)
include(${CMAKE_CURRENT_SOURCE_DIR}/arm-timer-observer.cmake)

set(AKA_RK3588_LIBRARY "" CACHE FILEPATH "Optional aka-rk3588 library")
set(AKA_RK3588_INCLUDE_DIR "" CACHE PATH "Optional aka-rk3588 include directory")
if(AKA_RK3588_SOURCE_DIR AND AKA_RK3588_LIBRARY)
  message(FATAL_ERROR "Select either AKA source or a prebuilt library")
endif()
if(AKA_RK3588_SOURCE_DIR)
  target_sources(app PRIVATE
    "${aka_app}/src/main.c"
    "${aka_app}/src/ivc_transport.c"
    "${aka_app}/src/robot_config_receiver.c"
    "${aka_app}/src/feetech_bus.c"
    "${aka_app}/src/robot_controller.c"
    "${aka_app}/src/resettable_watchdog.c")
  set_source_files_properties("${aka_app}/src/main.c" PROPERTIES
    COMPILE_DEFINITIONS main=aka_rk3588_run)
  target_include_directories(app PRIVATE "${AKA_RK3588_SOURCE_DIR}/protocol")
  target_compile_definitions(app PRIVATE TGOS_AKA_RK3588=1)
endif()
if(AKA_RK3588_LIBRARY)
  if(NOT EXISTS "${AKA_RK3588_LIBRARY}")
    message(FATAL_ERROR "AKA library does not exist: ${AKA_RK3588_LIBRARY}")
  endif()
  add_library(aka_rk3588_external UNKNOWN IMPORTED GLOBAL)
  set_target_properties(aka_rk3588_external PROPERTIES IMPORTED_LOCATION "${AKA_RK3588_LIBRARY}")
  target_link_libraries(app PRIVATE aka_rk3588_external)
  target_compile_definitions(app PRIVATE TGOS_AKA_RK3588=1)
endif()
if(AKA_RK3588_INCLUDE_DIR)
  target_include_directories(app PRIVATE "${AKA_RK3588_INCLUDE_DIR}")
endif()
