module ZstandardTranscodingStreamsExt

using Zstandard
using Zstandard: ZstdDictionary, ZstdError
using Zstandard.Encoder: StreamCompressor, stream_write!, stream_finish!
using Zstandard.Streaming: StreamDecoder, feed!, needed, at_boundary, available
import TranscodingStreams
using TranscodingStreams: Codec, Memory, Error

# ---------------------------------------------------------------------------
# Compressor
# ---------------------------------------------------------------------------

mutable struct ZstandardCompressorCodec <: Codec
    level::Int
    checksum::Bool
    dict::Union{Nothing,ZstdDictionary}
    sc::StreamCompressor
    opos::Int            # next byte of sc.out to emit
end

Zstandard.ZstandardCompressor(; level::Integer=3, checksum::Bool=false,
                              dict::Union{Nothing,ZstdDictionary}=nothing) =
    ZstandardCompressorCodec(Int(level), checksum, dict, StreamCompressor(; level, checksum, dict), 1)

Base.show(io::IO, c::ZstandardCompressorCodec) = print(io, "ZstandardCompressor(level=$(c.level))")

function TranscodingStreams.startproc(c::ZstandardCompressorCodec, mode::Symbol, err::Error)
    c.sc = StreamCompressor(; level=c.level, checksum=c.checksum, dict=c.dict)
    c.opos = 1
    return :ok
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
    d::StreamDecoder
    frames_reported::Int
end

Zstandard.ZstandardDecompressor(; dict::Union{Nothing,ZstdDictionary}=nothing) =
    ZstandardDecompressorCodec(dict, StreamDecoder(dict), 0)

Base.show(io::IO, ::ZstandardDecompressorCodec) = print(io, "ZstandardDecompressor()")

function TranscodingStreams.startproc(c::ZstandardDecompressorCodec, mode::Symbol, err::Error)
    if !at_boundary(c.d)
        c.d = StreamDecoder(c.dict)
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

end # module
