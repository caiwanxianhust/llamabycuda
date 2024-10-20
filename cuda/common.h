#pragma once
#include <stdio.h>
#include <cublas_v2.h>

namespace tinycudallama
{

    enum class OperationType
    {
        FP32,
        FP16
    };
    enum class AllocatorType
    {
        CUDA,
        TF,
        TH
    };

    template <typename T>
    struct ResNormWeight
    {
        const T *gamma = nullptr;
        const float eps = 1e-5f;
    };

    template <typename T>
    struct DenseWeight
    {
        const T *kernel = nullptr;
        const T *bias = nullptr;
        const float *weight_scale = nullptr;
    };

    template <typename T>
    struct AttentionWeight
    {
        DenseWeight<T> query_weight;
        DenseWeight<T> key_weight;
        DenseWeight<T> value_weight;
        DenseWeight<T> attention_output_weight;
    };

    template <typename T>
    struct FFNWeight
    {
        DenseWeight<T> w1_weight;
        DenseWeight<T> w2_weight;
        DenseWeight<T> w3_weight;
    };

#define PRINT_FUNC_NAME_()                                              \
    do                                                                  \
    {                                                                   \
        std::cout << "[FT][CALL] " << __FUNCTION__ << " " << std::endl; \
    } while (0)

static const char *_cudaGetErrorEnum(cublasStatus_t error)
{
    switch (error)
    {
    case CUBLAS_STATUS_SUCCESS:
        return "CUBLAS_STATUS_SUCCESS";

    case CUBLAS_STATUS_NOT_INITIALIZED:
        return "CUBLAS_STATUS_NOT_INITIALIZED";

    case CUBLAS_STATUS_ALLOC_FAILED:
        return "CUBLAS_STATUS_ALLOC_FAILED";

    case CUBLAS_STATUS_INVALID_VALUE:
        return "CUBLAS_STATUS_INVALID_VALUE";

    case CUBLAS_STATUS_ARCH_MISMATCH:
        return "CUBLAS_STATUS_ARCH_MISMATCH";

    case CUBLAS_STATUS_MAPPING_ERROR:
        return "CUBLAS_STATUS_MAPPING_ERROR";

    case CUBLAS_STATUS_EXECUTION_FAILED:
        return "CUBLAS_STATUS_EXECUTION_FAILED";

    case CUBLAS_STATUS_INTERNAL_ERROR:
        return "CUBLAS_STATUS_INTERNAL_ERROR";

    case CUBLAS_STATUS_NOT_SUPPORTED:
        return "CUBLAS_STATUS_NOT_SUPPORTED";

    case CUBLAS_STATUS_LICENSE_ERROR:
        return "CUBLAS_STATUS_LICENSE_ERROR";
    }
    return "<unknown>";
}

#define CHECK_CUDA_ERROR(call)                             \
    do                                                     \
    {                                                      \
        const cudaError_t errorCode = call;                \
        if (errorCode != cudaSuccess)                      \
        {                                                  \
            printf("CUDA Error:\n");                       \
            printf("    File:   %s\n", __FILE__);          \
            printf("    Line:   %d\n", __LINE__);          \
            printf("    Error code:     %d\n", errorCode); \
            printf("    Error text:     %s\n",             \
                   cudaGetErrorString(errorCode));         \
            exit(1);                                       \
        }                                                  \
    } while (0)

#define CHECK_CUBLAS_STATUS(call)                            \
    do                                                       \
    {                                                        \
        const cublasStatus_t statusCode = call;              \
        if (statusCode != CUBLAS_STATUS_SUCCESS)             \
        {                                                    \
            printf("CUDA Error:\n");                         \
            printf("    File:   %s\n", __FILE__);            \
            printf("    Line:   %d\n", __LINE__);            \
            printf("    Status code:     %d\n", statusCode); \
            printf("    Error text:     %s\n",               \
                   _cudaGetErrorEnum(statusCode));           \
            exit(1);                                         \
        }                                                    \
    } while (0)

}
