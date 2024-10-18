#ifndef DECODING_SAMPLING_H
#define DECODING_SAMPLING_H

#include "open_decoder.cuh"

namespace tinycudallama
{
    template <typename T>
    class DecodingInitParam
    {
    public:
        const T *embedding_table;
        const T *embedding_kernel;
        const float *embedding_bias;

        float *freq_cis;

        // the length of tokens in the batch. [batch_size, ]
        const int *prompt_sequence_length;
        // [batch_size, max_prompt_seq_len]
        const int *prompt_tokens;
        // [batch_size, max_prompt_seq_len], pad token is 0, otherwise 1.
        const bool *prompt_tokens_mask;

        ResNormWeight<T> decodingnorm;

        DenseWeight<T> output_weight;

        int *output_ids;
        int *parent_ids;
        int *sequence_length;
        cublasHandle_t cublas_handle;
        cudaStream_t stream;
    };

    struct TransformerArguments
    {
        int batch_size_;
        int seq_len_;
        int head_num_;
        int size_per_head_;
        int hidden_units_;
        int ffn_hidden_units_;
    };

    struct DecodingArguments : public TransformerArguments
    {
        int decoder_layers_;
        int vocab_size_;
        int start_id_;
        // the eos token's index
        int end_id_;
        int max_prompt_len_;
        int max_gen_len;
    };

    struct DecodingSamplingArguments : public DecodingArguments
    {
        // the k for top-k sampling
        int candidate_num_;
        // the p for top-p sampling
        float probability_threshold_;
        size_t temp_storage_size_;
    };

    struct DecodingBeamsearchArguments : public DecodingArguments
    {
        int beam_width_;
        int temp_storage_size_;
        float beam_search_diversity_rate_;
    };

    template <OperationType OpType_>
    class DecodingSampling
    {
    private:
        typedef DecoderTransformerTraits<OpType_> Traits_;
        typedef typename Traits_::DataType DataType_;
        const IAllocator &allocator_;
        struct DecodingSamplingArguments args_;

        const cudaDataType_t computeType_ = Traits_::computeType;
        const cudaDataType_t AType_ = Traits_::AType;
        const cudaDataType_t BType_ = Traits_::BType;
        const cudaDataType_t CType_ = Traits_::CType;
        int cublasAlgo_[1] = {20};

        OpenDecoder<OpType_> *decoder_;
        float **K_cache_;
        float **V_cache_;
        DataType_ *from_tensor_[2];
        DataType_ *decoder_buf_;
        DataType_ *decoder_normed_result_buf_;
        float *logits_buf_;
        float *cum_log_buf_;
        int *word_ids_buf_;
        bool *finished_buf_;
        int *topk_ids_buf_;
        float *topk_val_buf_;
        void *buf_;
        // int start_id_;
        // int end_id_;
        int *finished_count_buf_;
        bool *h_finished_buf_;
        // is initialized by [[0, 1, ..., vocab_size-1], [0, 1, ..., vocab_size-1], ..., [0, 1, ..., vocab_size-1]]
        int *topp_id_vals_buf_;
        float *topp_sorted_log_prob_buf_;
        int *topp_sorted_id_vals_buf_;
        int *topp_offset_buf_;

        void *temp_storage_;
        // size_t temp_storage_size_;

    public:
        DecodingSampling(const IAllocator &allocator, const int batch_size,
                         const int max_prompt_len, const int max_gen_len,
                         const int head_num, const int size_per_head,
                         const int vocab_size, const int decoder_layers,
                         const int start_id, const int end_id,
                         const int ffn_hidden_units, const int candidate_num = 0,
                         const float probability_threshold = 0.0) : allocator_(allocator)
        {
            args_.batch_size_ = batch_size;
            args_.max_prompt_len_ = max_prompt_len;
            args_.max_gen_len = max_gen_len;
            args_.head_num_ = head_num;
            args_.size_per_head_ = size_per_head;
            args_.hidden_units_ = head_num * size_per_head;
            args_.decoder_layers_ = decoder_layers;
            args_.vocab_size_ = vocab_size;
            args_.candidate_num_ = candidate_num;
            args_.probability_threshold_ = probability_threshold;
            args_.start_id_ = start_id;
            args_.end_id_ = end_id;
            args_.ffn_hidden_units_ = ffn_hidden_units;

            // Only one (top-k or top-p sampling) can be selected
            if (args_.candidate_num_ == 0 && args_.probability_threshold_ == 0.0)
            {
                printf("[ERROR] Candidate_num for topk is 0 and probability threshold for top p is 0.0 \n");
                exit(-1);
            }
            else if (args_.candidate_num_ != 0 && args_.probability_threshold_ != 0.0)
            {
                printf("[ERROR] Candidate_num for topk is not 0 and probability threshold for top p is not 0.0 \n");
                exit(-1);
            }
#ifndef NDEBUG
            PRINT_FUNC_NAME_();
#endif
            K_cache_ = new float *[1];
            V_cache_ = new float *[1];

            decoder_ = new OpenDecoder<OpType_>(batch_size, max_prompt_len,
                                                max_gen_len, head_num, size_per_head);

            int from_tensor_size = args_.batch_size_ * args_.max_prompt_len_ * args_.hidden_units_;                  // type T
            int decoder_workspace_size = decoder_->getWorkspaceSize();                                               // type T
            int decoder_normed_result_buffer_size = args_.batch_size_ * args_.max_prompt_len_ * args_.hidden_units_; // type float
            int cache_size = args_.batch_size_ * (args_.max_prompt_len_ + args_.max_gen_len_) * args_.hidden_units_; // type float

            int logits_buf_size = args_.batch_size_ * args_.vocab_size_; // type float
            int cum_log_buf_size = args_.batch_size_;                    // type float
            int word_ids_buf_size = args_.batch_size_;                   // type int
            int finished_buf_size = args_.batch_size_;                   // type bool
            int finished_count_size = (int)(ceil(1 / 32.)) * 32;         // type int

            int topk_ids_buf_size = args_.batch_size_ * args_.candidate_num_; // type int
            int topk_val_buf_size = args_.batch_size_ * args_.candidate_num_; // type float
            int topp_id_vals_buf_size = args_.batch_size_ * args_.vocab_size_;
            int topp_sorted_log_prob_buf_size = args_.batch_size_ * args_.vocab_size_;
            int topp_sorted_id_vals_buf_size = args_.batch_size_ * args_.vocab_size_;

            // prevent memory misalinged address
            logits_buf_size = (int)(ceil(logits_buf_size / 4.)) * 4;
            cum_log_buf_size = (int)(ceil(cum_log_buf_size / 4.)) * 4;
            word_ids_buf_size = (int)(ceil(word_ids_buf_size / 4.)) * 4;
            finished_buf_size = (int)(ceil(finished_buf_size / 32.)) * 32;
            topk_ids_buf_size = (int)(ceil(topk_ids_buf_size / 4.)) * 4;
            topk_val_buf_size = (int)(ceil(topk_val_buf_size / 4.)) * 4;
            topp_id_vals_buf_size = (int)(ceil(topp_id_vals_buf_size / 4.)) * 4;
            topp_sorted_log_prob_buf_size = (int)(ceil(topp_sorted_log_prob_buf_size / 4.)) * 4;
            topp_sorted_id_vals_buf_size = (int)(ceil(topp_sorted_id_vals_buf_size / 4.)) * 4;

            args_.temp_storage_size_ = get_topp_sort_temp_storage_size(logits_buf_,
                                                                       topp_id_vals_buf_,
                                                                       topp_sorted_log_prob_buf_,
                                                                       topp_sorted_id_vals_buf_,
                                                                       topp_offset_buf_,
                                                                       args_.batch_size_,
                                                                       args_.vocab_size_);

            int topp_offset_buf_size = args_.batch_size_ + 1;
            args_.temp_storage_size_ = (int)(ceil(args_.temp_storage_size_ / 4.)) * 4;
            topp_offset_buf_size = (int)(ceil(topp_offset_buf_size / 4.)) * 4;

            int datatype_buf_size = from_tensor_size * 2 + decoder_workspace_size +
                                    (cache_size * 4 + mem_cache_size * 2) * args_.decoder_layers_ + decoder_normed_result_buffer_size;

            buf_ = reinterpret_cast<void *>(allocator_.malloc(
                sizeof(DataType_) * datatype_buf_size +
                sizeof(float) * (logits_buf_size + cum_log_buf_size) +
                sizeof(int) * word_ids_buf_size +
                sizeof(bool) * finished_buf_size +
                sizeof(int) * finished_count_size +
                sizeof(int) * topk_ids_buf_size +
                sizeof(float) * topk_val_buf_size +
                sizeof(int) * (topp_id_vals_buf_size + topp_sorted_id_vals_buf_size + topp_offset_buf_size) +
                sizeof(float) * topp_sorted_log_prob_buf_size +
                args_.temp_storage_size_));

            from_tensor_[0] = (DataType_ *)buf_;
            from_tensor_[1] = (DataType_ *)(from_tensor_[0] + from_tensor_size);

            for (int i = 0; i < args_.decoder_layers_; ++i)
            {
                K_mem_cache_[i] = from_tensor_[1] + from_tensor_size + i * mem_cache_size * 2;
                V_mem_cache_[i] = from_tensor_[1] + from_tensor_size + i * mem_cache_size * 2 + mem_cache_size;
            }

            /* We use two-way buffer since we have to update KV buf at the end of each step. */
            K_cache_[0] = V_mem_cache_[args_.decoder_layers_ - 1] + mem_cache_size + 0 * cache_size * args_.decoder_layers_;
            V_cache_[0] = V_mem_cache_[args_.decoder_layers_ - 1] + mem_cache_size + 1 * cache_size * args_.decoder_layers_;

            decoder_buf_ = V_cache_[0] + cache_size * args_.decoder_layers_;
            decoder_normed_result_buf_ = (decoder_buf_ + decoder_workspace_size);
            logits_buf_ = (float *)(decoder_normed_result_buf_ + decoder_normed_result_buffer_size);
            cum_log_buf_ = (float *)(logits_buf_ + logits_buf_size);
            word_ids_buf_ = (int *)(cum_log_buf_ + cum_log_buf_size);
            finished_buf_ = (bool *)(word_ids_buf_ + word_ids_buf_size);
            topk_ids_buf_ = (int *)(finished_buf_ + finished_buf_size);
            topk_val_buf_ = (float *)(topk_ids_buf_ + topk_ids_buf_size);
            finished_count_buf_ = (int *)(topk_val_buf_ + topk_val_buf_size);
            topp_id_vals_buf_ = (int *)(finished_count_buf_ + finished_count_size);
            topp_sorted_id_vals_buf_ = (int *)(topp_id_vals_buf_ + topp_id_vals_buf_size);
            topp_offset_buf_ = (int *)(topp_sorted_id_vals_buf_ + topp_sorted_id_vals_buf_size);
            topp_sorted_log_prob_buf_ = (float *)(topp_offset_buf_ + topp_offset_buf_size);
            temp_storage_ = (void *)(topp_sorted_log_prob_buf_ + topp_sorted_log_prob_buf_size);

            h_finished_buf_ = new bool[finished_buf_size];

            FILE *fd = fopen("decoding_gemm_config.in", "r");
            int err = 0;
            if (fd == NULL)
                printf("[WARNING] decoding_gemm_config.in is not found\n");
            else
            {
                err = fscanf(fd, "%d", &cublasAlgo_[0]);
                fclose(fd);
            }
            if (err != 1)
            {
                printf("[WARNING] decoding loading GEMM algorithms error, using default GEMM algorithms!\n");
                if (Traits_::OpType == OperationType::FP32)
                {
                    cublasAlgo_[0] = CUBLAS_GEMM_DEFAULT;
                }
                else
                {
                    cublasAlgo_[0] = CUBLAS_GEMM_DEFAULT_TENSOR_OP;
                }
            }
            else
            {
                // check that the gemm_config setting is runnable
                if (Traits_::OpType == OperationType::FP32)
                {
                    if (cublasAlgo_[0] > CUBLAS_GEMM_ALGO23 || cublasAlgo_[0] < CUBLAS_GEMM_DEFAULT)
                    {
                        // the algorithm is not for FP32
                        printf("[ERROR] cuBLAS Algorithm %d is not used in FP32. \n", (int)cublasAlgo_[0]);
                        exit(-1);
                    }
                }
                else
                {
                    if (cublasAlgo_[0] > CUBLAS_GEMM_ALGO15_TENSOR_OP || cublasAlgo_[0] < CUBLAS_GEMM_DEFAULT_TENSOR_OP)
                    {
                        // the algorithm is not for FP16
                        printf("[ERROR] cuBLAS Algorithm %d is not used in FP16. \n", (int)cublasAlgo_[0]);
                        exit(-1);
                    }
                }
            }
        }

        void forward(const DecoderInitParam<DataType_> *param,
                     DecodingInitParam<DataType_> decoding_params)
        {

#ifndef NDEBUG
            PRINT_FUNC_NAME_();
#endif

            /*
              sequence_length initialize to 0
              finished: false
              cum_log_buf_: useless, keep it to reuse the kernel of decoding_opennmt.h
            */

            if (args_.candidate_num_ != 0)
            {
                launchTopKSamplingInitKernel(finished_buf_, decoding_params.sequence_length, cum_log_buf_,
                                             args_.batch_size_, decoding_params.stream)
            }
            else if (args_.probability_threshold_ != 0.0)
            {
                topp_initialization_kernelLauncher(finished_buf_,
                                                   decoding_params.sequence_length,
                                                   word_ids_buf_,
                                                   topp_id_vals_buf_,
                                                   topp_offset_buf_,
                                                   args_,
                                                   decoding_params.stream);
            }

#ifndef NDEBUG
            cudaDeviceSynchronize();
            check_cuda_error(cudaGetLastError());
#endif

            int cache_size = args_.batch_size_ * args_.seq_len_ * args_.hidden_units_; // type T

            int min_prompt_seq_len = args_.max_prompt_len_;
            int max_prompt_seq_len = 0;
            for (int i = 0; i < args_.batch_size_; ++i)
            {
                min_prompt_seq_len = min(decoding_params.prompt_sequence_length[i], min_prompt_seq_len);
                max_prompt_seq_len = max(decoding_params.prompt_sequence_length[i], max_prompt_seq_len);
            }
            assert(max_prompt_seq_len < args_.max_prompt_len_);
            int total_seq_len = max_prompt_seq_len + args_.max_gen_len;

            /**
             * init the freq_cis matrix, the freq_cis are only related to size_per_head
             */
            launchPrecomputeFreqsCis(decoding_params.freq_cis, args_.size_per_head_, total_seq_len, decoding_params.stream);

#ifndef NDEBUG
            cudaDeviceSynchronize();
            check_cuda_error(cudaGetLastError());
#endif
            int prev_pos = 0;
            for (int cur_pos = min_prompt_seq_len; cur_pos < total_seq_len; ++cur_pos)
            {
                int cur_seq_len = cur_pos - prev_pos;

                /**
                 * Embedding Lookup
                 */
                if (cur_pos == min_prompt_seq_len)
                {
                    // prompt phase, prompt_tokens[:, :cur_pos] is embedded to from_tensor which shape is [batch_size, cur_seq_len, hidden_units]
                    launchEmbeddingLookupKernel(from_tensor_[0], decoding_params.embedding_table, decoding_params.prompt_tokens,
                                                args_.batch_size_, cur_seq_len, max_prompt_seq_len, args_.hidden_units_, decoding_params.stream);
                }
                else
                {
                    // generation phase, word_ids_buf_ is embedded to from_tensor which shape is [batch_size, hidden_units]
                    launchEmbeddingLookupKernel(from_tensor_[0], decoding_params.embedding_table, word_ids_buf_,
                                                args_.batch_size_, 1, 1, args_.hidden_units_, decoding_params.stream);
                }

#ifndef NDEBUG
                cudaDeviceSynchronize();
                check_cuda_error(cudaGetLastError());
#endif

                int from_id, out_id;
                for (int layer = 0; layer < args_.decoder_layers_; ++layer)
                {
                    /*
                      For the first layer (layer-0), from_id is 0. We also stored the embedding lookup
                      result in from_tensor_[0]
                    */
                    from_id = layer & 0x1;
                    out_id = 1 - from_id;

                    /*
                      We use one decoder_ object to process multiple decoder layers.

                      At the beginning of each decoder layer, we initialize the decoder object
                      with corresponding weights and decoder_buf_.

                      The decoder_buf_ is reused.
                    */
                    decoder_->initialize(param[layer], decoder_buf_);

#ifndef NDEBUG
                    cudaDeviceSynchronize();
                    check_cuda_error(cudaGetLastError());
#endif
                    decoder_->forward(from_tensor_[from_id], decoding_params.freq_cis,
                                      K_cache_[0] + layer * cache_size,
                                      V_cache_[0] + layer * cache_size,
                                      args_.ffn_hidden_units_,
                                      from_tensor_[out_id], prev_pos, cur_seq_len);

#ifndef NDEBUG
                    cudaDeviceSynchronize();
                    check_cuda_error(cudaGetLastError());
#endif
                }

                launchResNormKernel(decoder_normed_result_buf_, from_tensor_[out_id], decoding_params.decodingnorm.gamma,
                                    decoding_params.decodingnorm.eps, args_.batch_size_ * cur_seq_len,
                                    args_.hidden_units_, decoding_params.stream);

                float alpha = (float)1.0f;
                float beta = (float)0.0f;
                int m = args_.batch_size_ * cur_seq_len;
                int k = args_.hidden_units_;
                int n = args_.vocab_size_;

                check_cuda_error(cublasGemmEx(decoding_params.cublas_handle,
                                              CUBLAS_OP_N, CUBLAS_OP_N,
                                              n, m, k,
                                              &alpha,
                                              decoding_params.output_weight.kernel, AType_, n,
                                              decoder_normed_result_buf_, BType_, k,
                                              &beta,
                                              logits_buf_, CUDA_R_32F, n,
                                              CUDA_R_32F,
                                              static_cast<cublasGemmAlgo_t>(cublasAlgo_[0])));

#ifndef NDEBUG
                cudaDeviceSynchronize();
                check_cuda_error(cudaGetLastError());
#endif

                if (args_.candidate_num_ != 0)
                {
                    // top k sampling
                    // step_logits_buf_ = logits_buf[:, -1, :]，and set the logits component corresponding to end_id to the maximum value
                    launchUpdateLogitsWithoutSoftmax(step_logits_buf_, logits_buf_, args_.end_id_, finished_buf_, args_.batch_size_,
                                                     cur_seq_len, args_.vocab_size_, decoding_params.stream);
                    launchTopKSamplingKernel(step_logits_buf_, topk_ids_buf_, topk_val_buf_,
                                             decoding_params.output_ids + (step - 1) * args_.batch_size_, decoding_params.sequence_length,
                                             finished_buf_, decoding_params.prompt_tokens, decoding_params.prompt_tokens_mask,
                                             cur_pos, max_prompt_seq_len,
                                             cur_pos, // used as a random seed
                                             args_.batch_size_, args_.vocab_size_, args_.candidate_num_, args_.end_id_, decoding_params.stream);
                }
                else if (args_.probability_threshold_ != 0.0)
                {
                    // top p sampling
                    // step_logits_buf_ = logits_buf[:, -1, :]，set the logits component corresponding to end_id to the maximum value, softmax
                    launchUpdateLogitsKernelWithoutLog(step_logits_buf_, logits_buf_, finished_buf_, cur_seq_len, args_.end_id_,
                                                       args_.batch_size_, args_.vocab_size_, decoding_params.stream);

                    launchTopPSamplingKernel(step_logits_buf_, topp_id_vals_buf_, topp_sorted_log_prob_buf_, topp_sorted_id_vals_buf_,
                                             topp_offset_buf_, temp_storage_, finished_buf_, decoding_params.prompt_tokens,
                                             decoding_params.prompt_tokens_mask, cur_pos, max_prompt_seq_len,
                                             cur_pos, // used as a random seed
                                             decoding_params.output_ids + (step - 1) * args_.batch_size_, decoding_params.sequence_length,
                                             args_.batch_size_, args_.vocab_size_, args_.probability_threshold_, decoding_params.stream);
                }
            }
        }

        virtual ~DecodingSampling()
        {
            delete[] K_cache_;
            delete[] V_cache_;
            delete[] K_mem_cache_;
            delete[] V_mem_cache_;
            delete[] h_finished_buf_;
            delete decoder_;
            allocator_.free(buf_);
        }
    }

#endif