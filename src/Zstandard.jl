module Zstandard

export decompress, compress, ZstdDecompressorStream, ZstdCompressorStream, ZstdDictionary,
       parse_dictionary, ZstdError, ZstandardCompressor, ZstandardDecompressor

const MAGIC_NUMBER = 0xFD2FB528
const SKIPPABLE_MAGIC_START = 0x184D2A50
const SKIPPABLE_MAGIC_END   = 0x184D2A5F

include("decoder.jl")
using .Decoder: ZstdError, ZstdDictionary, parse_dictionary, DecoderState, decompress_frames

include("encoder.jl")
using .Encoder: CompressionContext, compress_frame!

include("streaming.jl")
using .Streaming: ZstdDecompressorStream, ZstdCompressorStream

"""
    ZstandardCompressor(; level=3, checksum=false, dict=nothing)

A [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl) codec
compressing to the Zstandard format, for use with `transcode`,
`TranscodingStream`, etc. Available once `TranscodingStreams` is loaded.

```julia
using Zstandard, TranscodingStreams
compressed = transcode(ZstandardCompressor(level=5), data)
stream = TranscodingStream(ZstandardCompressor(), open("out.zst", "w"))
```
"""
function ZstandardCompressor end

"""
    ZstandardDecompressor(; dict=nothing)

A [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl) codec
decoding Zstandard data (concatenated and skippable frames included).
Available once `TranscodingStreams` is loaded.
"""
function ZstandardDecompressor end

function __init__()
    if isdefined(Base.Experimental, :register_error_hint)
        Base.Experimental.register_error_hint(MethodError) do io, exc, argtypes, kwargs
            if exc.f === ZstandardCompressor || exc.f === ZstandardDecompressor
                print(io, "\n$(exc.f) requires TranscodingStreams.jl; run `using TranscodingStreams` first.")
            end
        end
    end
end

# Pool of reusable decoder scratch states (~150KB each), so that repeated
# `decompress` calls do not reallocate them. Safe for concurrent use.
const _STATE_LOCK = ReentrantLock()
const _STATE_POOL = DecoderState[]

function _with_state(f)
    st = lock(_STATE_LOCK) do
        isempty(_STATE_POOL) ? DecoderState() : pop!(_STATE_POOL)
    end
    try
        return f(st)
    finally
        lock(_STATE_LOCK) do
            push!(_STATE_POOL, st)
        end
    end
end

const _CCTX_LOCK = ReentrantLock()
const _CCTX_POOL = CompressionContext[]

function _with_cctx(f)
    cc = lock(_CCTX_LOCK) do
        isempty(_CCTX_POOL) ? CompressionContext() : pop!(_CCTX_POOL)
    end
    try
        return f(cc)
    finally
        lock(_CCTX_LOCK) do
            push!(_CCTX_POOL, cc)
        end
    end
end

# Positions are stored as Int32 in the match finder tables.
const MAX_FRAME_INPUT = 1 << 30

"""
    compress(data; level=3, checksum=false, dict=nothing) -> Vector{UInt8}

Compress `data` (a byte vector or string) into a Zstandard frame.

`level` ranges from $(Encoder.MIN_LEVEL) (fastest) to $(Encoder.MAX_LEVEL) (strongest);
`0` selects the default level 3, as in libzstd. With `checksum=true` an XXH64
content checksum is appended. With a `ZstdDictionary`, its content serves as
history and, for formatted dictionaries, its entropy tables and repeat offsets
are used; the frame records the dictionary ID. Inputs larger than 1 GiB are
written as several concatenated frames.
"""
function compress(data::AbstractVector{UInt8}; level::Integer=3, checksum::Bool=false,
                  dict::Union{Nothing,ZstdDictionary}=nothing)
    _with_cctx() do cc
        if length(data) <= MAX_FRAME_INPUT
            return compress_frame!(cc, data, level; checksum, dict)
        end
        out = UInt8[]
        for off in 0:MAX_FRAME_INPUT:length(data)-1
            chunk = view(data, off+1:min(off + MAX_FRAME_INPUT, length(data)))
            append!(out, compress_frame!(cc, chunk, level; checksum, dict))
        end
        return out
    end
end
compress(data::AbstractString; kwargs...) = compress(codeunits(data); kwargs...)

"""
    decompress(data::AbstractVector{UInt8}, dict::Union{Nothing, ZstdDictionary}=nothing)

Decompress Zstandard compressed data, which may contain several concatenated
and/or skippable frames. Optionally, a `ZstdDictionary` can be provided.
Throws a [`ZstdError`](@ref) if the data is malformed.
"""
function decompress(data::AbstractVector{UInt8}, dict::Union{Nothing, ZstdDictionary}=nothing)
    return _with_state(st -> decompress_frames(data, st, dict))
end

end # module
