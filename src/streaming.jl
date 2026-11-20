# Streaming decompression and compression for Zstandard

module Streaming

import ..Decoder: DecoderState, ZstdDictionary, FrameInfo, read_frame_info, reset_frame!,
                  decode_compressed_block!, memset!, zerr, ensure_capacity!, ZstdError,
                  MAGIC_NUMBER, SKIPPABLE_MAGIC_START, SKIPPABLE_MASK, BLOCK_SIZE_MAX, WILDCOPY_SLACK
import ..Encoder: StreamCompressor, stream_write!, stream_flush!, stream_finish!, PreparedDictionary, FrameOptions,
                  prefix_dict, prefix_params,
                  parameter_overrides
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
    max_window::Int      # largest window size accepted
    magicless::Bool      # frames have no magic number (libzstd's ZSTD_f_zstd1_magicless)
    consumed::Int        # input bytes fed
    produced::Int        # bytes decoded (all frames)
end

"""
Default largest window a streaming decoder accepts: 128 MiB, as libzstd's
default `windowLogMax` of 27. Frames Zstandard.jl writes stay within it
(`long=true` included) unless `window_log` above 27 is passed explicitly; such
frames need a larger `max_window_size` here (or `--long=N` / `windowLogMax`
with libzstd).
"""
const DEFAULT_MAX_WINDOW_SIZE = 1 << 27

function StreamDecoder(dict::Union{Nothing,ZstdDictionary}=nothing;
                       max_window_size::Integer=DEFAULT_MAX_WINDOW_SIZE, magicless::Bool=false)
    max_window_size >= 1 << 10 || throw(ArgumentError("max_window_size must be at least 1 KiB"))
    StreamDecoder(dict, DecoderState(), Vector{UInt8}(undef, 64), 0, magicless ? 1 : 4,
        magicless ? U_FHDR1 : U_MAGIC, 0, 0, false,
        UInt8[], 1, 0, 0, false, 0, FrameInfo(0, 0, -1, 0, false, false), 0, nothing,
        Int(max_window_size), magicless, 0, 0)
end

# Expect the start of the next frame.
next_frame_unit!(d::StreamDecoder) = d.magicless ? set_unit!(d, U_FHDR1, 1) : set_unit!(d, U_MAGIC, 4)

"""Number of input bytes the decoder wants next (0 never happens)."""
needed(d::StreamDecoder) = d.ustage == U_SKIP ? d.skip_left : d.want - d.have

"""True when the decoder is between frames (input may legitimately end here)."""
at_boundary(d::StreamDecoder) = (d.magicless ? d.ustage == U_FHDR1 : d.ustage == U_MAGIC) && d.have == 0

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
        need = d.wpos + n + WILDCOPY_SLACK
        if length(d.out) < need
            # grow exactly (resize! over-allocates): doubling, up to two windows
            # plus two blocks, so that compaction moves each byte about once
            # (with one window, it would move the whole window every block)
            full = 2 * d.fi.window_size + 2 * BLOCK_SIZE_MAX + WILDCOPY_SLACK
            newlen = max(need, min(2 * length(d.out), full))
            w = Vector{UInt8}(undef, newlen)
            copyto!(w, 1, d.out, 1, d.wpos)
            d.out = w
        end
    end
end

@inline u32(b::Vector{UInt8}) = UInt32(b[1]) | (UInt32(b[2]) << 8) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 24)

function begin_frame!(d::StreamDecoder, hdr::AbstractVector{UInt8})
    h = Vector{UInt8}(hdr)
    fi = GC.@preserve h read_frame_info(pointer(h), length(h))
    # Decoding keeps up to one window of history in memory, so refuse windows
    # above the limit (libzstd: frameParameter_windowTooLarge).
    if fi.window_size > d.max_window
        zerr("frame requires a window of $(fi.window_size) bytes, more than the limit of " *
             "$(d.max_window) bytes (raise it with the `max_window_size` keyword)")
    end
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
        next_frame_unit!(d)
    end
end

function decode_body!(d::StreamDecoder)
    bsize = d.want
    lim = min(BLOCK_SIZE_MAX, d.fi.window_size)     # Block_Maximum_Size
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
    d.produced += d.wpos - start
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
        bsize > min(BLOCK_SIZE_MAX, d.fi.window_size) && zerr("block larger than the maximum block size")
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
        next_frame_unit!(d)
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
        d.consumed += k
        d.skip_left == 0 && set_unit!(d, U_MAGIC, 4)
        return k
    end
    k = min(n, d.want - d.have)
    GC.@preserve d unsafe_copyto!(pointer(d.unit, d.have + 1), p, k)
    d.have += k
    d.consumed += k
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
    ZstdDecompressorStream(io::IO, dict::Union{Nothing, ZstdDictionary}=nothing;
                           max_window_size=128 MiB)

A streaming Zstandard decompressor that implements the `IO` interface.
Decoded data is produced one block at a time; memory use is bounded by the
frame's window size plus one block. Frames declaring a window larger than
`max_window_size` (default 128 MiB, as libzstd) are rejected with a
`ZstdError`, so untrusted input cannot make the decoder allocate more; raise
it to read frames written with a larger window (e.g. `zstd --long=30`).
With `magicless=true`, frames are read without their magic number, and
`prefix` decodes frames written with that reference prefix (see
[`compress`](@ref Zstandard.compress)).

After a decoding error (a `ZstdError`), the stream is unusable: later reads
rethrow the same error (bytes decoded before it can still be read). Other
exceptions, such as an interrupt or an error from `io`, are not sticky.
"""
mutable struct ZstdDecompressorStream <: IO
    io::IO
    d::StreamDecoder
    err::Union{Nothing,ZstdError}   # sticky decoding error
end

ZstdDecompressorStream(io::IO, dict::Union{Nothing,ZstdDictionary}=nothing;
                       max_window_size::Integer=DEFAULT_MAX_WINDOW_SIZE, magicless::Bool=false,
                       prefix::Union{Nothing,AbstractVector{UInt8}}=nothing) =
    ZstdDecompressorStream(io, StreamDecoder(prefix_dict(prefix, dict); max_window_size, magicless), nothing)

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
        got = feed_from!(d, s.io)
        got == 0 && zerr("truncated input")
        d.consumed += got
    end
    return true
end

"""
    stream_progress(s::ZstdDecompressorStream) -> (; consumed, produced, frames)
    stream_progress(s::ZstdCompressorStream) -> (; ingested, consumed, produced, flushed)

Progress of a streaming (de)compressor, as libzstd's `ZSTD_getFrameProgression`.
For a decompressor: compressed bytes read from the source, bytes decoded so far
(read or still buffered) and frames completed. For a compressor: bytes written
to the stream, bytes of those compressed so far, compressed bytes produced and
compressed bytes written to the underlying IO.
"""
stream_progress(s::ZstdDecompressorStream) =
    (; consumed=s.d.consumed, produced=s.d.produced, frames=s.d.frames_done)

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
    ZstdCompressorStream(io::IO; level=3, checksum=false, dict=nothing, pledged_size=nothing,
                         close_io=true, size_hint=nothing, content_size=true, dict_id=true,
                         magicless=false, long=false, nthreads=1, window_log, ...)

A streaming Zstandard compressor implementing the writable `IO` interface.
Data written to the stream is compressed into a single frame and written to
`io` block by block. `flush` emits all pending data as a complete block, so
everything written so far can be decoded.

Without `pledged_size` the frame header does not record the content size. With
`pledged_size = n`, it does (so decoders can preallocate, and
`frame_content_size` reports it), the compression parameters are sized to `n`
as in one-shot `compress`, and exactly `n` bytes must be written: writing more
throws an `ArgumentError`, and so does `close` after writing fewer.

Without a pledge, `size_hint = n` sizes the parameters for about `n` bytes
(libzstd's `ZSTD_c_srcSizeHint`) without recording a size or limiting the
input.

`window_log`, `hash_log`, `chain_log`, `search_log`, `min_match`,
`target_length` and `strategy` override the level's parameters,
`content_size`, `dict_id`, `magicless` and `target_block_size` set frame
options, and
`prefix` sets a reference prefix, as for `compress` (the window is sized for
the prefix plus the pledged size or size hint).
With `long=true`, long-distance matching finds repetitions up to 128 MiB
apart, as for `compress` (the stream then buffers up to 128 MiB of history,
less when a smaller `pledged_size` or `size_hint` is given). With
`nthreads > 1`, input is cut into jobs compressed in parallel tasks (as
libzstd's `nbWorkers`; jobs are four windows long, so the stream buffers
that much); output is written as jobs complete, in order, and `flush` and
`close` wait for them. `nthreads > 1` is not combined with `dict`, `prefix`
or `long`.

`close` finishes the frame and, if `close_io` is true, closes `io` (pass
`close_io=false` to keep writing to `io`, e.g. an `IOBuffer` read afterwards).
"""
mutable struct ZstdCompressorStream <: IO
    io::IO
    sc::StreamCompressor
    closed::Bool
    close_io::Bool
    flushed::Int         # compressed bytes written to io
end

function ZstdCompressorStream(io::IO; level::Union{Nothing,Integer}=nothing, checksum::Bool=false,
                              dict::Union{Nothing,ZstdDictionary,PreparedDictionary}=nothing,
                              pledged_size::Union{Nothing,Integer}=nothing, close_io::Bool=true,
                              size_hint::Union{Nothing,Integer}=nothing,
                              content_size::Bool=true, dict_id::Bool=true, magicless::Bool=false,
                              prefix::Union{Nothing,AbstractVector{UInt8}}=nothing,
                              target_block_size::Union{Nothing,Integer}=nothing,
                              long::Bool=false, nthreads::Integer=1,
                              window_log=nothing, hash_log=nothing, chain_log=nothing, search_log=nothing, min_match=nothing, target_length=nothing, strategy=nothing)
    params = parameter_overrides(; window_log, hash_log, chain_log, search_log, min_match, target_length, strategy)
    frame = FrameOptions(; content_size, dict_id, magicless, target_block_size)
    dict = prefix_dict(prefix, dict)
    expect = pledged_size !== nothing ? Int(pledged_size) : size_hint !== nothing ? Int(size_hint) :
             prefix === nothing ? 0 : length(prefix)
    params = prefix_params(params, prefix, level, expect)
    ZstdCompressorStream(io, StreamCompressor(; level, checksum, dict, pledged_size, params, frame, size_hint,
                                              long, nthreads), false, close_io, 0)
end

function drain!(s::ZstdCompressorStream)
    sc = s.sc
    if sc.olen > 0
        GC.@preserve sc unsafe_write(s.io, pointer(sc.out), sc.olen)
        s.flushed += sc.olen
        sc.olen = 0
    end
end

function stream_progress(s::ZstdCompressorStream)
    sc = s.sc
    return (; ingested=sc.total, consumed=sc.consumed, produced=s.flushed + sc.olen, flushed=s.flushed)
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
    # Close (or flush) the wrapped io even if finishing the frame throws (a
    # pledge mismatch, a failed job): the frame cannot be completed anyway.
    try
        stream_finish!(s.sc)
        drain!(s)
    finally
        s.closed = true
        s.close_io ? close(s.io) : flush(s.io)
    end
    return nothing
end

end # module
