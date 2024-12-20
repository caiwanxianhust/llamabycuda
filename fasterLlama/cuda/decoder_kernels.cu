#include "decoder_kernels.cuh"
#include "cuda_kernels.cuh"
#include "utils.h"

namespace FasterLLaMA
{

    /** resNorm、量化
     * grid(batch_size * seq_len)  block(128)
     * output: [batch_size, seq_len, hidden_units]
     * input: [batch_size, seq_len, hidden_units]
     * gamma: [hidden_units, ]
     */
    template <typename DataType>
    __global__ void resNormQuantizedKernel(int8_t *__restrict__ output, const DataType *__restrict__ input, const DataType *__restrict__ gamma,
                                           float *__restrict__ norm_scale, const float eps, const int hidden_units)
    {
        const int row_id = blockIdx.x;
        const int offset = row_id * hidden_units;

        extern __shared__ float s_buf[]; // hiddent_units
        float val;
        float mean = 0.0f;
        float absmax = -1e9f;
        char4 out_val;

        for (int tid = threadIdx.x; tid < hidden_units; tid += blockDim.x)
        {
            val = static_cast<float>(input[offset + tid]);
            s_buf[tid] = val;
            mean += val * val;
            absmax = max(absmax, fabsf(val * static_cast<float>(__ldg(gamma + tid))));
        }
        __syncthreads();

        mean = blockAllReduceSum<float>(mean);
        mean = rsqrtf(mean / hidden_units + eps);

        absmax = blockAllReduceMax<float>(absmax);
        absmax *= mean;
        if (threadIdx.x == 0)
        {
            norm_scale[blockIdx.x] = absmax / 127.0f;
        }

        int target_idx;
        char4 *out_ptr = (char4 *)output;
        for (int tid = (threadIdx.x << 2); tid < hidden_units; tid += (blockDim.x << 2))
        {
            out_val.x = float_to_int8_rn(s_buf[tid] * mean * static_cast<float>(__ldg(gamma + tid)) * 127.0f / absmax);
            out_val.y = float_to_int8_rn(s_buf[tid + 1] * mean * static_cast<float>(__ldg(gamma + tid + 1)) * 127.0f / absmax);
            out_val.z = float_to_int8_rn(s_buf[tid + 2] * mean * static_cast<float>(__ldg(gamma + tid + 2)) * 127.0f / absmax);
            out_val.w = float_to_int8_rn(s_buf[tid + 3] * mean * static_cast<float>(__ldg(gamma + tid + 3)) * 127.0f / absmax);
            target_idx = row_id * hidden_units + tid;
            out_ptr[target_idx >> 2] = out_val;
        }
    }

    template <>
    __global__ void resNormQuantizedKernel(int8_t *__restrict__ output, const half *__restrict__ input, const half *__restrict__ gamma,
                                           float *__restrict__ norm_scale, const float eps, const int hidden_units)
    {
        const int row_id = blockIdx.x;
        const int offset = row_id * hidden_units;

        extern __shared__ float s_buf[]; // hiddent_units
        float val;
        float mean = 0.0f;
        float absmax = -1e9f;
        char4 out_val;

        for (int tid = threadIdx.x; tid < hidden_units; tid += blockDim.x)
        {
            val = static_cast<float>(input[offset + tid]);
            s_buf[tid] = val;
            mean += val * val;
            absmax = max(absmax, fabsf(val * __half2float(__ldg(gamma + tid))));
        }
        __syncthreads();

        mean = blockAllReduceSum<float>(mean);
        mean = rsqrtf(mean / hidden_units + eps);

        absmax = blockAllReduceMax<float>(absmax);
        absmax *= mean;
        if (threadIdx.x == 0)
        {
            norm_scale[blockIdx.x] = absmax / 127.0f;
        }

        int target_idx;
        char4 *out_ptr = (char4 *)output;
        for (int tid = (threadIdx.x << 2); tid < hidden_units; tid += (blockDim.x << 2))
        {
            out_val.x = float_to_int8_rn(s_buf[tid] * mean * __half2float(__ldg(gamma + tid)) * 127.0f / absmax);
            out_val.y = float_to_int8_rn(s_buf[tid + 1] * mean * __half2float(__ldg(gamma + tid + 1)) * 127.0f / absmax);
            out_val.z = float_to_int8_rn(s_buf[tid + 2] * mean * __half2float(__ldg(gamma + tid + 2)) * 127.0f / absmax);
            out_val.w = float_to_int8_rn(s_buf[tid + 3] * mean * __half2float(__ldg(gamma + tid + 3)) * 127.0f / absmax);
            target_idx = row_id * hidden_units + tid;
            out_ptr[target_idx >> 2] = out_val;
        }
    }

    template <typename DataType>
    void launchResNormQuantizedKernel(int8_t *output, const DataType *input, const DataType *gamma,
                                      float *norm_scale, const float eps, const int nrows, const int hidden_units, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        assert(hidden_units % 4 == 0);
        int mem_size = sizeof(float) * hidden_units;
        resNormQuantizedKernel<DataType><<<nrows, 256, mem_size, stream>>>(output, input, gamma, norm_scale, eps, hidden_units);
    }

    /** embeddingLookingUp
     * grid(batch_size, seq_len) block(128)
     * from_tensor: [batch_size, seq_len, hidden_units]
     * word_ids:    [batch_size, seq_len]
     */
    template <typename DataType>
    __global__ void embeddingLookingUpKernel(DataType *__restrict__ from_tensor, const DataType *__restrict__ embedding_table,
                                             const int *__restrict__ word_ids, const int hidden_units, const int seq_len)
    {
        const int batch_id = blockIdx.x;
        const int seq_id = blockIdx.y;
        const int offset = batch_id * seq_len * hidden_units + seq_id * hidden_units;
        const int id_for_word = word_ids[batch_id * seq_len + seq_id];
        for (int i = threadIdx.x; i < hidden_units; i += blockDim.x)
        {
            from_tensor[offset + i] = embedding_table[id_for_word * hidden_units + i];
        }
    }

    template <typename DataType>
    void launchEmbeddingLookingUpKernel(DataType *from_tensor, const DataType *embedding_table,
                                        const int *word_ids, const int hidden_units, const int batch_size, const int seq_len, cudaStream_t stream)
    {
        dim3 grid(batch_size, seq_len);
        dim3 block(128);
        embeddingLookingUpKernel<DataType><<<grid, block, 0, stream>>>(from_tensor, embedding_table, word_ids, hidden_units, seq_len);
    }

    /** perChannel 量化
     * src: [rows, clos]
     * dst: [rows, clos]
     * scale_ptr: [rows, ]
     */
    template <typename DataType>
    __global__ void perChannelQuantizedKernel(int8_t *__restrict__ dst, const DataType *__restrict__ src, float *__restrict__ scale_ptr,
                                              const int hidden_size)
    {
        const int offset = blockIdx.x * hidden_size;
        float absmax = 0.0f;
        for (int i = (threadIdx.x << 2); i < hidden_size; i += (blockDim.x << 2))
        {
            absmax = fmaxf(absmax, fabsf(static_cast<float>(__ldg(&src[offset + i]))));
            absmax = fmaxf(absmax, fabsf(static_cast<float>(__ldg(&src[offset + i + 1]))));
            absmax = fmaxf(absmax, fabsf(static_cast<float>(__ldg(&src[offset + i + 2]))));
            absmax = fmaxf(absmax, fabsf(static_cast<float>(__ldg(&src[offset + i + 3]))));
        }
        __syncthreads();
        absmax = blockAllReduceMax<float>(absmax);
        float scale = 127.0f / absmax;

        char4 *dst_ptr4 = (char4 *)(dst + offset);
        char4 tmp;
        for (int i = (threadIdx.x << 2); i < hidden_size; i += (blockDim.x << 2))
        {
            tmp.x = float_to_int8_rn(static_cast<float>(__ldg(&src[offset + i])) * scale);
            tmp.y = float_to_int8_rn(static_cast<float>(__ldg(&src[offset + i + 1])) * scale);
            tmp.z = float_to_int8_rn(static_cast<float>(__ldg(&src[offset + i + 2])) * scale);
            tmp.w = float_to_int8_rn(static_cast<float>(__ldg(&src[offset + i + 3])) * scale);
            dst_ptr4[i >> 2] = tmp;
        }
        if (threadIdx.x == 0)
        {
            scale_ptr[blockIdx.x] = absmax / 127.0f;
        }
    }

    template <typename DataType>
    void perChannelQuantizedKernelLauncher(int8_t *dst, const DataType *src, float *scale_ptr, const int hidden_size,
                                           const int nrows, cudaStream_t stream)
    {
        dim3 grid(nrows);
        dim3 block(128);
        perChannelQuantizedKernel<DataType><<<grid, block, 0, stream>>>(dst, src, scale_ptr, hidden_size);
    }

    /**
     * 反量化、rope旋转编码、量化、转置
     * Q K: [batch_size, seq_len, head_num, size_per_head]
     * grid(head_num / warp_num, seq_len, batch_size * 2) block(32, warp_num), each warp process size_per_head elements
     * q_inp_sacle k_inp_scale: [batch_size, seq_len], absmax / 127.0f
     * q_weight_scale k_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     * freq_cis: [max_seq_len, size_per_head]
     * q_out_scale k_out_scale: [batch_size, seq_len, head_num], absmax / 127.0f
     */
    __global__ void warpQKRoteEmbeddingQuantizedTransposeKernel(int8_t *q_buf, int8_t *k_buf, const int32_t *Q,
                                                                const int32_t *K, const float *q_inp_scale, const float *k_inp_scale,
                                                                const float *q_weight_scale, const float *k_weight_scale, float *q_out_scale,
                                                                float *k_out_scale, float *freq_cis, const int batch_size, const int seq_len,
                                                                const int start_pos, const int total_len, const int head_num,
                                                                const int size_per_head)
    {
        const int qk_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x * blockDim.y + threadIdx.y;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = (qk_id == 0) ? __ldg(q_inp_scale + batch_id * seq_len + seq_id) : __ldg(k_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = (qk_id == 0) ? Q + offset : K + offset;
        const float *weight_scale_ptr = (qk_id == 0) ? q_weight_scale : k_weight_scale;
        const float *freq_cis_ptr = freq_cis + seq_id * size_per_head;
        float *out_scale_ptr = (qk_id == 0) ? q_out_scale + batch_id * head_num * seq_len + head_id * seq_len + seq_id : k_out_scale + batch_id * head_num * total_len + head_id * total_len + start_pos + seq_id;
        char4 *out_ptr = (qk_id == 0) ? (char4 *)q_buf : (char4 *)k_buf;
        float4 val, rope_val;
        char4 out_val;
        float absmax = 0.0f;
        const int tid = (threadIdx.x << 2);
        float out_scale;
        int target_idx;
        if (tid < size_per_head)
        {
            // dequantized
            val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid);
            val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 1);
            val.z = static_cast<float>(data_ptr[tid + 2]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 2);
            val.w = static_cast<float>(data_ptr[tid + 3]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 3);

            // rope embedding
            rope_val.x = val.x * freq_cis_ptr[tid] - val.y * freq_cis_ptr[tid + 1];
            rope_val.y = val.y * freq_cis_ptr[tid] + val.x * freq_cis_ptr[tid + 1];
            rope_val.z = val.z * freq_cis_ptr[tid + 2] - val.w * freq_cis_ptr[tid + 3];
            rope_val.w = val.w * freq_cis_ptr[tid + 2] + val.z * freq_cis_ptr[tid + 3];

            // quantized
            absmax = fmaxf(absmax, fmaxf(fabsf(rope_val.x), fmaxf(fabsf(rope_val.y), fmaxf(fabsf(rope_val.z), fabsf(rope_val.w)))));
            __syncwarp();
            absmax = warpAllReduce<MaxOp, float>(absmax);
            if (tid == 0)
            {
                out_scale_ptr[0] = absmax / 127.0f;
            }
            out_scale = 127.0f / absmax;
            out_val.x = float_to_int8_rn(static_cast<float>(rope_val.x) * out_scale);
            out_val.y = float_to_int8_rn(static_cast<float>(rope_val.y) * out_scale);
            out_val.z = float_to_int8_rn(static_cast<float>(rope_val.z) * out_scale);
            out_val.w = float_to_int8_rn(static_cast<float>(rope_val.w) * out_scale);

            // transpose
            target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
            out_ptr[target_idx >> 2] = out_val;
        }
    }

    /**
     * 反量化、rope旋转编码、量化、转置
     * Q K: [batch_size, seq_len, head_num, size_per_head]
     * grid(head_num, seq_len, batch_size * 2) block(128), each block process size_per_head(256) elements
     * q_inp_sacle k_inp_scale: [batch_size, seq_len], absmax / 127.0f
     * q_weight_scale k_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     * freq_cis: [max_seq_len, size_per_head]
     * q_out_scale k_out_scale: [batch_size, seq_len, head_num], absmax / 127.0f
     */
    __global__ void blockQKRoteEmbeddingQuantizedTransposeForDim256Kernel(int8_t *q_buf, int8_t *k_buf, const int32_t *Q,
                                                                          const int32_t *K, const float *q_inp_scale, const float *k_inp_scale,
                                                                          const float *q_weight_scale, const float *k_weight_scale, float *q_out_scale,
                                                                          float *k_out_scale, float *freq_cis, const int batch_size, const int seq_len,
                                                                          const int start_pos, const int total_len, const int head_num,
                                                                          const int size_per_head)
    {
        const int qk_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = (qk_id == 0) ? __ldg(q_inp_scale + batch_id * seq_len + seq_id) : __ldg(k_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = (qk_id == 0) ? Q + offset : K + offset;
        const float *weight_scale_ptr = (qk_id == 0) ? q_weight_scale : k_weight_scale;
        const float *freq_cis_ptr = freq_cis + seq_id * size_per_head;
        float *out_scale_ptr = (qk_id == 0) ? q_out_scale + batch_id * head_num * seq_len + head_id * seq_len + seq_id : k_out_scale + batch_id * head_num * total_len + head_id * total_len + start_pos + seq_id;
        char2 *out_ptr = (qk_id == 0) ? (char2 *)q_buf : (char2 *)k_buf;
        float2 val, rope_val;
        char2 out_val;
        float absmax = 0.0f;
        const int tid = (threadIdx.x << 1);
        float out_scale;
        int target_idx;
        // dequantized
        val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid);
        val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 1);

        // rope embedding
        rope_val.x = val.x * freq_cis_ptr[tid] - val.y * freq_cis_ptr[tid + 1];
        rope_val.y = val.y * freq_cis_ptr[tid] + val.x * freq_cis_ptr[tid + 1];

        // quantized
        absmax = fmaxf(absmax, fmaxf(fabsf(rope_val.x), fabsf(rope_val.y)));
        __syncthreads();
        absmax = blockAllReduceMax<float>(absmax);
        if (tid == 0)
        {
            out_scale_ptr[0] = absmax / 127.0f;
        }
        out_scale = 127.0f / absmax;
        out_val.x = float_to_int8_rn(static_cast<float>(rope_val.x) * out_scale);
        out_val.y = float_to_int8_rn(static_cast<float>(rope_val.y) * out_scale);

        // transpose
        target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
        out_ptr[target_idx >> 1] = out_val;
    }

    /**
     * 反量化、rope旋转编码、量化、转置
     * Q K: [batch_size, seq_len, head_num, size_per_head]
     * grid(head_num, seq_len, batch_size * 2) block(size_per_head / 4), each block process size_per_head elements
     * q_inp_sacle k_inp_scale: [batch_size, seq_len], absmax / 127.0f
     * q_weight_scale k_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     * freq_cis: [max_seq_len, size_per_head]
     * q_out_scale k_out_scale: [batch_size, head_num, seq_len], absmax / 127.0f
     */
    __global__ void blockQKRoteEmbeddingQuantizedTransposeKernel(int8_t *q_buf, int8_t *k_buf, const int32_t *Q,
                                                                 const int32_t *K, const float *q_inp_scale, const float *k_inp_scale,
                                                                 const float *q_weight_scale, const float *k_weight_scale, float *q_out_scale,
                                                                 float *k_out_scale, float *freq_cis, const int batch_size, const int seq_len,
                                                                 const int start_pos, const int total_len, const int head_num,
                                                                 const int size_per_head)
    {
        const int qk_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = (qk_id == 0) ? __ldg(q_inp_scale + batch_id * seq_len + seq_id) : __ldg(k_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = (qk_id == 0) ? Q + offset : K + offset;
        const float *weight_scale_ptr = (qk_id == 0) ? q_weight_scale : k_weight_scale;
        const float *freq_cis_ptr = freq_cis + seq_id * size_per_head;
        float *out_scale_ptr = (qk_id == 0) ? q_out_scale + batch_id * head_num * seq_len + head_id * seq_len + seq_id : k_out_scale + batch_id * head_num * total_len + head_id * total_len + start_pos + seq_id;
        char4 *out_ptr = (qk_id == 0) ? (char4 *)q_buf : (char4 *)k_buf;
        float4 val, rope_val;
        char4 out_val;
        float absmax = 0.0f;
        const int tid = (threadIdx.x << 2);
        float out_scale;
        int target_idx;

        // dequantized
        val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid);
        val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 1);
        val.z = static_cast<float>(data_ptr[tid + 2]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 2);
        val.w = static_cast<float>(data_ptr[tid + 3]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 3);

        // rope embedding
        rope_val.x = val.x * freq_cis_ptr[tid] - val.y * freq_cis_ptr[tid + 1];
        rope_val.y = val.y * freq_cis_ptr[tid] + val.x * freq_cis_ptr[tid + 1];
        rope_val.z = val.z * freq_cis_ptr[tid + 2] - val.w * freq_cis_ptr[tid + 3];
        rope_val.w = val.w * freq_cis_ptr[tid + 2] + val.z * freq_cis_ptr[tid + 3];

        // quantized
        absmax = fmaxf(absmax, fmaxf(fabsf(rope_val.x), fmaxf(fabsf(rope_val.y), fmaxf(fabsf(rope_val.z), fabsf(rope_val.w)))));
        __syncthreads();
        absmax = blockAllReduceMax<float>(absmax);
        if (tid == 0)
        {
            out_scale_ptr[0] = absmax / 127.0f;
        }
        out_scale = 127.0f / absmax;
        out_val.x = float_to_int8_rn(static_cast<float>(rope_val.x) * out_scale);
        out_val.y = float_to_int8_rn(static_cast<float>(rope_val.y) * out_scale);
        out_val.z = float_to_int8_rn(static_cast<float>(rope_val.z) * out_scale);
        out_val.w = float_to_int8_rn(static_cast<float>(rope_val.w) * out_scale);

        // transpose
        target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
        out_ptr[target_idx >> 2] = out_val;
    }

    void launchQKRoteEmbeddingQuantizedTranspose(int8_t *q_buf, int8_t *k_buf, const int32_t *Q,
                                                 const int32_t *K, const float *q_inp_scale, const float *k_inp_scale,
                                                 const float *q_weight_scale, const float *k_weight_scale, float *q_out_scale,
                                                 float *k_out_scale, float *freq_cis, const int batch_size, const int seq_len,
                                                 const int start_pos, const int total_len, const int head_num,
                                                 const int size_per_head, cudaStream_t stream)
    {
        assert(size_per_head <= 1024);
        if (size_per_head <= 128)
        {
            int warp_num = 4;
            dim3 grid(head_num / warp_num, seq_len, batch_size * 2);
            dim3 block(32, warp_num);
            warpQKRoteEmbeddingQuantizedTransposeKernel<<<grid, block, 0, stream>>>(q_buf, k_buf, Q, K, q_inp_scale, k_inp_scale,
                                                                                    q_weight_scale, k_weight_scale, q_out_scale, k_out_scale, freq_cis, batch_size, seq_len, start_pos, total_len, head_num, size_per_head);
        }
        else if (size_per_head == 256)
        {
            dim3 grid(head_num, seq_len, batch_size * 2);
            dim3 block(128);
            blockQKRoteEmbeddingQuantizedTransposeForDim256Kernel<<<grid, block, 0, stream>>>(q_buf, k_buf, Q, K, q_inp_scale, k_inp_scale,
                                                                                              q_weight_scale, k_weight_scale, q_out_scale, k_out_scale, freq_cis, batch_size, seq_len, start_pos, total_len, head_num, size_per_head);
        }
        else if (size_per_head == 512 || size_per_head == 1024)
        {
            dim3 grid(head_num, seq_len, batch_size * 2);
            dim3 block(size_per_head / 4);
            blockQKRoteEmbeddingQuantizedTransposeKernel<<<grid, block, 0, stream>>>(q_buf, k_buf, Q, K, q_inp_scale, k_inp_scale,
                                                                                     q_weight_scale, k_weight_scale, q_out_scale, k_out_scale, freq_cis, batch_size, seq_len, start_pos, total_len, head_num, size_per_head);
        }
        else
        {
            throw "invalid size_per_head!";
        }
    }

    /**
     * 反量化、rope旋转编码、转置
     * Q K: [batch_size, seq_len, head_num, size_per_head]
     * grid(head_num / warp_num, seq_len, batch_size * 2) block(32, warp_num), each warp process size_per_head elements
     * q_inp_sacle k_inp_scale: [batch_size, seq_len], absmax / 127.0f
     * q_weight_scale k_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     * freq_cis: [max_seq_len, size_per_head]
     */
    __global__ void warpQKRoteEmbeddingTransposeKernel(float *q_buf, float *k_buf, const int32_t *Q,
                                                       const int32_t *K, const float *q_inp_scale, const float *k_inp_scale,
                                                       const float *q_weight_scale, const float *k_weight_scale, const float *freq_cis,
                                                       const int batch_size, const int seq_len,
                                                       const int start_pos, const int total_len, const int head_num,
                                                       const int size_per_head)
    {
        const int qk_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x * blockDim.y + threadIdx.y;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = (qk_id == 0) ? __ldg(q_inp_scale + batch_id * seq_len + seq_id) : __ldg(k_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = (qk_id == 0) ? Q + offset : K + offset;
        const float *weight_scale_ptr = (qk_id == 0) ? q_weight_scale : k_weight_scale;
        const float *freq_cis_ptr = freq_cis + seq_id * size_per_head;

        float4 *out_ptr = (qk_id == 0) ? (float4 *)q_buf : (float4 *)k_buf;
        float4 val, rope_val;
        const int tid = (threadIdx.x << 2);
        int target_idx;
        if (tid < size_per_head)
        {
            // dequantized
            val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid);
            val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 1);
            val.z = static_cast<float>(data_ptr[tid + 2]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 2);
            val.w = static_cast<float>(data_ptr[tid + 3]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 3);

            // rope embedding
            rope_val.x = val.x * freq_cis_ptr[tid] - val.y * freq_cis_ptr[tid + 1];
            rope_val.y = val.y * freq_cis_ptr[tid] + val.x * freq_cis_ptr[tid + 1];
            rope_val.z = val.z * freq_cis_ptr[tid + 2] - val.w * freq_cis_ptr[tid + 3];
            rope_val.w = val.w * freq_cis_ptr[tid + 2] + val.z * freq_cis_ptr[tid + 3];

            // transpose
            target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
            out_ptr[target_idx >> 2] = rope_val;
        }
    }

    /**
     * 反量化、rope旋转编码、转置
     * Q K: [batch_size, seq_len, head_num, size_per_head]
     * grid(head_num, seq_len, batch_size * 2) block(128), each block process size_per_head(256) elements
     * q_inp_sacle k_inp_scale: [batch_size, seq_len], absmax / 127.0f
     * q_weight_scale k_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     * freq_cis: [max_seq_len, size_per_head]
     */
    __global__ void blockQKRoteEmbeddingTransposeForDim256Kernel(float *q_buf, float *k_buf, const int32_t *Q,
                                                                 const int32_t *K, const float *q_inp_scale, const float *k_inp_scale,
                                                                 const float *q_weight_scale, const float *k_weight_scale,
                                                                 const float *freq_cis, const int batch_size, const int seq_len,
                                                                 const int start_pos, const int total_len, const int head_num,
                                                                 const int size_per_head)
    {
        const int qk_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = (qk_id == 0) ? __ldg(q_inp_scale + batch_id * seq_len + seq_id) : __ldg(k_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = (qk_id == 0) ? Q + offset : K + offset;
        const float *weight_scale_ptr = (qk_id == 0) ? q_weight_scale : k_weight_scale;
        const float *freq_cis_ptr = freq_cis + seq_id * size_per_head;
        float2 *out_ptr = (qk_id == 0) ? (float2 *)q_buf : (float2 *)k_buf;
        float2 val, rope_val;
        const int tid = (threadIdx.x << 1);
        int target_idx;
        // dequantized
        val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid);
        val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 1);

        // rope embedding
        rope_val.x = val.x * freq_cis_ptr[tid] - val.y * freq_cis_ptr[tid + 1];
        rope_val.y = val.y * freq_cis_ptr[tid] + val.x * freq_cis_ptr[tid + 1];

        // transpose
        target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
        out_ptr[target_idx >> 1] = rope_val;
    }

    /**
     * 反量化、rope旋转编码、转置
     * Q K: [batch_size, seq_len, head_num, size_per_head]
     * grid(head_num, seq_len, batch_size * 2) block(size_per_head / 4), each block process size_per_head elements
     * q_inp_sacle k_inp_scale: [batch_size, seq_len], absmax / 127.0f
     * q_weight_scale k_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     * freq_cis: [max_seq_len, size_per_head]
     */
    __global__ void blockQKRoteEmbeddingTransposeKernel(float *q_buf, float *k_buf, const int32_t *Q,
                                                        const int32_t *K, const float *q_inp_scale, const float *k_inp_scale,
                                                        const float *q_weight_scale, const float *k_weight_scale,
                                                        const float *freq_cis, const int batch_size, const int seq_len,
                                                        const int start_pos, const int total_len, const int head_num,
                                                        const int size_per_head)
    {
        const int qk_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = (qk_id == 0) ? __ldg(q_inp_scale + batch_id * seq_len + seq_id) : __ldg(k_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = (qk_id == 0) ? Q + offset : K + offset;
        const float *weight_scale_ptr = (qk_id == 0) ? q_weight_scale : k_weight_scale;
        const float *freq_cis_ptr = freq_cis + seq_id * size_per_head;
        float4 *out_ptr = (qk_id == 0) ? (float4 *)q_buf : (float4 *)k_buf;
        float4 val, rope_val;
        const int tid = (threadIdx.x << 2);
        int target_idx;

        // dequantized
        val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid);
        val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 1);
        val.z = static_cast<float>(data_ptr[tid + 2]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 2);
        val.w = static_cast<float>(data_ptr[tid + 3]) * inp_scale_val * __ldg(weight_scale_ptr + head_id * size_per_head + tid + 3);

        // rope embedding
        rope_val.x = val.x * freq_cis_ptr[tid] - val.y * freq_cis_ptr[tid + 1];
        rope_val.y = val.y * freq_cis_ptr[tid] + val.x * freq_cis_ptr[tid + 1];
        rope_val.z = val.z * freq_cis_ptr[tid + 2] - val.w * freq_cis_ptr[tid + 3];
        rope_val.w = val.w * freq_cis_ptr[tid + 2] + val.z * freq_cis_ptr[tid + 3];

        // transpose
        target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
        out_ptr[target_idx >> 2] = rope_val;
    }

    void launchQKRoteEmbeddingTranspose(float *q_buf, float *k_buf, const int32_t *Q,
                                        const int32_t *K, const float *q_inp_scale, const float *k_inp_scale,
                                        const float *q_weight_scale, const float *k_weight_scale,
                                        const float *freq_cis, const int batch_size, const int seq_len,
                                        const int start_pos, const int total_len, const int head_num,
                                        const int size_per_head, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        assert(size_per_head <= 1024 && head_num >= 4);
        if (size_per_head <= 128)
        {
            int warp_num = 4;
            dim3 grid(head_num / warp_num, seq_len, batch_size * 2);
            dim3 block(32, warp_num);
            warpQKRoteEmbeddingTransposeKernel<<<grid, block, 0, stream>>>(q_buf, k_buf, Q, K, q_inp_scale, k_inp_scale,
                                                                           q_weight_scale, k_weight_scale, freq_cis, batch_size, seq_len, start_pos, total_len, head_num, size_per_head);
        }
        else if (size_per_head == 256)
        {
            dim3 grid(head_num, seq_len, batch_size * 2);
            dim3 block(128);
            blockQKRoteEmbeddingTransposeForDim256Kernel<<<grid, block, 0, stream>>>(q_buf, k_buf, Q, K, q_inp_scale, k_inp_scale,
                                                                                     q_weight_scale, k_weight_scale, freq_cis, batch_size, seq_len, start_pos, total_len, head_num, size_per_head);
        }
        else if (size_per_head == 512 || size_per_head == 1024)
        {
            dim3 grid(head_num, seq_len, batch_size * 2);
            dim3 block(size_per_head / 4);
            blockQKRoteEmbeddingTransposeKernel<<<grid, block, 0, stream>>>(q_buf, k_buf, Q, K, q_inp_scale, k_inp_scale,
                                                                            q_weight_scale, k_weight_scale, freq_cis, batch_size, seq_len, start_pos, total_len, head_num, size_per_head);
        }
        else
        {
            throw "invalid size_per_head!";
        }
    }

    /**
     * grid: [seq_len, head_num / blockDim.y, batch_size * 2]  block(size_per_head / 4, 256 / (size_per_head / 4))
     * k_cache v_cache: [batch_size, head_num, max_seq_len, size_per_head]
     * K V : [batch_size, head_num, seq_len, size_per_head]
     */
    __global__ void storeKVcacheKernel(float *__restrict__ k_cache, float *__restrict__ v_cache, const float *__restrict__ K,
                                       const float *__restrict__ V, const int start_pos, const int seq_len, const int batch_size, const int head_num,
                                       const int max_seq_len, const int size_per_head)
    {
        const int kv_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int head_id = blockIdx.y * blockDim.y + threadIdx.y;
        const int seq_id = blockIdx.x;
        const int offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
        const int cache_offset = batch_id * head_num * max_seq_len * size_per_head + head_id * max_seq_len * size_per_head +
                                 (start_pos + seq_id) * size_per_head;
        float4 *cache_ptr = (kv_id == 0) ? (float4 *)(k_cache + cache_offset) : (float4 *)(v_cache + cache_offset);
        const float4 *data_ptr = (kv_id == 0) ? (const float4 *)(K + offset) : (const float4 *)(V + offset);
        cache_ptr[threadIdx.x] = data_ptr[threadIdx.x];
    }

    /**
     * grid: [seq_len, head_num, batch_size * 2]  block(size_per_head)
     * k_cache v_cache: [batch_size, head_num, max_seq_len, size_per_head]
     * K V : [batch_size, head_num, seq_len, size_per_head]
     */
    __global__ void storeKVcacheBlockKernel(float *__restrict__ k_cache, float *__restrict__ v_cache, const float *__restrict__ K,
                                            const float *__restrict__ V, const int start_pos, const int seq_len, const int batch_size, const int head_num,
                                            const int max_seq_len, const int size_per_head)
    {
        const int kv_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int head_id = blockIdx.y;
        const int seq_id = blockIdx.x;
        const int offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
        const int cache_offset = batch_id * head_num * max_seq_len * size_per_head + head_id * max_seq_len * size_per_head +
                                 (start_pos + seq_id) * size_per_head;
        float *cache_ptr = (kv_id == 0) ? (k_cache + cache_offset) : (v_cache + cache_offset);
        const float *data_ptr = (kv_id == 0) ? (const float *)(K + offset) : (const float *)(V + offset);
        cache_ptr[threadIdx.x] = data_ptr[threadIdx.x];
    }

    void launchStoreKVcacheKernel(float *k_cache, float *v_cache, const float *K, const float *V, const int start_pos, const int seq_len,
                                  const int batch_size, const int head_num, const int max_seq_len, const int size_per_head, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        assert(size_per_head <= 1024 && size_per_head % 32 == 0);
        dim3 block, grid;
        if (size_per_head >= 128)
        {
            block.x = size_per_head / 4;
            block.y = 256 / block.x;
            grid.x = seq_len;
            assert(grid.y >= 1);
            grid.y = head_num / block.y;
            grid.z = batch_size * 2;
            storeKVcacheKernel<<<grid, block, 0, stream>>>(k_cache, v_cache, K, V, start_pos, seq_len, batch_size, head_num, max_seq_len,
                                                           size_per_head);
        }
        else
        {
            grid.x = seq_len;
            grid.y = head_num;
            grid.z = batch_size * 2;
            block.x = size_per_head;
            storeKVcacheBlockKernel<<<grid, block, 0, stream>>>(k_cache, v_cache, K, V, start_pos, seq_len, batch_size, head_num, max_seq_len,
                                                                size_per_head);
        }
    }

    /**
     * grid: [seq_len, head_num / blockDim.y, batch_size * 2]  block(size_per_head / 4, 256 / (size_per_head / 4))
     * k_cache v_cache: [batch_size, head_num, max_seq_len, size_per_head]
     * K V : [batch_size, head_num, seq_len, size_per_head]
     */
    __global__ void storeINT8KVcacheKernel(int8_t *__restrict__ k_cache, int8_t *__restrict__ v_cache, const int8_t *__restrict__ K,
                                           const int8_t *__restrict__ V, const int start_pos, const int seq_len, const int batch_size, const int head_num,
                                           const int max_seq_len, const int size_per_head)
    {
        const int kv_id = blockIdx.z / batch_size;
        const int batch_id = blockIdx.z % batch_size;
        const int head_id = blockIdx.y * blockDim.y + threadIdx.y;
        const int seq_id = blockIdx.x;
        const int offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
        const int cache_offset = batch_id * head_num * max_seq_len * size_per_head + head_id * max_seq_len * size_per_head +
                                 (start_pos + seq_id) * size_per_head;
        char4 *cache_ptr = (kv_id == 0) ? (char4 *)(k_cache + cache_offset) : (char4 *)(v_cache + cache_offset);
        const char4 *data_ptr = (kv_id == 0) ? (const char4 *)(K + offset) : (const char4 *)(V + offset);
        cache_ptr[threadIdx.x] = data_ptr[threadIdx.x];
    }

    void launchINT8StoreKVcacheKernel(int8_t *k_cache, int8_t *v_cache, const int8_t *K, const int8_t *V, const int start_pos, const int seq_len,
                                      const int batch_size, const int head_num, const int max_seq_len, const int size_per_head, cudaStream_t stream)
    {
        assert(size_per_head <= 1024);
        dim3 block, grid;
        block.x = size_per_head / 4;
        assert(block.x >= 1);
        block.y = 256 / block.x;
        grid.x = seq_len;
        grid.y = head_num / block.y;
        assert(grid.y >= 1);
        grid.z = batch_size * 2;

        storeINT8KVcacheKernel<<<grid, block, 0, stream>>>(k_cache, v_cache, K, V, start_pos, seq_len, batch_size, head_num, max_seq_len,
                                                           size_per_head);
    }

    /**从 K cache 拷贝数据用于后续 gemm
     * grid(end_seq_id, head_num * batch_size) block(128)
     * from [batch_size, head_num, total_len, size_per_head] to [batch_size, head_num, end_seq_id, size_per_head]
     */
    __global__ void copyKFromCacheKernel(int8_t *__restrict__ k_buf, const int8_t *__restrict__ k_cache,
                                         const int nrows, const int total_len, const int end_seq_id, const int size_per_head)
    {
        const int row_id = blockIdx.y;
        const int seq_id = blockIdx.x;
        const int offset = row_id * total_len * size_per_head + seq_id * size_per_head;
        const int out_offset = row_id * end_seq_id * size_per_head + seq_id * size_per_head;
        char4 *k_ptr = (char4 *)(k_cache + offset);
        char4 *k_out_ptr = (char4 *)(k_buf + out_offset);
        for (int tid = threadIdx.x; tid < (size_per_head >> 2); tid++)
        {
            k_out_ptr[tid] = k_ptr[tid];
        }
    }

    void launchCopyKFromCacheKernel(int8_t *k_buf, const int8_t *k_cache, const int nrows, const int total_len,
                                    const int end_seq_id, const int size_per_head, cudaStream_t stream)
    {
        assert(size_per_head % 4 == 0);
        dim3 grid(end_seq_id, nrows * 2);
        dim3 block(128);
        copyKFromCacheKernel<<<grid, block, 0, stream>>>(k_buf, k_cache, nrows, total_len, end_seq_id, size_per_head);
    }

    /**
     * 反量化、softmax、量化
     * grid(seq_len_q, head_num, batch_size), block(128), each block process seq_len_k elements
     * qk score: [batch_size, head_num, seq_len_q, seq_len_k]
     * atten_mask: [max_seq_len, max_seq_len]
     * q_inp_scale: [batch_size, head_num, seq_len_q]
     * k_inp_scale: [batch_size, head_num, seq_len_k]
     * score_scale: [batch_size, head_num, seq_len_q]
     *
     */
    __global__ void blockDeQuantizedSoftmaxQuantizedKernel(int8_t *__restrict__ score, const int32_t *__restrict__ qk, const float *__restrict__ attn_mask,
                                                           const float *__restrict__ q_inp_scale, const float *__restrict__ k_inp_scale, float *__restrict__ score_scale,
                                                           const float attn_scale, const int batch_size, const int head_num, const int seq_len_q, const int seq_len_k, const int max_seq_len)
    {
        const int batch_id = blockIdx.z;
        const int head_id = blockIdx.y;
        const int seq_q_id = blockIdx.x;
        const int offset = batch_id * head_num * seq_len_q * seq_len_k + head_id * seq_len_q * seq_len_k + seq_q_id * seq_len_k;
        const int k_scale_offset = batch_id * head_num * seq_len_k + head_id * seq_len_k;
        const float q_inp_scale_val = q_inp_scale[batch_id * head_num * seq_len_q + head_id * seq_len_q + seq_q_id];
        const int mask_offset = seq_q_id * max_seq_len;
        extern __shared__ float s_buf[];
        float val, mask_val;
        float sum_val = 0.0f;
        float max_val = -1e9f;
        for (int i = threadIdx.x; i < seq_len_k; i += blockDim.x)
        {
            // dequantized
            val = static_cast<float>(qk[offset + i]) * q_inp_scale_val * k_inp_scale[k_scale_offset + i];
            mask_val = (attn_mask) ? attn_mask[mask_offset + i] : 0.0f;
            val = val * attn_scale + mask_val;
            s_buf[i] = val;
            max_val = max(max_val, val);
        }
        __syncthreads();
        max_val = blockAllReduceMax<float>(max_val);

        for (int i = threadIdx.x; i < seq_len_k; i += blockDim.x)
        {
            val = expf(s_buf[i] - max_val);
            sum_val += val;
            score[offset + i] = float_to_int8_rn(val * 127.0f);
        }
        __syncthreads();
        sum_val = blockAllReduceSum<float>(sum_val);

        if (threadIdx.x == 0)
        {
            score_scale[batch_id * head_num * seq_len_q + head_id * seq_len_q + seq_q_id] = 1.0f / (127.0f * (sum_val + 1e-7f));
        }
    }

    void launchBlockDeQuantizedSoftmaxQuantizedKernel(int8_t *score, const int32_t *qk, const float *attn_mask, const float *q_inp_scale,
                                                      const float *k_inp_scale, float *score_scale, const float attn_scale, const int batch_size, const int head_num,
                                                      const int seq_len_q, const int seq_len_k, const int max_seq_len, cudaStream_t stream)
    {
        dim3 grid(seq_len_q, head_num, batch_size);
        dim3 block(128);
        int shared_mem_size = sizeof(float) * seq_len_k;
        blockDeQuantizedSoftmaxQuantizedKernel<<<grid, block, shared_mem_size, stream>>>(score, qk, attn_mask, q_inp_scale, k_inp_scale, score_scale, attn_scale,
                                                                                         batch_size, head_num, seq_len_q, seq_len_k, max_seq_len);
    }

    /**
     * softmax
     * grid(seq_len_q, head_num, batch_size), block(128), each block process seq_len_k elements
     * qk score: [batch_size, head_num, seq_len_q, seq_len_k]
     * atten_mask: [max_seq_len, max_seq_len]
     *
     */
    __global__ void blockSoftmaxKernel(float *__restrict__ qk, const float *__restrict__ attn_mask, const int batch_size,
                                       const int head_num, const int seq_len_q, const int seq_len_k, const int max_seq_len, const float scaler)
    {
        const int batch_id = blockIdx.z;
        const int head_id = blockIdx.y;
        const int seq_q_id = blockIdx.x;
        const int offset = batch_id * head_num * seq_len_q * seq_len_k + head_id * seq_len_q * seq_len_k + seq_q_id * seq_len_k;
        const int mask_offset = seq_q_id * max_seq_len;
        extern __shared__ float s_buf[];
        float val, mask_val;
        float sum_val = 0.0f;
        float max_val = -1e9f;
        for (int i = threadIdx.x; i < seq_len_k; i += blockDim.x)
        {
            mask_val = (attn_mask) ? attn_mask[mask_offset + i] : 0.0f;
            val = qk[offset + i] * scaler + mask_val;
            s_buf[i] = val;
            max_val = max(max_val, val);
        }
        __syncthreads();
        max_val = blockAllReduceMax<float>(max_val);

        for (int i = threadIdx.x; i < seq_len_k; i += blockDim.x)
        {
            val = expf(s_buf[i] - max_val);
            sum_val += val;
            s_buf[i] = val;
        }
        __syncthreads();
        sum_val = blockAllReduceSum<float>(sum_val);

        for (int i = threadIdx.x; i < seq_len_k; i += blockDim.x)
        {
            qk[offset + i] = s_buf[i] / sum_val;
        }
    }

    void launchBlockSoftmaxKernel(float *qk, const float *attn_mask, const int batch_size, const int head_num, const int seq_len_q,
                                  const int seq_len_k, const int max_seq_len, const float scaler, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        dim3 grid(seq_len_q, head_num, batch_size);
        dim3 block(128);
        int shared_mem_size = sizeof(float) * seq_len_k;
        blockSoftmaxKernel<<<grid, block, shared_mem_size, stream>>>(qk, attn_mask, batch_size, head_num, seq_len_q, seq_len_k,
                                                                     max_seq_len, scaler);
    }

    /**
     * 反量化、转置
     * grid(head_num / warp_num, seq_len, batch_size) block(32, warp_num), each warp process size_per_head elements
     * V: [batch_size, seq_len, head_num, size_per_head]
     * v_buf: [batch_size, head_num, seq_len, size_per_head]
     * v_inp_sacle: [batch_size, seq_len], absmax / 127.0f
     * v_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     */
    __global__ void warpDequantizedVTransposeKernel(float *__restrict__ v_buf, const int32_t *__restrict__ V,
                                                    const float *__restrict__ v_inp_scale, const float *__restrict__ v_weight_scale,
                                                    const int batch_size, const int seq_len, const int head_num, const int size_per_head)
    {
        const int batch_id = blockIdx.z;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x * blockDim.y + threadIdx.y;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = __ldg(v_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = V + offset;
        float4 *out_ptr = (float4 *)v_buf;
        float4 val;
        const int tid = (threadIdx.x << 2);
        int target_idx;
        if (tid < size_per_head)
        {
            // dequantized
            val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid);
            val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid + 1);
            val.z = static_cast<float>(data_ptr[tid + 2]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid + 2);
            val.w = static_cast<float>(data_ptr[tid + 3]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid + 3);

            // transpose
            target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
            out_ptr[target_idx >> 2] = val;
        }
    }

    /**
     * 反量化、转置
     * grid(head_num, seq_len, batch_size) block(128), each block process size_per_head elements
     * V: [batch_size, seq_len, head_num, size_per_head]
     * v_buf: [batch_size, head_num, seq_len, size_per_head]
     * v_inp_sacle: [batch_size, seq_len], absmax / 127.0f
     * v_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     */
    __global__ void blockDequantizedVTransposeFor256Kernel(float *__restrict__ v_buf, const int32_t *__restrict__ V,
                                                           const float *__restrict__ v_inp_scale, const float *__restrict__ v_weight_scale,
                                                           const int batch_size, const int seq_len, const int head_num, const int size_per_head)
    {
        const int batch_id = blockIdx.z;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = __ldg(v_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = V + offset;

        float2 *out_ptr = (float2 *)v_buf;
        float2 val;
        const int tid = (threadIdx.x << 1);
        int target_idx;

        // dequantized
        val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid);
        val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid + 1);

        // transpose
        target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
        out_ptr[target_idx >> 1] = val;
    }

    /**
     * 反量化、转置
     * grid(head_num, seq_len, batch_size) block(size_per_head / 4), each block process size_per_head elements
     * V: [batch_size, seq_len, head_num, size_per_head]
     * v_buf: [batch_size, head_num, seq_len, size_per_head]
     * v_inp_sacle: [batch_size, seq_len], absmax / 127.0f
     * v_weight_scale: [head_num * size_per_head, ], absmax / 127.0f
     */
    __global__ void blockDequantizedVTransposeKernel(float *__restrict__ v_buf, const int32_t *__restrict__ V,
                                                     const float *__restrict__ v_inp_scale, const float *__restrict__ v_weight_scale,
                                                     const int batch_size, const int seq_len, const int head_num, const int size_per_head)
    {
        const int batch_id = blockIdx.z;
        const int seq_id = blockIdx.y;
        const int head_id = blockIdx.x;
        const int offset = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head;
        const float inp_scale_val = __ldg(v_inp_scale + batch_id * seq_len + seq_id);
        const int32_t *data_ptr = V + offset;
        float4 *out_ptr = (float4 *)v_buf;
        float4 val;
        const int tid = (threadIdx.x << 2);
        int target_idx;

        // dequantized
        val.x = static_cast<float>(data_ptr[tid]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid);
        val.y = static_cast<float>(data_ptr[tid + 1]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid + 1);
        val.z = static_cast<float>(data_ptr[tid + 2]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid + 2);
        val.w = static_cast<float>(data_ptr[tid + 3]) * inp_scale_val * __ldg(v_weight_scale + head_id * size_per_head + tid + 3);

        // transpose
        target_idx = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head + tid;
        out_ptr[target_idx >> 2] = val;
    }

    void launchDequantizedVTransposeKernel(float *v_buf, const int32_t *V, const float *v_inp_scale, const float *v_weight_scale,
                                           const int batch_size, const int seq_len, const int head_num, const int size_per_head, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        assert(size_per_head <= 1024);
        if (size_per_head <= 128)
        {
            int warp_num = 128 / 32;
            dim3 grid(head_num / warp_num, seq_len, batch_size);
            dim3 block(32, warp_num);
            warpDequantizedVTransposeKernel<<<grid, block, 0, stream>>>(v_buf, V, v_inp_scale, v_weight_scale, batch_size,
                                                                        seq_len, head_num, size_per_head);
        }
        else if (size_per_head == 256)
        {
            dim3 grid(head_num, seq_len, batch_size);
            dim3 block(128);
            blockDequantizedVTransposeFor256Kernel<<<grid, block, 0, stream>>>(v_buf, V, v_inp_scale, v_weight_scale,
                                                                               batch_size, seq_len, head_num, size_per_head);
        }
        else if (size_per_head == 512 || size_per_head == 1024)
        {
            dim3 grid(head_num, seq_len, batch_size);
            dim3 block(size_per_head / 4);
            blockDequantizedVTransposeKernel<<<grid, block, 0, stream>>>(v_buf, V, v_inp_scale, v_weight_scale,
                                                                         batch_size, seq_len, head_num, size_per_head);
        }
        else
        {
            throw "invalid size_per_head!";
        }
    }

    /**
     * 量化
     * grid(head_num, batch_size) block(size_per_head), each warp process seq_len elements
     * V: [batch_size, head_num, seq_len, size_per_head]
     * v_buf: [batch_size, head_num, seq_len, size_per_head]
     * v_out_scale: [batch_size, head_num, 1, size_per_head], absmax / 127.0f
     */
    __global__ void blockVQuantizedKernel(int8_t *__restrict__ v_buf, const float *__restrict__ V, float *__restrict__ v_out_scale,
                                          const int batch_size, const int seq_len, const int head_num, const int size_per_head)
    {
        const int batch_id = blockIdx.y;
        const int head_id = blockIdx.x;
        int offset;
        int scale_offset = batch_id * head_num * size_per_head + head_id * size_per_head;
        float absmax = -1e9f;

        if (threadIdx.x < size_per_head)
        {
            for (int seq_id = 0; seq_id < seq_len; ++seq_id)
            {
                offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
                absmax = max(absmax, fabsf(V[offset + threadIdx.x]));
            }
            v_out_scale[scale_offset + threadIdx.x] = absmax / 127.0f;

            for (int seq_id = 0; seq_id < seq_len; ++seq_id)
            {
                offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
                v_buf[offset + threadIdx.x] = float_to_int8_rn(V[offset + threadIdx.x] * 127.0f / absmax);
            }
        }
    }

    void launchBlockVQuantizedKernel(int8_t *v_buf, const float *V, float *v_out_scale, const int batch_size, const int seq_len,
                                     const int head_num, const int size_per_head, cudaStream_t stream)
    {
        assert(size_per_head <= 1024 && (size_per_head & 0x1f) == 0);
        dim3 grid(head_num, batch_size);
        dim3 block(size_per_head);
        blockVQuantizedKernel<<<grid, block, 0, stream>>>(v_buf, V, v_out_scale, batch_size, seq_len, head_num, size_per_head);
    }

    /** 反量化、量化、转置
     * grid(seq_len, batch_size) block(32 * head_num)
     * attn_buf:[batch_size, seq_len, head_num, size_per_head]
     * attn:[batch_size, head_num, seq_len, size_per_head]
     * score_scale:[batch_size, head_num, seq_len]
     * v_scale:[batch_size, head_num, size_per_head]
     * attn_out_scale:[batch_size, seq_len]
     */
    __global__ void warpDequantizedAttnQuantizedTransposeKernel(int8_t *__restrict__ attn_buf, const int32_t *__restrict__ attn,
                                                                const float *__restrict__ score_scale, const float *__restrict__ v_scale, float *__restrict__ attn_out_scale, const int batch_size,
                                                                const int head_num, const int seq_len, const int size_per_head)
    {
        const int batch_id = blockIdx.y;
        const int seq_id = blockIdx.x;
        const int head_id = (threadIdx.x >> 5);
        const int tid = ((threadIdx.x & 0x1f) << 2);
        const int offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
        const float score_scale_val = __ldg(score_scale + batch_id * head_num * seq_len + head_id * seq_len + seq_id);
        const int scale_offset = batch_id * head_num * size_per_head + head_id * size_per_head;
        float4 val;
        char4 out_val;
        float absmax = -1e9f;
        int target_idx;
        char4 *out_ptr = (char4 *)attn_buf;
        if (tid < size_per_head)
        {
            val.x = static_cast<float>(attn[offset + tid]) * score_scale_val * __ldg(v_scale + scale_offset + tid);
            val.y = static_cast<float>(attn[offset + tid + 1]) * score_scale_val * __ldg(v_scale + scale_offset + tid + 1);
            val.z = static_cast<float>(attn[offset + tid + 2]) * score_scale_val * __ldg(v_scale + scale_offset + tid + 2);
            val.w = static_cast<float>(attn[offset + tid + 3]) * score_scale_val * __ldg(v_scale + scale_offset + tid + 3);

            absmax = max(absmax, max(fabsf(val.x), max(fabsf(val.y), max(fabsf(val.z), fabsf(val.w)))));
            __syncthreads();
            absmax = blockAllReduceMax<float>(absmax);
            if (tid == 0)
            {
                attn_out_scale[batch_id * seq_len + seq_id] = absmax / 127.0f;
            }

            out_val.x = float_to_int8_rn(val.x * 127.0f / absmax);
            out_val.y = float_to_int8_rn(val.y * 127.0f / absmax);
            out_val.z = float_to_int8_rn(val.z * 127.0f / absmax);
            out_val.w = float_to_int8_rn(val.w * 127.0f / absmax);

            target_idx = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head + tid;
            out_ptr[target_idx >> 2] = out_val;
        }
    }

    /** 反量化、量化、转置
     * grid(seq_len, batch_size) block(size_per_head)
     * attn_buf:[batch_size, seq_len, head_num, size_per_head]
     * attn:[batch_size, head_num, seq_len, size_per_head]
     * score_scale:[batch_size, head_num, seq_len]
     * v_scale:[batch_size, head_num, size_per_head]
     * attn_out_scale:[batch_size, seq_len]
     */
    __global__ void blockDequantizedAttnQuantizedTransposeKernel(int8_t *__restrict__ attn_buf, const int32_t *__restrict__ attn,
                                                                 const float *__restrict__ score_scale, const float *__restrict__ v_scale, float *__restrict__ attn_out_scale, const int batch_size,
                                                                 const int head_num, const int seq_len, const int size_per_head)
    {
        const int batch_id = blockIdx.y;
        const int seq_id = blockIdx.x;
        int offset;
        float score_scale_val;
        int scale_offset;
        float val;
        int8_t out_val;
        float absmax = -1e9f;
        int target_idx;
        if (threadIdx.x < size_per_head)
        {
            for (int head_id = 0; head_id < head_num; ++head_id)
            {
                offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
                score_scale_val = __ldg(score_scale + batch_id * head_num * seq_len + head_id * seq_len + seq_id);
                scale_offset = batch_id * head_num * size_per_head + head_id * size_per_head;
                val = static_cast<float>(attn[offset + threadIdx.x]) * score_scale_val * __ldg(v_scale + scale_offset + threadIdx.x);
                absmax = max(absmax, fabsf(val));
            }
            __syncthreads();
            absmax = blockAllReduceMax<float>(absmax);

            if (threadIdx.x == 0)
            {
                attn_out_scale[batch_id * seq_len + seq_id] = absmax / 127.0f;
            }

            for (int head_id = 0; head_id < head_num; ++head_id)
            {
                offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
                score_scale_val = __ldg(score_scale + batch_id * head_num * seq_len + head_id * seq_len + seq_id);
                scale_offset = batch_id * head_num * size_per_head + head_id * size_per_head;
                val = static_cast<float>(attn[offset + threadIdx.x]) * score_scale_val * __ldg(v_scale + scale_offset + threadIdx.x);
                out_val = float_to_int8_rn(val * 127.0f / absmax);
                target_idx = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head + threadIdx.x;
                attn_buf[target_idx] = out_val;
            }
        }
    }

    void launchDequantizedAttnQuantizedTransposeKernel(int8_t *__restrict__ attn_buf, const int32_t *__restrict__ attn,
                                                       const float *__restrict__ score_scale, const float *__restrict__ v_scale, float *__restrict__ attn_out_scale, const int batch_size,
                                                       const int head_num, const int seq_len, const int size_per_head, cudaStream_t stream)
    {
        assert(size_per_head <= 1024);
        if (head_num <= 32 && size_per_head <= 128)
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(32 * head_num);
            warpDequantizedAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, score_scale, v_scale, attn_out_scale,
                                                                                    batch_size, head_num, seq_len, size_per_head);
        }
        else if (size_per_head > 512)
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(1024);
            blockDequantizedAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, score_scale, v_scale, attn_out_scale,
                                                                                     batch_size, head_num, seq_len, size_per_head);
        }
        else if (size_per_head > 256)
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(512);
            blockDequantizedAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, score_scale, v_scale, attn_out_scale,
                                                                                     batch_size, head_num, seq_len, size_per_head);
        }
        else if (size_per_head > 128)
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(256);
            blockDequantizedAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, score_scale, v_scale, attn_out_scale,
                                                                                     batch_size, head_num, seq_len, size_per_head);
        }
        else
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(128);
            blockDequantizedAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, score_scale, v_scale, attn_out_scale,
                                                                                     batch_size, head_num, seq_len, size_per_head);
        }
    }

    /** 量化、转置
     * grid(seq_len, batch_size) block(32 * head_num)
     * attn_buf:[batch_size, seq_len, head_num, size_per_head]
     * attn:[batch_size, head_num, seq_len, size_per_head]
     * attn_out_scale:[batch_size, seq_len]
     */
    __global__ void warpAttnQuantizedTransposeKernel(int8_t *__restrict__ attn_buf, const float *__restrict__ attn,
                                                     float *__restrict__ attn_out_scale, const int batch_size,
                                                     const int head_num, const int seq_len, const int size_per_head)
    {
        const int batch_id = blockIdx.y;
        const int seq_id = blockIdx.x;
        const int head_id = (threadIdx.x >> 5);
        const int tid = ((threadIdx.x & 0x1f) << 2);
        const int offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
        float4 val;
        char4 out_val;
        float absmax = -1e9f;
        int target_idx;
        float4 *inp_ptr = (float4 *)(attn + offset);
        char4 *out_ptr = (char4 *)attn_buf;
        if (tid < size_per_head)
        {
            val = inp_ptr[(threadIdx.x & 0x1f)];
            absmax = max(absmax, max(fabsf(val.x), max(fabsf(val.y), max(fabsf(val.z), fabsf(val.w)))));
            __syncthreads();
            absmax = blockAllReduceMax<float>(absmax);
            if (tid == 0)
            {
                attn_out_scale[batch_id * seq_len + seq_id] = absmax / 127.0f;
            }

            out_val.x = float_to_int8_rn(val.x * 127.0f / absmax);
            out_val.y = float_to_int8_rn(val.y * 127.0f / absmax);
            out_val.z = float_to_int8_rn(val.z * 127.0f / absmax);
            out_val.w = float_to_int8_rn(val.w * 127.0f / absmax);

            target_idx = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head + tid;
            out_ptr[target_idx >> 2] = out_val;
        }
    }

    /** 量化、转置
     * grid(seq_len, batch_size) block(size_per_head)
     * attn_buf:[batch_size, seq_len, head_num, size_per_head]
     * attn:[batch_size, head_num, seq_len, size_per_head]
     * attn_out_scale:[batch_size, seq_len]
     */
    __global__ void blockAttnQuantizedTransposeKernel(int8_t *__restrict__ attn_buf, const float *__restrict__ attn,
                                                      float *__restrict__ attn_out_scale, const int batch_size,
                                                      const int head_num, const int seq_len, const int size_per_head)
    {
        const int batch_id = blockIdx.y;
        const int seq_id = blockIdx.x;
        int offset;
        float val;
        int8_t out_val;
        float absmax = -1e9f;
        int target_idx;

        for (int head_id = 0; head_id < head_num; ++head_id)
        {
            offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
            val = attn[offset + threadIdx.x];
            absmax = max(absmax, fabsf(val));
        }
        __syncthreads();
        absmax = blockAllReduceMax<float>(absmax);

        if (threadIdx.x == 0)
        {
            attn_out_scale[batch_id * seq_len + seq_id] = absmax / 127.0f;
        }

        for (int head_id = 0; head_id < head_num; ++head_id)
        {
            offset = batch_id * head_num * seq_len * size_per_head + head_id * seq_len * size_per_head + seq_id * size_per_head;
            val = attn[offset + threadIdx.x];
            out_val = float_to_int8_rn(val * 127.0f / absmax);
            target_idx = batch_id * seq_len * head_num * size_per_head + seq_id * head_num * size_per_head + head_id * size_per_head + threadIdx.x;
            attn_buf[target_idx] = out_val;
        }
    }

    void launchAttnQuantizedTransposeKernel(int8_t *__restrict__ attn_buf, const float *__restrict__ attn,
                                            float *__restrict__ attn_out_scale, const int batch_size,
                                            const int head_num, const int seq_len, const int size_per_head, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        assert(size_per_head <= 1024);
        if (head_num <= 32 && size_per_head <= 128)
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(32 * head_num);
            warpAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, attn_out_scale,
                                                                         batch_size, head_num, seq_len, size_per_head);
        }
        else if (size_per_head == 1024)
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(1024);
            blockAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, attn_out_scale,
                                                                          batch_size, head_num, seq_len, size_per_head);
        }
        else if (size_per_head == 512)
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(512);
            blockAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, attn_out_scale,
                                                                          batch_size, head_num, seq_len, size_per_head);
        }
        else if (size_per_head == 256)
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(256);
            blockAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, attn_out_scale,
                                                                          batch_size, head_num, seq_len, size_per_head);
        }
        else
        {
            dim3 grid(seq_len, batch_size);
            dim3 block(128);
            blockAttnQuantizedTransposeKernel<<<grid, block, 0, stream>>>(attn_buf, attn, attn_out_scale,
                                                                          batch_size, head_num, seq_len, size_per_head);
        }
    }

    /**反量化、残差结构、ResNorm、量化
     * grid(seq_len * batch_size) block(128)
     * norm_out: [batch_size, seq_len, hidden_units]
     * ffn_tensor: [batch_size, seq_len, hidden_units]
     * from_temsor: [batch_size, seq_len, hidden_units]
     * attn_out: [batch_size, seq_len, hidden_units]
     * attn_out_scale: [batch_size, seq_len]
     * attn_weight_scale: [hidden_units]
     * gamma: [hidden_units]
     * norm_scale: [batch_size, seq_len]
     */
    template <typename DataType>
    __global__ void dequantizedResidualResNormQuantizedKernel(int8_t *__restrict__ norm_out, DataType *__restrict__ ffn_tensor, const DataType *__restrict__ from_temsor,
                                                              const int32_t *__restrict__ attn_out, const float *__restrict__ attn_out_scale, const float *__restrict__ attn_weight_scale,
                                                              const DataType *__restrict__ gamma, float *__restrict__ norm_scale, const float eps, const int hidden_units)
    {
        const int row_id = blockIdx.x;
        const int offset = row_id * hidden_units;
        const float attn_scale_val = __ldg(attn_out_scale + row_id);

        extern __shared__ float s_buf[]; // hiddent_units
        float val;
        float mean = 0.0f;
        float absmax = -1e9f;
        char4 out_val;

        for (int tid = threadIdx.x; tid < hidden_units; tid += blockDim.x)
        {
            val = static_cast<float>(attn_out[offset + tid]) * attn_scale_val * __ldg(attn_weight_scale + tid) + static_cast<float>(from_temsor[offset + tid]);
            s_buf[tid] = val;
            ffn_tensor[offset + tid] = static_cast<DataType>(val);
            mean += val * val;
            absmax = max(absmax, fabsf(val * static_cast<float>(__ldg(gamma + tid))));
        }
        __syncthreads();

        mean = blockAllReduceSum<float>(mean / hidden_units);
        mean = rsqrtf(mean + eps);

        absmax = blockAllReduceMax<float>(absmax);
        absmax *= mean;
        if (threadIdx.x == 0)
        {
            norm_scale[blockIdx.x] = absmax / 127.0f;
        }

        int target_idx;
        char4 *out_ptr = (char4 *)norm_out;
        for (int tid = (threadIdx.x << 2); tid < hidden_units; tid += (blockDim.x << 2))
        {
            out_val.x = float_to_int8_rn(s_buf[tid] * mean * static_cast<float>(__ldg(gamma + tid)) * 127.0f / absmax);
            out_val.y = float_to_int8_rn(s_buf[tid + 1] * mean * static_cast<float>(__ldg(gamma + tid + 1)) * 127.0f / absmax);
            out_val.z = float_to_int8_rn(s_buf[tid + 2] * mean * static_cast<float>(__ldg(gamma + tid + 2)) * 127.0f / absmax);
            out_val.w = float_to_int8_rn(s_buf[tid + 3] * mean * static_cast<float>(__ldg(gamma + tid + 3)) * 127.0f / absmax);
            target_idx = row_id * hidden_units + tid;
            out_ptr[target_idx >> 2] = out_val;
        }
    }

    /**反量化、残差结构、ResNorm、量化
     * grid(seq_len * batch_size) block(128)
     * norm_out: [batch_size, seq_len, hidden_units]
     * ffn_tensor: [batch_size, seq_len, hidden_units]
     * from_temsor: [batch_size, seq_len, hidden_units]
     * attn_out: [batch_size, seq_len, hidden_units]
     * attn_out_scale: [batch_size, seq_len]
     * attn_weight_scale: [hidden_units]
     * gamma: [hidden_units]
     */
    template <>
    __global__ void dequantizedResidualResNormQuantizedKernel(int8_t *__restrict__ norm_out, half *__restrict__ ffn_tensor, const half *__restrict__ from_temsor,
                                                              const int32_t *__restrict__ attn_out, const float *__restrict__ attn_out_scale, const float *__restrict__ attn_weight_scale,
                                                              const half *__restrict__ gamma, float *__restrict__ norm_scale, const float eps, const int hidden_units)
    {
        const int row_id = blockIdx.x;
        const int offset = row_id * hidden_units;
        const float attn_scale_val = __ldg(attn_out_scale + row_id);

        extern __shared__ float s_buf[]; // hiddent_units
        float val;
        float mean = 0.0f;
        float absmax = -1e9f;
        char4 out_val;

        for (int tid = threadIdx.x; tid < hidden_units; tid += blockDim.x)
        {
            val = static_cast<float>(attn_out[offset + tid]) * attn_scale_val * __ldg(attn_weight_scale + tid) + __half2float(from_temsor[offset + tid]);
            s_buf[tid] = val;
            ffn_tensor[offset + tid] = __float2half(val);
            mean += val * val;
            absmax = max(absmax, fabsf(val * __half2float(__ldg(gamma + tid))));
        }
        __syncthreads();

        mean = blockAllReduceSum<float>(mean / hidden_units);
        mean = rsqrtf(mean + eps);

        absmax = blockAllReduceMax<float>(absmax);
        absmax *= mean;
        if (threadIdx.x == 0)
        {
            norm_scale[blockIdx.x] = absmax / 127.0f;
        }

        int target_idx;
        char4 *out_ptr = (char4 *)norm_out;
        for (int tid = (threadIdx.x << 2); tid < hidden_units; tid += (blockDim.x << 2))
        {
            out_val.x = float_to_int8_rn(s_buf[tid] * mean * __half2float(__ldg(gamma + tid)) * 127.0 / absmax);
            out_val.y = float_to_int8_rn(s_buf[tid + 1] * mean * __half2float(__ldg(gamma + tid + 1)) * 127.0 / absmax);
            out_val.z = float_to_int8_rn(s_buf[tid + 2] * mean * __half2float(__ldg(gamma + tid + 2)) * 127.0 / absmax);
            out_val.w = float_to_int8_rn(s_buf[tid + 3] * mean * __half2float(__ldg(gamma + tid + 3)) * 127.0 / absmax);
            target_idx = row_id * hidden_units + tid;
            out_ptr[target_idx >> 2] = out_val;
        }
    }

    template <typename DataType>
    void launchDequantizedResidualResNormQuantized(int8_t *norm_out, DataType *__restrict__ ffn_tensor, const DataType *from_temsor, const int32_t *attn_out, const float *attn_out_scale,
                                                   const float *attn_weight_scale, const DataType *gamma, float *norm_scale, const float eps, const int rows, const int hidden_units, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        assert(hidden_units % 4 == 0);
        int mem_size = hidden_units * sizeof(float);
        dequantizedResidualResNormQuantizedKernel<DataType><<<rows, 128, mem_size, stream>>>(norm_out, ffn_tensor, from_temsor, attn_out, attn_out_scale, attn_weight_scale, gamma,
                                                                                             norm_scale, eps, hidden_units);
    }

    inline __device__ float silu(float x)
    {
        return x / (1.0f + __expf(-x));
    }

    /** 反量化、silu、element-wise-multify、量化
     * grid(nrows) block(128)
     * out_buf: [nrows, hidden_units]
     * w1_ret w3_ret: [nrows, hidden_units]
     * norm_scale: [nrows, ]
     * w1_weight_scale w3_weight_scale: [hidden_units, ]
     * out_scale: [nrows, ]
     */
    __global__ void dequantizedSiluMultifyQuantizedKernel(int8_t *__restrict__ out_buf, const int32_t *__restrict__ w1_ret, const float *__restrict__ norm_scale,
                                                          const float *__restrict__ w1_weight_scale, const int32_t *__restrict__ w3_ret, const float *__restrict__ w3_weight_scale,
                                                          float *__restrict__ out_scale, const int hidden_units)
    {
        const int row_id = blockIdx.x;
        const float norm_scale_val = __ldg(norm_scale + row_id);
        const int offset = row_id * hidden_units;
        extern __shared__ float s_buf[];
        float val;
        float absmax = -1e9f;
        for (int tid = threadIdx.x; tid < hidden_units; tid += blockDim.x)
        {
            val = static_cast<float>(w1_ret[offset + tid]) * norm_scale_val * __ldg(w1_weight_scale + tid);
            val = silu(val);
            val *= static_cast<float>(w3_ret[offset + tid]) * norm_scale_val * __ldg(w3_weight_scale + tid);
            s_buf[tid] = val;
            absmax = max(absmax, fabsf(val));
        }
        __syncthreads();

        absmax = blockAllReduceMax<float>(absmax);
        if (threadIdx.x == 0)
        {
            out_scale[row_id] = absmax / 127.0f;
        }

        float scale_val = 127.0f / absmax;
        char4 out_val;
        char4 *out_ptr = (char4 *)out_buf;
        for (int tid = (threadIdx.x << 2); tid < hidden_units; tid += (blockDim.x << 2))
        {
            out_val.x = float_to_int8_rn(s_buf[tid] * scale_val);
            out_val.y = float_to_int8_rn(s_buf[tid + 1] * scale_val);
            out_val.z = float_to_int8_rn(s_buf[tid + 2] * scale_val);
            out_val.w = float_to_int8_rn(s_buf[tid + 3] * scale_val);
            out_ptr[(offset + tid >> 2)] = out_val;
        }
    }

    void launchDequantizedSiluMultifyQuantized(int8_t *out_buf, const int32_t *w1_ret, const float *norm_scale, const float *w1_weight_scale,
                                               const int32_t *w3_ret, const float *w3_weight_scale, float *out_scale, const int nrows, const int hidden_units, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        assert(hidden_units % 4 == 0);
        int mem_size = sizeof(float) * hidden_units;
        dequantizedSiluMultifyQuantizedKernel<<<nrows, 128, mem_size, stream>>>(out_buf, w1_ret, norm_scale, w1_weight_scale,
                                                                                w3_ret, w3_weight_scale, out_scale, hidden_units);
    }

    /**反量化、残差结构
     * grid(seq_len * batch_size) block(128)
     * out: [batch_size, seq_len, hidden_units]
     * ffn_tensor: [batch_size, seq_len, hidden_units]
     * from_temsor: [batch_size, seq_len, hidden_units]
     * inp: [batch_size, seq_len, hidden_units]
     * inp_scale: [batch_size, seq_len]
     * weight_scale: [hidden_units]
     */
    template <typename DataType>
    __global__ void dequantizedResidualKernel(DataType *__restrict__ out, const DataType *__restrict__ from_temsor,
                                              const int32_t *__restrict__ inp, const float *__restrict__ inp_scale, const float *__restrict__ weight_scale,
                                              const int hidden_units)
    {
        const int row_id = blockIdx.x;
        const int offset = row_id * hidden_units;
        const float inp_scale_val = __ldg(inp_scale + row_id);
        float val;

        for (int tid = threadIdx.x; tid < hidden_units; tid += blockDim.x)
        {
            val = static_cast<float>(inp[offset + tid]) * inp_scale_val * __ldg(weight_scale + tid) + static_cast<float>(from_temsor[offset + tid]);
            out[offset + tid] = static_cast<DataType>(val);
        }
    }

    template <>
    __global__ void dequantizedResidualKernel(half *__restrict__ out, const half *__restrict__ from_temsor,
                                              const int32_t *__restrict__ inp, const float *__restrict__ inp_scale, const float *__restrict__ weight_scale,
                                              const int hidden_units)
    {
        const int row_id = blockIdx.x;
        const int offset = row_id * hidden_units;
        const float inp_scale_val = __ldg(inp_scale + row_id);
        half2 tmp;
        half2 *from_temsor_ptr = (half2 *)(from_temsor + offset);
        half2 *out_ptr = (half2 *)(out + offset);

        for (int tid = threadIdx.x; tid < (hidden_units >> 1); tid += blockDim.x)
        {
            tmp.x = __float2half(static_cast<float>(inp[offset + 2 * tid]) * inp_scale_val * __ldg(weight_scale + 2 * tid));
            tmp.y = __float2half(static_cast<float>(inp[offset + 2 * tid + 1]) * inp_scale_val * __ldg(weight_scale + 2 * tid + 1));
            out_ptr[tid] = __hadd2(from_temsor_ptr[tid], tmp);
        }
    }

    template <typename DataType>
    void launchDequantizedResidual(DataType *__restrict__ out, const DataType *__restrict__ from_temsor, const int32_t *__restrict__ inp,
                                   const float *__restrict__ inp_scale, const float *__restrict__ weight_scale, const int nrows,
                                   const int hidden_units, cudaStream_t stream)
    {
#ifndef NDEBUG
        PRINT_FUNC_NAME_();
#endif
        assert(hidden_units % 2 == 0);
        dequantizedResidualKernel<<<nrows, 128, 0, stream>>>(out, from_temsor, inp, inp_scale, weight_scale, hidden_units);
    }

    template void launchResNormQuantizedKernel(int8_t *output, const float *input, const float *gamma,
                                               float *norm_scale, const float eps, const int nrows, const int hidden_units, cudaStream_t stream);

    template void launchResNormQuantizedKernel(int8_t *output, const half *input, const half *gamma,
                                               float *norm_scale, const float eps, const int nrows, const int hidden_units, cudaStream_t stream);

    template void launchEmbeddingLookingUpKernel(float *from_tensor, const float *embedding_table, const int *word_ids,
                                                 const int hidden_units, const int batch_size, const int seq_len, cudaStream_t stream);

    template void perChannelQuantizedKernelLauncher(int8_t *dst, const float *src, float *scale_ptr, const int hidden_size,
                                                    const int nrows, cudaStream_t stream);

    template void launchDequantizedResidualResNormQuantized(int8_t *norm_out, float *__restrict__ ffn_tensor, const float *from_temsor,
                                                            const int32_t *attn_out, const float *attn_out_scale,
                                                            const float *attn_weight_scale, const float *gamma,
                                                            float *norm_scale, const float eps, const int rows, const int hidden_units,
                                                            cudaStream_t stream);

    template void launchDequantizedResidualResNormQuantized(int8_t *norm_out, half *__restrict__ ffn_tensor, const half *from_temsor,
                                                            const int32_t *attn_out, const float *attn_out_scale,
                                                            const float *attn_weight_scale, const half *gamma,
                                                            float *norm_scale, const float eps, const int rows, const int hidden_units,
                                                            cudaStream_t stream);

    template void launchDequantizedResidual(float *__restrict__ out, const float *__restrict__ from_temsor,
                                            const int32_t *__restrict__ inp, const float *__restrict__ inp_scale,
                                            const float *__restrict__ weight_scale, const int nrows,
                                            const int hidden_units, cudaStream_t stream);

    template void launchDequantizedResidual(half *__restrict__ out, const half *__restrict__ from_temsor,
                                            const int32_t *__restrict__ inp, const float *__restrict__ inp_scale,
                                            const float *__restrict__ weight_scale, const int nrows,
                                            const int hidden_units, cudaStream_t stream);

}