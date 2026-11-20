module ZstandardTranscodingStreamsExt

using Zstandard
using Zstandard: ZstdDictionary, ZstdError
using Zstandard.Encoder: StreamCompressor, stream_write!, stream_finish!, stream_pledge!
using Zstandard.Streaming: StreamDecoder, feed!, needed, at_boundary, available
import TranscodingStreams
using TranscodingStreams: Codec, Memory, Error

# ---------------------------------------------------------------------------
# Compressor
# ---------------------------------------------------------------------------

mutable struct ZstandardCompressorCodec <: Codec
    level::Union{Nothing,Int}
    checksum::Bool
    dict::Union{Nothing,ZstdDictionary,Zstandard.PreparedDictionary}
    params::Zstandard.Encoder.ParameterOverrides
    sc::StreamCompressor
    opos::Int            # next byte of sc.out to emit
end

function Zstandard.ZstandardCompressor(; level::Union{Nothing,Integer}=nothing, checksum::Bool=false,
                                       dict::Union{Nothing,ZstdDictionary,Zstandard.PreparedDictionary}=nothing,
                                       window_log=nothing, hash_log=nothing, chain_log=nothing, search_log=nothing, min_match=nothing, target_length=nothing, strategy=nothing)
    params = Zstandard.Encoder.parameter_overrides(; window_log, hash_log, chain_log, search_log, min_match, target_length, strategy)
    sc = StreamCompressor(; level, checksum, dict, params)
    ZstandardCompressorCodec(sc.level, checksum, dict, params, sc, 1)
end

Base.show(io::IO, c::ZstandardCompressorCodec) = print(io, "ZstandardCompressor(level=$(c.level))")

function TranscodingStreams.startproc(c::ZstandardCompressorCodec, mode::Symbol, err::Error)
    c.sc = StreamCompressor(; level=c.level, checksum=c.checksum, dict=c.dict, params=c.params)
    c.opos = 1
    return :ok
end

# `transcode` pledges the total input size: record it in the frame header.
function TranscodingStreams.pledgeinsize(c::ZstandardCompressorCodec, insize::Int64, err::Error)
    try
        stream_pledge!(c.sc, insize)
        return :ok
    catch e
        err[] = e
        return :error
    end
end

function emit!(c::ZstandardCompressorCodec, output::Memory)
    sc = c.sc
    k = min(Int(output.size), sc.olen - c.opos + 1)
    if k > 0
        GC.@preserve sc unsafe_copyto!(output.ptr, pointer(sc.out, c.opos), k)
        c.opos += k
        if c.opos > sc.olen
            sc.olen = 0
            c.opos = 1
        end
    end
    return k
end

function TranscodingStreams.process(c::ZstandardCompressorCodec, input::Memory, output::Memory, err::Error)
    try
        sc = c.sc
        # Emit pending output before accepting more input.
        if c.opos <= sc.olen
            return 0, emit!(c, output), :ok
        end
        if input.size > 0
            stream_write!(sc, unsafe_wrap(Array, input.ptr, Int(input.size)))
            return Int(input.size), emit!(c, output), :ok
        end
        sc.finished || stream_finish!(sc)
        k = emit!(c, output)
        return 0, k, c.opos <= sc.olen ? :ok : :end
    catch e
        err[] = e
        return 0, 0, :error
    end
end

# ---------------------------------------------------------------------------
# Decompressor
# ---------------------------------------------------------------------------

mutable struct ZstandardDecompressorCodec <: Codec
    dict::Union{Nothing,ZstdDictionary}
    max_window_size::Int
    d::StreamDecoder
    frames_reported::Int
end

Zstandard.ZstandardDecompressor(; dict::Union{Nothing,ZstdDictionary}=nothing,
                                max_window_size::Integer=Zstandard.Streaming.DEFAULT_MAX_WINDOW_SIZE) =
    ZstandardDecompressorCodec(dict, Int(max_window_size), StreamDecoder(dict; max_window_size), 0)

Base.show(io::IO, ::ZstandardDecompressorCodec) = print(io, "ZstandardDecompressor()")

# Use the content sizes recorded in the frame headers, when all are present.
function TranscodingStreams.expectedsize(c::ZstandardDecompressorCodec, input::Memory)
    n = Int(input.size)
    n == 0 && return 0
    try
        data = unsafe_wrap(Array, input.ptr, n)
        s = Zstandard.decompressed_size(data)
        return s === nothing ? 4n : Int(s)
    catch
        return 4n
    end
end

function TranscodingStreams.startproc(c::ZstandardDecompressorCodec, mode::Symbol, err::Error)
    # Keep the decoder (and its buffers) only at a clean frame boundary: mid-frame,
    # or with decoded bytes that were never read, it belongs to an abandoned stream.
    if !at_boundary(c.d) || available(c.d) > 0
        c.d = StreamDecoder(c.dict; max_window_size=c.max_window_size)
        c.frames_reported = 0
    end
    return :ok
end

function TranscodingStreams.process(c::ZstandardDecompressorCodec, input::Memory, output::Memory, err::Error)
    try
        d = c.d
        # 1. deliver decoded bytes
        if available(d) > 0
            k = min(Int(output.size), available(d))
            GC.@preserve d unsafe_copyto!(output.ptr, pointer(d.out, d.rpos), k)
            d.rpos += k
            return 0, k, :ok
        end
        # 2. a frame finished and its output is drained
        if d.frames_done > c.frames_reported && at_boundary(d)
            c.frames_reported = d.frames_done
            return 0, 0, :end
        end
        # 3. consume input
        if input.size == 0
            at_boundary(d) && return 0, 0, :end
            throw(ZstdError("truncated input"))
        end
        consumed = 0
        while consumed < input.size && available(d) == 0 &&
              !(d.frames_done > c.frames_reported && at_boundary(d))
            consumed += feed!(d, input.ptr + consumed, Int(input.size) - consumed)
        end
        k = 0
        if available(d) > 0
            k = min(Int(output.size), available(d))
            GC.@preserve d unsafe_copyto!(output.ptr, pointer(d.out, d.rpos), k)
            d.rpos += k
        end
        return consumed, k, :ok
    catch e
        err[] = e
        return 0, 0, :error
    end
end

# Precompilation workload for the codecs (see src/precompile.jl).
if ccall(:jl_generating_output, Cint, ()) == 1
    let data = Vector{UInt8}(repeat("TranscodingStreams precompile workload. ", 2000))
        c = transcode(Zstandard.ZstandardCompressor(), data)
        transcode(Zstandard.ZstandardDecompressor(), c)
        read(TranscodingStreams.TranscodingStream(Zstandard.ZstandardDecompressor(), IOBuffer(c)))
    end
end

end # module
