// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#define HEAD_ELEMS 128
#define HEAD_DIM_NAMESPACE H128

#if defined(USE_FP8_KV_CACHE) && !defined(DISABLE_FLOAT8_TYPES)
#include "xqa_loader_fp16_fp8_impl.cuh"
#endif
