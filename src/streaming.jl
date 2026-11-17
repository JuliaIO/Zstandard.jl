# Streaming decompressor for Zstandard

module Streaming

import ..Decoder: DecoderState, ZstdDictionary, FrameInfo, read_frame_info, reset_frame!,
                  decode_compressed_block!, memset!, zerr, ensure_capacity!,
                  MAGIC_NUMBER, SKIPPABLE_MAGIC_START, SKIPPABLE_MASK, BLOCK_SIZE_MAX, WILDCOPY_SLACK
using XXHashNative: XXH64State, update!, digest!

export ZstdDecompressorStream

const STAGE_FRAME = 0   # expecting a frame (or end of input)
const STAGE_BLOCK = 1   # inside a frame, expecting a block header

"""
    ZstdDecompressorStream(io::IO, dict::Union{Nothing, ZstdDictionary}=nothing)

A streaming Zstandard decompressor that implements the `IO` interface.
Decoded data is produced one block at a time; memory use is bounded by the
frame's window size plus one block.
"""
mutable struct ZstdDecompressorStream <: IO
    io::IO
    dict::Union{Nothing,ZstdDictionary}
    st::DecoderState
    inbuf::Vector{UInt8}
    out::Vector{UInt8}
    rpos::Int            # next unread byte in `out` (1-based)
    wpos::Int            # number of valid bytes in `out`
    frame_start::Int     # 0-based offset of the current frame's first byte in `out` (may be < 0)
    stage::Int
    fi::FrameInfo
    frame_produced::Int
    xxh::Union{Nothing,XXH64State}
end

function ZstdDecompressorStream(io::IO, dict::Union{Nothing,ZstdDictionary}=nothing)
    return ZstdDecompressorStream(io, dict, DecoderState(), Vector{UInt8}(undef, 64),
        UInt8[], 1, 0, 0, STAGE_FRAME, FrameInfo(0, 0, -1, 0, false, false), 0, nothing)
end

function read_exact!(s::ZstdDecompressorStream, n::Int, what::String)
    length(s.inbuf) < n && resize!(s.inbuf, n)
    got = readbytes!(s.io, s.inbuf, n)
    got < n && zerr("truncated input ($what)")
    return s.inbuf
end

read_u32!(s, what) = (b = read_exact!(s, 4, what);
    UInt32(b[1]) | (UInt32(b[2]) << 8) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 24))

# Discard bytes that are already read and no longer needed as match history.
function compact!(s::ZstdDecompressorStream)
    hist_from = max(s.frame_start, s.wpos - s.fi.window_size)
    drop = min(s.rpos - 1, hist_from)
    if drop > 0
        copyto!(s.out, 1, s.out, drop + 1, s.wpos - drop)
        s.rpos -= drop
        s.wpos -= drop
        s.frame_start -= drop
    end
    return s
end

function make_room!(s::ZstdDecompressorStream, n::Int)
    need = s.wpos + n + WILDCOPY_SLACK
    if length(s.out) < need
        compact!(s)
        need = s.wpos + n + WILDCOPY_SLACK
        ensure_capacity!(s.out, need)
    end
end

function begin_frame!(s::ZstdDecompressorStream)
    while true
        eof(s.io) && return false
        magic = read_u32!(s, "magic number")
        if magic & SKIPPABLE_MASK == SKIPPABLE_MAGIC_START
            sz = Int(read_u32!(s, "skippable frame size"))
            while sz > 0
                k = min(sz, 1 << 16)
                read_exact!(s, k, "skippable frame")
                sz -= k
            end
            continue
        end
        magic != MAGIC_NUMBER && zerr("unknown frame magic number 0x$(string(magic, base=16))")
        fd = read_exact!(s, 1, "frame header")[1]
        single = (fd >> 5) & 1 == 1
        hs = 1 + (single ? 0 : 1) + (0, 1, 2, 4)[(fd & 3) + 1] + (single ? 1 : 0, 2, 4, 8)[(fd >> 6) + 1]
        hdr = Vector{UInt8}(undef, hs)
        hdr[1] = fd
        hs > 1 && (hdr[2:hs] = read_exact!(s, hs - 1, "frame header")[1:hs-1])
        fi = GC.@preserve hdr read_frame_info(pointer(hdr), hs)
        d = s.dict
        if fi.dict_id != 0
            d === nothing && zerr("frame requires dictionary ID $(fi.dict_id)")
            (d.id != 0 && d.id != fi.dict_id) &&
                zerr("dictionary ID mismatch: frame requires $(fi.dict_id), got $(d.id)")
        end
        reset_frame!(s.st, d)
        s.fi = fi
        # Previous frames are never referenced: drop everything already read.
        if s.rpos > 1
            copyto!(s.out, 1, s.out, s.rpos, s.wpos - s.rpos + 1)
            s.wpos -= s.rpos - 1
            s.rpos = 1
        end
        s.frame_start = s.wpos
        s.frame_produced = 0
        s.xxh = fi.checksum ? XXH64State() : nothing
        s.stage = STAGE_BLOCK
        return true
    end
end

function end_frame!(s::ZstdDecompressorStream)
    fi = s.fi
    if fi.content_size >= 0 && s.frame_produced != fi.content_size
        zerr("frame content size mismatch: header says $(fi.content_size), decoded $(s.frame_produced)")
    end
    if fi.checksum
        expected = read_u32!(s, "frame checksum")
        actual = digest!(s.xxh) % UInt32
        actual != expected && zerr("checksum mismatch")
    end
    s.stage = STAGE_FRAME
end

function decode_block!(s::ZstdDecompressorStream)
    b = read_exact!(s, 3, "block header")
    bh = Int(b[1]) | (Int(b[2]) << 8) | (Int(b[3]) << 16)
    last = bh & 1 == 1
    btype = (bh >> 1) & 3
    bsize = bh >> 3
    btype == 3 && zerr("reserved block type")
    bsize > BLOCK_SIZE_MAX && zerr("block too large")
    start = s.wpos
    if btype == 0
        make_room!(s, bsize)
        got = readbytes!(s.io, view(s.out, s.wpos+1:s.wpos+bsize), bsize)
        got < bsize && zerr("truncated input (raw block)")
        s.wpos += bsize
    elseif btype == 1
        v = read_exact!(s, 1, "RLE block")[1]
        make_room!(s, bsize)
        GC.@preserve s memset!(pointer(s.out) + s.wpos, v, bsize)
        s.wpos += bsize
    else
        inp = read_exact!(s, bsize, "compressed block")
        lim = BLOCK_SIZE_MAX
        if s.fi.content_size >= 0
            lim = min(lim, Int(s.fi.content_size) - s.frame_produced)
            lim < 0 && zerr("frame content size exceeded")
        end
        make_room!(s, lim)
        out = s.out
        hist = max(s.frame_start, 0)
        d = s.frame_start >= 0 ? s.dict : nothing
        GC.@preserve out inp begin
            base = pointer(out)
            op = decode_compressed_block!(s.st, pointer(inp), bsize, base + s.wpos,
                                          base + hist, base + s.wpos + lim, d)
            s.wpos = Int(op - base)
        end
    end
    s.frame_produced += s.wpos - start
    if s.xxh !== nothing && s.wpos > start
        update!(s.xxh, view(s.out, start+1:s.wpos))
    end
    last && end_frame!(s)
    return nothing
end

# Decode until at least one unread byte is available. Returns false at end of input.
function fill_buffer!(s::ZstdDecompressorStream)
    while s.rpos > s.wpos
        if s.stage == STAGE_FRAME
            begin_frame!(s) || return false
        else
            decode_block!(s)
        end
    end
    return true
end

Base.bytesavailable(s::ZstdDecompressorStream) = s.wpos - s.rpos + 1
Base.eof(s::ZstdDecompressorStream) = s.rpos > s.wpos && !fill_buffer!(s)
Base.isopen(s::ZstdDecompressorStream) = isopen(s.io)
Base.close(s::ZstdDecompressorStream) = close(s.io)

function Base.read(s::ZstdDecompressorStream, ::Type{UInt8})
    eof(s) && throw(EOFError())
    v = @inbounds s.out[s.rpos]
    s.rpos += 1
    return v
end

function Base.unsafe_read(s::ZstdDecompressorStream, p::Ptr{UInt8}, n::UInt)
    n = Int(n)
    while n > 0
        eof(s) && throw(EOFError())
        k = min(n, s.wpos - s.rpos + 1)
        GC.@preserve s unsafe_copyto!(p, pointer(s.out, s.rpos), k)
        s.rpos += k
        p += k
        n -= k
    end
    return nothing
end

function Base.readbytes!(s::ZstdDecompressorStream, b::AbstractVector{UInt8}, nb=length(b))
    got = 0
    while got < nb && !eof(s)
        k = min(nb - got, s.wpos - s.rpos + 1)
        if got + k > length(b)
            resize!(b, got + k)
        end
        copyto!(b, got + 1, s.out, s.rpos, k)
        s.rpos += k
        got += k
    end
    return got
end

function Base.read(s::ZstdDecompressorStream)
    out = UInt8[]
    while !eof(s)
        k = s.wpos - s.rpos + 1
        append!(out, view(s.out, s.rpos:s.wpos))
        s.rpos += k
    end
    return out
end

Base.read(s::ZstdDecompressorStream, nb::Integer) = (b = Vector{UInt8}(undef, nb); resize!(b, readbytes!(s, b, nb)))

end # module
