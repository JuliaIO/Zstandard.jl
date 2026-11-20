# Memory estimates (libzstd's ZSTD_estimateCCtxSize / ZSTD_estimateCStreamSize /
# ZSTD_estimateDStreamSize). Included in module Zstandard.

const _CTX_OVERHEAD = Ref(0)
const _SPLIT_OVERHEAD = Ref(0)
const _DSTATE_OVERHEAD = Ref(0)

function _overheads()
    if _CTX_OVERHEAD[] == 0
        _CTX_OVERHEAD[] = Base.summarysize(CompressionContext())
        _SPLIT_OVERHEAD[] = Base.summarysize(Encoder.SplitState())
        _DSTATE_OVERHEAD[] = Base.summarysize(DecoderState())
    end
    return _CTX_OVERHEAD[], _SPLIT_OVERHEAD[], _DSTATE_OVERHEAD[]
end

# Bytes of the match-finder tables for parameters p.
function _table_bytes(p::Encoder.CParams)
    t = 4 << p.hash_log
    if p.strategy == Encoder.S_DFAST || p.strategy >= Encoder.S_GREEDY
        t += Encoder.is_row(p) ? 4 * Encoder.row_tab_len(p) : 4 << p.chain_log
    end
    return t
end

"""
    estimate_compression_memory(; level=3, src_size=nothing, streaming=false, long=false,
                                nthreads=1, dict_size=0, window_log, ...) -> Int

Estimated bytes of working memory to compress with these settings (as
libzstd's `ZSTD_estimateCCtxSize` / `ZSTD_estimateCStreamSize`): the
match-finder tables sized for `src_size` (unknown when `nothing`, which sizes
them for the level), entropy and parsing scratch, and either the one-shot
output scratch (`streaming=false`) or the stream's window buffer
(`streaming=true`). The input and the returned result are not counted.
Parameter keywords are those of [`compress`](@ref).
"""
function estimate_compression_memory(; level::Union{Nothing,Integer}=nothing, src_size::Union{Nothing,Integer}=nothing,
                                     streaming::Bool=false, long::Bool=false, nthreads::Integer=1,
                                     dict_size::Integer=0, kwargs...)
    ov = Encoder.parameter_overrides(; kwargs...)
    lvl = level === nothing ? 3 : Int(level)
    n = src_size === nothing ? -1 : Int(src_size)
    p = Encoder.compression_parameters(lvl, n < 0 ? -1 : n + Int(dict_size), ov)
    ctx, split, _ = _overheads()
    one = ctx + _table_bytes(p) + (p.strategy >= Encoder.S_BTOPT && p.window_log >= 17 ? split : 0)
    one += 2 * Encoder.BLOCK_SIZE_MAX + 1024           # per-block entropy scratch
    window = 1 << p.window_log
    if streaming
        gran = 1 << max(p.chain_log, 17)
        one += window + Int(dict_size) + gran + 3 * Encoder.BLOCK_SIZE_MAX
    elseif n >= 0
        bound = n + (n >> 7) + 64
        one += bound <= Encoder.OUT_SCRATCH_MAX ? bound : 0
    else
        one += Encoder.BLOCK_SIZE_MAX
    end
    if long
        hl = max(6, min(20, p.window_log - 7))
        one += 8 << hl
    end
    workers = 1
    if nthreads > 1 && n >= 0 && !streaming
        _, job, _ = mt_layout(n, lvl, ov)
        workers = clamp(cld(n, job), 1, Int(nthreads))
    end
    return workers * one
end

"""
    estimate_decompression_memory(; window_size=128 MiB, streaming=true) -> Int

Estimated bytes of working memory to decode frames with windows up to
`window_size` (as libzstd's `ZSTD_estimateDStreamSize`): decoding tables, plus
for streaming the window and block buffers. One-shot `decompress` needs the
decoding tables besides the decoded result itself.
"""
function estimate_decompression_memory(; window_size::Integer=Streaming.DEFAULT_MAX_WINDOW_SIZE,
                                       streaming::Bool=true)
    _, _, ds = _overheads()
    streaming || return ds
    return ds + Int(window_size) + 2 * Encoder.BLOCK_SIZE_MAX + 64
end
