cmake_minimum_required(VERSION 3.18)
project(cpython_runtime LANGUAGES C)

set(PYTHON_VERSION "3.14")
set(PYTHON_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../../../runtime/${ANDROID_ABI}/prefix")

add_library(python_runtime SHARED IMPORTED)
set_target_properties(python_runtime PROPERTIES
  IMPORTED_LOCATION "${PYTHON_PREFIX}/lib/libpython${PYTHON_VERSION}.so"
  INTERFACE_INCLUDE_DIRECTORIES "${PYTHON_PREFIX}/include/python${PYTHON_VERSION}"
)

add_library(cpython_runtime SHARED cpython_runtime.c)
target_compile_features(cpython_runtime PRIVATE c_std_11)
target_link_libraries(cpython_runtime PRIVATE python_runtime log)
