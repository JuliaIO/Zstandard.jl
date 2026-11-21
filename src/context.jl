# Reusable compression and decompression contexts (libzstd's ZSTD_CCtx and
# ZSTD_DCtx). Included in module Zstandard.

"""
    ZstandardCompressionContext(; level=3, checksum=false, dict=nothing, long=false,
                           content_size=true, dict_id=true, magicless=false, prefix=nothing,
                           window_log, hash_log, chain_log, search_log, min_match,
                           target_length, strategy)

A compression context with fixed parameters, reused across calls (as a
libzstd `ZSTD_CCtx`): its match-finder tables, entropy scratch and output
buffer persist, and parameters are validated once. Use it with
`compress(ctx, data)`, or `compress!(ctx, out, data)` to write into a vector
you reuse as well, which avoids allocating a result per call (worthwhile for
many small inputs). The keywords mean the same as for [`compress`](@ref).

A context must not be used by several tasks at the same time.

```julia
ctx = ZstandardCompressionContext(level=5, checksum=true)
out = UInt8[]
for msg in messages
    compress!(ctx, out, msg)
    send(out)
end
```
"""
mutable struct ZstandardCompressionContext
    cc::CompressionContext
    level::Int
    checksum::Bool
    dict::Union{Nothing,ZstandardDictionary,PreparedDictionary}
    long::Bool
    params::Encoder.ParameterOverrides
    frame::Encoder.FrameOptions
    prefix::Union{Nothing,Vector{UInt8}}
end

function ZstandardCompressionContext(; level::Union{Nothing,Integer}=nothing, checksum::Bool=false,
                                dict::Union{Nothing,ZstandardDictionary,PreparedDictionary}=nothing,
                                long::Bool=false, content_size::Bool=true, dict_id::Bool=true,
                                magicless::Bool=false, prefix::Union{Nothing,AbstractVector{UInt8}}=nothing,
                                target_block_size::Union{Nothing,Integer}=nothing,
                                window_log=nothing, hash_log=nothing,
                                chain_log=nothing, search_log=nothing, min_match=nothing,
                                target_length=nothing, strategy=nothing)
    params = Encoder.parameter_overrides(; window_log, hash_log, chain_log, search_log, min_match,
                                         target_length, strategy)
    if dict isa PreparedDictionary
        Encoder.use_prepared(dict, 0, level, params)     # checks level and parameters
        level = dict.level
    end
    level = level === nothing ? 3 : Int(level)
    dict = Encoder.prefix_dict(prefix, dict)
    return ZstandardCompressionContext(CompressionContext(), level, checksum, dict, long, params,
                                  Encoder.FrameOptions(; content_size, dict_id, magicless, target_block_size),
                                  prefix === nothing ? nothing : Vector{UInt8}(prefix))
end

function Base.show(io::IO, ctx::ZstandardCompressionContext)
    print(io, "ZstandardCompressionContext(level=", ctx.level, ctx.checksum ? ", checksum=true" : "",
          ctx.dict === nothing ? "" : ", dict", ctx.long ? ", long=true" : "", ")")
end

_bytes(data::AbstractVector{UInt8}) = data
_bytes(data::AbstractString) = codeunits(data)

"""
    compress(ctx::ZstandardCompressionContext, data) -> Vector{UInt8}

Compress `data` (a byte vector or string) with the context's parameters.
"""
compress(ctx::ZstandardCompressionContext, data::Union{AbstractVector{UInt8},AbstractString}) =
    compress!(ctx, UInt8[], data)

"""
    compress!(ctx::ZstandardCompressionContext, out::Vector{UInt8}, data) -> out

Compress `data` into `out`, which is resized to the compressed frame. Reusing
`out` across calls avoids allocating (its capacity is kept by Julia).
"""
function compress!(ctx::ZstandardCompressionContext, out::Vector{UInt8},
                   data::Union{AbstractVector{UInt8},AbstractString})
    src = _bytes(data)
    out === src && throw(ArgumentError("out must not be the input"))
    params = Encoder.prefix_params(ctx.params, ctx.prefix, ctx.level, min(length(src), MAX_FRAME_INPUT))
    if length(src) <= MAX_FRAME_INPUT
        return compress_frame!(ctx.cc, src, ctx.level; checksum=ctx.checksum, dict=ctx.dict,
                               long=ctx.long, params, dest=out, frame=ctx.frame)
    end
    empty!(out)
    for off in 0:MAX_FRAME_INPUT:length(src)-1
        chunk = view(src, off+1:min(off + MAX_FRAME_INPUT, length(src)))
        append!(out, compress_frame!(ctx.cc, chunk, ctx.level; checksum=ctx.checksum, dict=ctx.dict,
                                     long=ctx.long, params, frame=ctx.frame))
    end
    return out
end

"""
    ZstandardDecompressionContext(; dict=nothing, magicless=false, prefix=nothing)

A decompression context reused across calls (as a libzstd `ZSTD_DCtx`): its
decoding tables persist. Use it with `decompress(ctx, data)`, or
`decompress!(ctx, out, data)` to decode into a vector you reuse. Data may hold
several concatenated and skippable frames; `dict` is used for frames that
need it. `dict` may also be a [`ZstandardDictionarySet`](@ref) (or a vector of
`ZstandardDictionary`) to choose each frame's dictionary by its ID. With `magicless=true`, frames have no magic numbers (see `compress`).

A context must not be used by several tasks at the same time.
"""
mutable struct ZstandardDecompressionContext
    st::DecoderState
    dict::DecodeDict
    magicless::Bool
end
ZstandardDecompressionContext(; dict::DictArg=nothing,
                         magicless::Bool=false, prefix::Union{Nothing,AbstractVector{UInt8}}=nothing) =
    ZstandardDecompressionContext(DecoderState(), Encoder.prefix_dict(prefix, decode_dict(dict)), magicless)

Base.show(io::IO, ctx::ZstandardDecompressionContext) =
    print(io, "ZstandardDecompressionContext(", ctx.dict === nothing ? "" :
          ctx.dict isa ZstandardDictionarySet ? "dicts" : "dict", ")")

"""
    decompress(ctx::ZstandardDecompressionContext, data) -> Vector{UInt8}

Decompress `data` with the context (and its dictionary, if any).
"""
decompress(ctx::ZstandardDecompressionContext, data::AbstractVector{UInt8}) =
    decompress_frames(data, ctx.st, ctx.dict; magicless=ctx.magicless)

"""
    decompress!(ctx::ZstandardDecompressionContext, out::Vector{UInt8}, data) -> out

Decompress `data` into `out`, which is resized to the decoded content. Reusing
`out` across calls avoids allocating (its capacity is kept by Julia). If
decoding throws, `out` is left empty.
"""
function decompress!(ctx::ZstandardDecompressionContext, out::Vector{UInt8}, data::AbstractVector{UInt8})
    out === data && throw(ArgumentError("out must not be the input"))
    resize!(out, 0)
    try
        return decompress_frames(data, ctx.st, ctx.dict; out, magicless=ctx.magicless, release=false)
    catch
        resize!(out, 0)          # no partly undefined contents after an error
        rethrow()
    end
end
