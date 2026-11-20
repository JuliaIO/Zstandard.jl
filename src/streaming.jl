# Streaming decompression and compression for Zstandard

module Streaming

import ..Decoder: DecoderState, ZstdDictionary, FrameInfo, read_frame_info, reset_frame!,
                  decode_compressed_block!, memset!, zerr, ensure_capacity!, ZstdError,
                  MAGIC_NUMBER, SKIPPABLE_MAGIC_START, SKIPPABLE_MASK, BLOCK_SIZE_MAX, WILDCOPY_SLACK
import ..Encoder: StreamCompressor, stream_write!, stream_flush!, stream_finish!
using ..XXHash: ChecksumState, checksum_update!, checksum_digest

export ZstdDecompressorStream, ZstdCompressorStream, StreamDecoder

# ---------------------------------------------------------------------------
# Push-based decoder core
# ---------------------------------------------------------------------------
# The decoder consumes its input one "unit" at a time (magic number, frame
# header, block header, block body, checksum) and asks for exactly the bytes
# that unit needs (`needed`), so it never reads past the end of a frame.

const U_MAGIC = 0
const U_SKIPSIZE = 1
const U_SKIP = 2
const U_FHDR1 = 3
const U_FHDR = 4
const U_BHDR = 5
const U_BODY = 6
const U_CKSUM = 7

"""
    StreamDecoder(dict=nothing)

Incremental Zstandard decoder. Feed input with [`feed!`](@ref) (at most
[`needed`](@ref) bytes are consumed per call); decoded bytes are available in
`d.out[d.rpos:d.wpos]`.
"""
mutable struct StreamDecoder
    dict::Union{Nothing,ZstdDictionary}
    st::DecoderState
    unit::Vector{UInt8}
    have::Int            # bytes of the current unit received
    want::Int            # size of the current unit
    ustage::Int
    skip_left::Int
    btype::Int
    blast::Bool
    out::Vector{UInt8}
    rpos::Int            # next unread byte in `out` (1-based)
    wpos::Int            # number of valid bytes in `out`
    frame_start::Int     # 0-based offset of the current frame's first byte in `out` (may be < 0)
    in_frame::Bool
    frames_done::Int     # number of completed frames
    fi::FrameInfo
    frame_produced::Int
    xxh::Union{Nothing,ChecksumState}
end

function StreamDecoder(dict::Union{Nothing,ZstdDictionary}=nothing)
    StreamDecoder(dict, DecoderState(), Vector{UInt8}(undef, 64), 0, 4, U_MAGIC, 0, 0, false,
        UInt8[], 1, 0, 0, false, 0, FrameInfo(0, 0, -1, 0, false, false), 0, nothing)
end

"""Number of input bytes the decoder wants next (0 never happens)."""
needed(d::StreamDecoder) = d.ustage == U_SKIP ? d.skip_left : d.want - d.have

"""True when the decoder is between frames (input may legitimately end here)."""
at_boundary(d::StreamDecoder) = d.ustage == U_MAGIC && d.have == 0

available(d::StreamDecoder) = d.wpos - d.rpos + 1

function set_unit!(d::StreamDecoder, stage::Int, n::Int)
    d.ustage = stage
    d.want = n
    d.have = 0
    length(d.unit) < n && resize!(d.unit, n)
    return d
end

# Discard bytes that are already read and no longer needed as match history.
function compact!(d::StreamDecoder)
    hist_from = d.in_frame ? max(d.frame_start, d.wpos - d.fi.window_size) : d.wpos
    drop = min(d.rpos - 1, hist_from)
    if drop > 0
        copyto!(d.out, 1, d.out, drop + 1, d.wpos - drop)
        d.rpos -= drop
        d.wpos -= drop
        d.frame_start -= drop
    end
    return d
end

function make_room!(d::StreamDecoder, n::Int)
    need = d.wpos + n + WILDCOPY_SLACK
    if length(d.out) < need
        compact!(d)
        ensure_capacity!(d.out, d.wpos + n + WILDCOPY_SLACK)
    end
end

@inline u32(b::Vector{UInt8}) = UInt32(b[1]) | (UInt32(b[2]) << 8) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 24)

function begin_frame!(d::StreamDecoder, hdr::AbstractVector{UInt8})
    h = Vector{UInt8}(hdr)
    fi = GC.@preserve h read_frame_info(pointer(h), length(h))
    dict = d.dict
    if fi.dict_id != 0
        dict === nothing && zerr("frame requires dictionary ID $(fi.dict_id)")
        (dict.id != 0 && dict.id != fi.dict_id) &&
            zerr("dictionary ID mismatch: frame requires $(fi.dict_id), got $(dict.id)")
    end
    reset_frame!(d.st, dict)
    d.fi = fi
    compact!(d)   # previous frames are never referenced
    d.frame_start = d.wpos
    d.frame_produced = 0
    d.in_frame = true
    d.xxh = fi.checksum ? ChecksumState() : nothing
    set_unit!(d, U_BHDR, 3)
end

function end_frame!(d::StreamDecoder)
    fi = d.fi
    if fi.content_size >= 0 && d.frame_produced != fi.content_size
        zerr("frame content size mismatch: header says $(fi.content_size), decoded $(d.frame_produced)")
    end
    if fi.checksum
        set_unit!(d, U_CKSUM, 4)
    else
        d.in_frame = false
        d.frames_done += 1
        set_unit!(d, U_MAGIC, 4)
    end
end

function decode_body!(d::StreamDecoder)
    bsize = d.want
    lim = BLOCK_SIZE_MAX
    if d.btype == 2 && d.fi.content_size >= 0
        lim = min(lim, Int(d.fi.content_size) - d.frame_produced)
        lim < 0 && zerr("frame content size exceeded")
    end
    # make_room! may compact the buffer (moving wpos), so take `start` after it
    make_room!(d, d.btype == 0 ? bsize : d.btype == 1 ? d.skip_left : lim)
    start = d.wpos
    if d.btype == 0
        copyto!(d.out, d.wpos + 1, d.unit, 1, bsize)
        d.wpos += bsize
    elseif d.btype == 1
        n = d.skip_left          # RLE regenerated size
        GC.@preserve d memset!(pointer(d.out) + d.wpos, d.unit[1], n)
        d.wpos += n
    else
        out = d.out
        inp = d.unit
        hist = max(d.frame_start, 0)
        dict = d.frame_start >= 0 ? d.dict : nothing
        GC.@preserve out inp begin
            base = pointer(out)
            op = decode_compressed_block!(d.st, pointer(inp), bsize, base + d.wpos,
                                          base + hist, base + d.wpos + lim, dict)
            d.wpos = Int(op - base)
        end
    end
    d.frame_produced += d.wpos - start
    if d.xxh !== nothing && d.wpos > start
        checksum_update!(d.xxh, view(d.out, start+1:d.wpos))
    end
    if d.blast
        end_frame!(d)
    else
        set_unit!(d, U_BHDR, 3)
    end
end

# Called when the current unit is complete.
function process_unit!(d::StreamDecoder)
    u = d.unit
    st = d.ustage
    if st == U_MAGIC
        magic = u32(u)
        if magic & SKIPPABLE_MASK == SKIPPABLE_MAGIC_START
            set_unit!(d, U_SKIPSIZE, 4)
        elseif magic == MAGIC_NUMBER
            set_unit!(d, U_FHDR1, 1)
        else
            zerr("unknown frame magic number 0x$(string(magic, base=16))")
        end
    elseif st == U_SKIPSIZE
        n = Int(u32(u))
        if n == 0
            set_unit!(d, U_MAGIC, 4)
        else
            d.ustage = U_SKIP
            d.skip_left = n
        end
    elseif st == U_FHDR1
        fd = u[1]
        single = (fd >> 5) & 1 == 1
        hs = 1 + (single ? 0 : 1) + (0, 1, 2, 4)[(fd & 3) + 1] + (single ? 1 : 0, 2, 4, 8)[(fd >> 6) + 1]
        if hs == 1
            begin_frame!(d, view(u, 1:1))
        else
            d.ustage = U_FHDR
            d.want = hs
            d.have = 1
            length(d.unit) < hs && resize!(d.unit, hs)
        end
    elseif st == U_FHDR
        begin_frame!(d, view(u, 1:d.want))
    elseif st == U_BHDR
        bh = Int(u[1]) | (Int(u[2]) << 8) | (Int(u[3]) << 16)
        d.blast = bh & 1 == 1
        d.btype = (bh >> 1) & 3
        bsize = bh >> 3
        d.btype == 3 && zerr("reserved block type")
        bsize > BLOCK_SIZE_MAX && zerr("block too large")
        if d.btype == 1
            d.skip_left = bsize
            set_unit!(d, U_BODY, 1)
        elseif bsize == 0
            d.want = 0
            decode_body!(d)
        else
            set_unit!(d, U_BODY, bsize)
        end
    elseif st == U_BODY
        decode_body!(d)
    elseif st == U_CKSUM
        expected = u32(u)
        actual = checksum_digest(d.xxh)
        actual != expected && zerr("checksum mismatch")
        d.in_frame = false
        d.frames_done += 1
        set_unit!(d, U_MAGIC, 4)
    end
    return d
end

"""
    feed!(d::StreamDecoder, p::Ptr{UInt8}, n) -> consumed

Consume up to `needed(d)` of the `n` bytes at `p`, decoding as units complete.
"""
function feed!(d::StreamDecoder, p::Ptr{UInt8}, n::Int)
    n <= 0 && return 0
    if d.ustage == U_SKIP
        k = min(n, d.skip_left)
        d.skip_left -= k
        d.skip_left == 0 && set_unit!(d, U_MAGIC, 4)
        return k
    end
    k = min(n, d.want - d.have)
    GC.@preserve d unsafe_copyto!(pointer(d.unit, d.have + 1), p, k)
    d.have += k
    d.have == d.want && process_unit!(d)
    return k
end

# Fill the current unit directly from an IO. Returns bytes read.
function feed_from!(d::StreamDecoder, io::IO)
    if d.ustage == U_SKIP
        k = min(d.skip_left, 1 << 16)
        length(d.unit) < k && resize!(d.unit, k)
        got = readbytes!(io, d.unit, k)
        d.skip_left -= got
        d.skip_left == 0 && set_unit!(d, U_MAGIC, 4)
        return got
    end
    k = d.want - d.have
    got = if d.have == 0
        readbytes!(io, d.unit, k)
    else
        tmp = Vector{UInt8}(undef, k)
        g = readbytes!(io, tmp, k)
        copyto!(d.unit, d.have + 1, tmp, 1, g)
        g
    end
    d.have += got
    d.have == d.want && process_unit!(d)
    return got
end

# ---------------------------------------------------------------------------
# ZstdDecompressorStream
# ---------------------------------------------------------------------------

"""
    ZstdDecompressorStream(io::IO, dict::Union{Nothing, ZstdDictionary}=nothing)

A streaming Zstandard decompressor that implements the `IO` interface.
Decoded data is produced one block at a time; memory use is bounded by the
frame's window size plus one block.

After a decoding error (a `ZstdError`), the stream is unusable: later reads
rethrow the same error (bytes decoded before it can still be read). Other
exceptions, such as an interrupt or an error from `io`, are not sticky.
"""
mutable struct ZstdDecompressorStream <: IO
    io::IO
    d::StreamDecoder
    err::Union{Nothing,ZstdError}   # sticky decoding error
end

ZstdDecompressorStream(io::IO, dict::Union{Nothing,ZstdDictionary}=nothing) =
    ZstdDecompressorStream(io, StreamDecoder(dict), nothing)

# Decode until at least one unread byte is available. Returns false at end of input.
function fill_buffer!(s::ZstdDecompressorStream)
    s.err === nothing || throw(s.err)
    try
        return fill_buffer_unchecked!(s)
    catch e
        # after a decoding error the position in the input is lost: stay failed
        e isa ZstdError && (s.err = e)
        rethrow()
    end
end

function fill_buffer_unchecked!(s::ZstdDecompressorStream)
    d = s.d
    while available(d) <= 0
        if eof(s.io)
            at_boundary(d) && return false
            zerr("truncated input")
        end
        feed_from!(d, s.io) == 0 && zerr("truncated input")
    end
    return true
end

Base.bytesavailable(s::ZstdDecompressorStream) = available(s.d)
Base.eof(s::ZstdDecompressorStream) = available(s.d) <= 0 && !fill_buffer!(s)
Base.isopen(s::ZstdDecompressorStream) = isopen(s.io)
Base.close(s::ZstdDecompressorStream) = close(s.io)

function Base.read(s::ZstdDecompressorStream, ::Type{UInt8})
    eof(s) && throw(EOFError())
    d = s.d
    v = @inbounds d.out[d.rpos]
    d.rpos += 1
    return v
end

function Base.unsafe_read(s::ZstdDecompressorStream, p::Ptr{UInt8}, n::UInt)
    n = Int(n)
    d = s.d
    while n > 0
        eof(s) && throw(EOFError())
        k = min(n, available(d))
        GC.@preserve d unsafe_copyto!(p, pointer(d.out, d.rpos), k)
        d.rpos += k
        p += k
        n -= k
    end
    return nothing
end

function Base.readbytes!(s::ZstdDecompressorStream, b::AbstractVector{UInt8}, nb=length(b))
    got = 0
    d = s.d
    while got < nb && !eof(s)
        k = min(nb - got, available(d))
        got + k > length(b) && resize!(b, got + k)
        copyto!(b, got + 1, d.out, d.rpos, k)
        d.rpos += k
        got += k
    end
    return got
end

function Base.read(s::ZstdDecompressorStream)
    out = UInt8[]
    d = s.d
    while !eof(s)
        append!(out, view(d.out, d.rpos:d.wpos))
        d.rpos = d.wpos + 1
    end
    return out
end

# At most `nb` bytes: start small and let readbytes! grow the vector as data
# arrives, rather than allocating `nb` bytes up front.
function Base.read(s::ZstdDecompressorStream, nb::Integer)
    nb < 0 && throw(ArgumentError("nb must be non-negative, got $nb"))
    b = Vector{UInt8}(undef, min(Int(nb), 1 << 16))
    return resize!(b, readbytes!(s, b, nb))
end

# ---------------------------------------------------------------------------
# ZstdCompressorStream
# ---------------------------------------------------------------------------

"""
    ZstdCompressorStream(io::IO; level=3, checksum=false, dict=nothing, close_io=true)

A streaming Zstandard compressor implementing the writable `IO` interface.
Data written to the stream is compressed into a single frame (without a
content size) and written to `io` block by block. `flush` emits all pending
data as a complete block, so everything written so far can be decoded.
`close` finishes the frame and, if `close_io` is true, closes `io` (pass
`close_io=false` to keep writing to `io`, e.g. an `IOBuffer` read afterwards).
"""
mutable struct ZstdCompressorStream <: IO
    io::IO
    sc::StreamCompressor
    closed::Bool
    close_io::Bool
end

function ZstdCompressorStream(io::IO; level::Integer=3, checksum::Bool=false,
                              dict::Union{Nothing,ZstdDictionary}=nothing, close_io::Bool=true)
    ZstdCompressorStream(io, StreamCompressor(; level, checksum, dict), false, close_io)
end

function drain!(s::ZstdCompressorStream)
    sc = s.sc
    if sc.olen > 0
        GC.@preserve sc unsafe_write(s.io, pointer(sc.out), sc.olen)
        sc.olen = 0
    end
end

function Base.unsafe_write(s::ZstdCompressorStream, p::Ptr{UInt8}, n::UInt)
    s.closed && throw(ArgumentError("stream is closed"))
    stream_write!(s.sc, unsafe_wrap(Array, p, Int(n)))
    drain!(s)
    return Int(n)
end

Base.write(s::ZstdCompressorStream, x::UInt8) = (r = Ref(x); GC.@preserve r unsafe_write(s, Base.unsafe_convert(Ptr{UInt8}, r), UInt(1)))

function Base.flush(s::ZstdCompressorStream)
    s.closed && return
    stream_flush!(s.sc)
    drain!(s)
    flush(s.io)
end

Base.isopen(s::ZstdCompressorStream) = !s.closed
Base.isreadable(::ZstdCompressorStream) = false
Base.iswritable(s::ZstdCompressorStream) = !s.closed

function Base.close(s::ZstdCompressorStream)
    s.closed && return
    stream_finish!(s.sc)
    drain!(s)
    s.closed = true
    s.close_io ? close(s.io) : flush(s.io)
    return nothing
end

end # module
