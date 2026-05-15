if(NOT DEFINED CUTLASS_SOURCE_DIR OR CUTLASS_SOURCE_DIR STREQUAL "")
  message(FATAL_ERROR "CUTLASS_SOURCE_DIR is required")
endif()

# CI 的 Windows 环境可能优先找到 Strawberry 自带的旧 patch.exe，
# 它在应用 CUTLASS 补丁时会触发内部断言。这里改用 CMake 文本替换，
# 只修改 YOLO 精简 CUDA 构建需要的三处兼容性补丁，并保持幂等。
function(neonsight_replace_once file_path old_text new_text)
  file(READ "${file_path}" file_content)
  string(FIND "${file_content}" "${new_text}" patched_index)
  if(NOT patched_index EQUAL -1)
    return()
  endif()

  string(FIND "${file_content}" "${old_text}" old_index)
  if(old_index EQUAL -1)
    message(FATAL_ERROR "CUTLASS patch context was not found: ${file_path}")
  endif()

  string(REPLACE "${old_text}" "${new_text}" file_content "${file_content}")
  file(WRITE "${file_path}" "${file_content}")
endfunction()

set(layout_file "${CUTLASS_SOURCE_DIR}/include/cute/layout.hpp")
set(cuda_host_adapter_file "${CUTLASS_SOURCE_DIR}/include/cutlass/cuda_host_adapter.hpp")
set(exmy_base_file "${CUTLASS_SOURCE_DIR}/include/cutlass/exmy_base.h")

neonsight_replace_once(
  "${layout_file}"
  "  auto iseq = cute::fold(make_seq<rank_v<decltype(flat_stride)>>{}, cute::tuple<>{},"
  "  [[maybe_unused]] auto iseq = cute::fold(make_seq<rank_v<decltype(flat_stride)>>{}, cute::tuple<>{},"
)

neonsight_replace_once(
  "${cuda_host_adapter_file}"
  "  virtual Status memsetDeviceImpl(
    void* destination, ///< Device memory pointer to be filled
    void const* fill_value, ///< Value to be filled in the buffer"
  "  // Patching to work around this error:
  //   include\\cutlass/cuda_host_adapter.hpp(414): error #20011-D: calling a __host__ function(\"memsetDeviceImpl\")
  //     from a __host__ __device__ function(\"memsetDevice\") is not allowed
  CUTLASS_HOST_DEVICE
  virtual Status memsetDeviceImpl(
    void* destination, ///< Device memory pointer to be filled
    void const* fill_value, ///< Value to be filled in the buffer"
)

neonsight_replace_once(
  "${exmy_base_file}"
  "  explicit float_exmy_base<T, Derived>(float x) {"
  "  explicit float_exmy_base(float x) {"
)

neonsight_replace_once(
  "${exmy_base_file}"
  "  explicit float_exmy_base<T, Derived>(int x) {"
  "  explicit float_exmy_base(int x) {"
)

neonsight_replace_once(
  "${exmy_base_file}"
  "  explicit float_exmy_base<T, Derived>(unsigned x) {"
  "  explicit float_exmy_base(unsigned x) {"
)
