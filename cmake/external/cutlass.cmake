include(FetchContent)
onnxruntime_fetchcontent_declare(
  cutlass
  URL ${DEP_URL_cutlass}
  URL_HASH SHA1=${DEP_SHA1_cutlass}
  EXCLUDE_FROM_ALL
  PATCH_COMMAND ${CMAKE_COMMAND}
    "-DCUTLASS_SOURCE_DIR=<SOURCE_DIR>"
    -P "${PROJECT_SOURCE_DIR}/patches/cutlass/apply_cutlass_4_4_2_patch.cmake"
)

FetchContent_GetProperties(cutlass)
if(NOT cutlass_POPULATED)
  FetchContent_Populate(cutlass)
endif()
