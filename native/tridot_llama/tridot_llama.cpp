#include "tridot_llama.h"

#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "llama.h"

struct tl_ctx {
    llama_model *model;
    llama_context *ctx;
    const llama_vocab *vocab;
    llama_batch_ext *batch;
    std::vector<llama_token> past;  // токены в кэше
};

static std::once_flag g_backend;

// Журнал llama.cpp не нужен: в нём пути к файлам и куски запроса.
static void quiet(ggml_log_level, const char *, void *) {}

static void set_tokens(llama_batch_ext *batch, const llama_token *tokens, int32_t n, llama_pos pos0) {
    llama_batch_ext_clear(batch);
    for (int32_t i = 0; i < n; ++i) {
        const int32_t idx = llama_batch_ext_add_token(batch, 0, tokens[i]);
        const llama_pos pos = pos0 + i;
        llama_batch_ext_set_pos(batch, idx, &pos);
    }
    llama_batch_ext_set_output_logits(batch, n - 1, true);
}

tl_ctx *tl_load(const char *path, int32_t n_ctx, int32_t threads) {
    std::call_once(g_backend, [] {
        llama_log_set(quiet, nullptr);
        llama_backend_init();
    });
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    llama_model *model = llama_model_load_from_file(path, mp);
    if (!model) return nullptr;
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)n_ctx;
    cp.n_batch = 512;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        llama_model_free(model);
        return nullptr;
    }
    llama_batch_ext *batch = llama_batch_ext_init(ctx);
    return new tl_ctx{model, ctx, llama_model_get_vocab(model), batch, {}};
}

int32_t tl_complete(tl_ctx *t, const char *prompt, const char *grammar, int32_t max_tokens,
                    char *out, int32_t out_cap, volatile int32_t *cancel) {
    const int32_t len = (int32_t)std::strlen(prompt);
    int32_t n = -llama_tokenize(t->vocab, prompt, len, nullptr, 0, false, true);
    if (n <= 0) return TL_ERR_TOKENIZE;
    std::vector<llama_token> tokens(n);
    if (llama_tokenize(t->vocab, prompt, len, tokens.data(), n, false, true) < 0) return TL_ERR_TOKENIZE;
    if ((uint32_t)(n + max_tokens) > llama_n_ctx(t->ctx)) return TL_ERR_TOO_LONG;

    // Общее начало с прошлым запросом остаётся в кэше. Хотя бы последний
    // токен запроса прогоняется заново: нужны его логиты.
    size_t keep = 0;
    while (keep < t->past.size() && keep < tokens.size() && t->past[keep] == tokens[keep]) keep++;
    if (keep == tokens.size()) keep--;
    llama_memory_seq_rm(llama_get_memory(t->ctx), 0, (llama_pos)keep, -1);
    t->past.assign(tokens.begin(), tokens.begin() + keep);

    const int32_t step = (int32_t)llama_n_batch(t->ctx);
    for (size_t i = keep; i < tokens.size(); i += step) {
        if (cancel && *cancel) return TL_ERR_CANCELLED;
        const int32_t m = (int32_t)std::min<size_t>(step, tokens.size() - i);
        set_tokens(t->batch, tokens.data() + i, m, (llama_pos)i);
        if (llama_process(t->ctx, LLAMA_PROCESS_TYPE_DECODE, t->batch)) return TL_ERR_DECODE;
        t->past.insert(t->past.end(), tokens.begin() + i, tokens.begin() + i + m);
    }

    llama_sampler *chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (grammar && *grammar) {
        llama_sampler *g = llama_sampler_init_grammar(t->vocab, grammar, "root");
        if (!g) {
            llama_sampler_free(chain);
            return TL_ERR_GRAMMAR;
        }
        llama_sampler_chain_add(chain, g);
    }
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());

    std::string text;
    int32_t result = 0;
    for (int32_t k = 0; k < max_tokens; ++k) {
        if (cancel && *cancel) {
            result = TL_ERR_CANCELLED;
            break;
        }
        llama_token id = llama_sampler_sample(chain, t->ctx, -1);
        if (llama_vocab_is_eog(t->vocab, id)) break;
        char buf[256];
        const int32_t p = llama_token_to_piece(t->vocab, id, buf, sizeof(buf), 0, false);
        if (p > 0) text.append(buf, p);
        set_tokens(t->batch, &id, 1, (llama_pos)t->past.size());
        if (llama_process(t->ctx, LLAMA_PROCESS_TYPE_DECODE, t->batch)) {
            result = TL_ERR_DECODE;
            break;
        }
        t->past.push_back(id);
    }
    llama_sampler_free(chain);
    if (result < 0) return result;
    const int32_t size = (int32_t)std::min<size_t>(text.size(), (size_t)(out_cap - 1));
    std::memcpy(out, text.data(), size);
    out[size] = 0;
    return size;
}

void tl_free(tl_ctx *t) {
    if (!t) return;
    llama_batch_ext_free(t->batch);
    llama_free(t->ctx);
    llama_model_free(t->model);
    delete t;
}
