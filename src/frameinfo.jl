# Frame inspection helpers (counterparts of ZSTD_getFrameContentSize,
# ZSTD_findFrameCompressedSize, ZSTD_findDecompressedSize, ZSTD_getDictID_fromFrame,
# ZSTD_isFrame, ZSTD_isSkippableFrame, ZSTD_writeSkippableFrame, ZSTD_readSkippableFrame).
# Included in module Zstandard.

using .Decoder: read_frame_info, zerr, SKIPPABLE_MASK

"""
    ZstdFrameHeader

Information from a Zstandard frame header, as returned by [`frame_header`](@ref).

- `content_size`: decompressed size, or `nothing` if the header does not record it
- `window_size`: window size required to decode the frame
- `dict_id`: dictionary ID, `0` if none
- `checksum`: whether the frame ends with an XXH64 content checksum
- `single_segment`: whether the frame is a single segment (window = content size)
- `header_size`: size of the frame header in bytes, including the magic number
"""
struct ZstdFrameHeader
    content_size::Union{Nothing,Int64}
    window_size::Int
    dict_id::UInt32
    checksum::Bool
    single_segment::Bool
    header_size::Int
end

@inline _u32le(d::AbstractVector{UInt8}, i::Int) =
    UInt32(d[i]) | (UInt32(d[i+1]) << 8) | (UInt32(d[i+2]) << 16) | (UInt32(d[i+3]) << 24)

# bytes from `offset` on; negative for an offset before the start
_remaining(d, offset) = offset < 1 ? -1 : length(d) - offset + 1
_check_offset(offset) = offset >= 1 || throw(ArgumentError("offset must be at least 1, got $offset"))

# Sizes from untrusted headers are summed with overflow checks: a negative or
# wrapped total would be a hazard for callers that allocate from it.
_add_size(a::Int64, b::Integer) = Base.Checked.add_with_overflow(a, Int64(b))[2] ?
    zerr("total decompressed size overflows Int64 (corrupted or forged headers)") : a + Int64(b)

"""
    is_zstd_frame(data; offset=1) -> Bool

Whether a Zstandard or skippable frame starts at `offset` (checks the magic number).
"""
function is_zstd_frame(data::AbstractVector{UInt8}; offset::Integer=1)
    _remaining(data, offset) < 4 && return false
    m = _u32le(data, offset)
    return m == MAGIC_NUMBER || m & SKIPPABLE_MASK == SKIPPABLE_MAGIC_START
end

"""
    is_skippable_frame(data; offset=1) -> Bool

Whether a skippable frame starts at `offset`.
"""
function is_skippable_frame(data::AbstractVector{UInt8}; offset::Integer=1)
    _remaining(data, offset) < 4 && return false
    return _u32le(data, offset) & SKIPPABLE_MASK == SKIPPABLE_MAGIC_START
end

"""
    frame_header(data; offset=1) -> ZstdFrameHeader

Parse the header of the Zstandard frame starting at `offset`. Throws a
`ZstdError` for skippable frames, unknown magic numbers or truncated headers.
"""
function frame_header(data::AbstractVector{UInt8}; offset::Integer=1)
    _check_offset(offset)
    _remaining(data, offset) < 5 && zerr("truncated frame header")
    m = _u32le(data, offset)
    m & SKIPPABLE_MASK == SKIPPABLE_MAGIC_START && zerr("skippable frame has no frame header")
    m != MAGIC_NUMBER && zerr("unknown frame magic number 0x$(string(m, base=16))")
    hdr = Vector{UInt8}(data[offset+4:min(end, offset + 4 + 17)])
    fi = GC.@preserve hdr read_frame_info(pointer(hdr), length(hdr))
    cs = fi.content_size >= 0 ? fi.content_size : nothing
    return ZstdFrameHeader(cs, fi.window_size, fi.dict_id, fi.checksum, fi.single_segment, 4 + fi.header_size)
end

"""
    frame_content_size(data; offset=1) -> Union{Int64, Nothing}

Decompressed size recorded in the header of the frame at `offset`, or
`nothing` if the frame does not record it. Skippable frames have size 0.
"""
function frame_content_size(data::AbstractVector{UInt8}; offset::Integer=1)
    is_skippable_frame(data; offset) && return Int64(0)
    return frame_header(data; offset).content_size
end

"""
    frame_dict_id(data; offset=1) -> UInt32

Dictionary ID required by the frame at `offset` (`0` if none).
"""
frame_dict_id(data::AbstractVector{UInt8}; offset::Integer=1) =
    is_skippable_frame(data; offset) ? UInt32(0) : frame_header(data; offset).dict_id

"""
    frame_compressed_size(data; offset=1) -> Int

Total size in bytes of the (Zstandard or skippable) frame starting at
`offset`, found by walking its block headers.
"""
function frame_compressed_size(data::AbstractVector{UInt8}; offset::Integer=1)
    _check_offset(offset)
    if is_skippable_frame(data; offset)
        _remaining(data, offset) < 8 && zerr("truncated skippable frame")
        n = 8 + Int(_u32le(data, offset + 4))
        n > _remaining(data, offset) && zerr("truncated skippable frame")
        return n
    end
    fh = frame_header(data; offset)
    pos = offset + fh.header_size
    while true
        length(data) - pos + 1 < 3 && zerr("truncated block header")
        bh = Int(data[pos]) | (Int(data[pos+1]) << 8) | (Int(data[pos+2]) << 16)
        btype = (bh >> 1) & 3
        btype == 3 && zerr("reserved block type")
        bsize = btype == 1 ? 1 : bh >> 3
        pos += 3 + bsize
        pos - 1 > length(data) && zerr("truncated block")
        bh & 1 == 1 && break
    end
    pos += fh.checksum ? 4 : 0
    pos - 1 > length(data) && zerr("truncated frame checksum")
    return pos - offset
end

"""
    decompressed_size(data) -> Union{Int64, Nothing}

Sum of the content sizes of all frames in `data` (skippable frames count as 0),
or `nothing` if any frame does not record its content size. Throws a
`ZstdError` if the sizes (taken from untrusted headers) overflow `Int64`.
"""
function decompressed_size(data::AbstractVector{UInt8})
    total = Int64(0)
    pos = 1
    while pos <= length(data)
        cs = frame_content_size(data; offset=pos)
        cs === nothing && return nothing
        total = _add_size(total, cs)
        pos += frame_compressed_size(data; offset=pos)
    end
    return total
end

"""
    skippable_frame(content; variant=0) -> Vector{UInt8}

Build a skippable frame carrying `content` (user data ignored by decoders).
`variant` (0-15) selects the magic number `0x184D2A50 + variant`.
"""
function skippable_frame(content::AbstractVector{UInt8}; variant::Integer=0)
    0 <= variant <= 15 || throw(ArgumentError("variant must be in 0:15"))
    length(content) > typemax(UInt32) && throw(ArgumentError("content too large for a skippable frame"))
    out = Vector{UInt8}(undef, 8 + length(content))
    m = SKIPPABLE_MAGIC_START + UInt32(variant)
    n = UInt32(length(content))
    for k in 0:3
        out[1 + k] = (m >> (8k)) % UInt8
        out[5 + k] = (n >> (8k)) % UInt8
    end
    copyto!(out, 9, content, firstindex(content), length(content))
    return out
end
skippable_frame(content::AbstractString; kwargs...) = skippable_frame(codeunits(content); kwargs...)

"""
    read_skippable_frame(data; offset=1) -> (variant, content)

Read the skippable frame at `offset`, returning its magic-number variant and a
copy of its content.
"""
function read_skippable_frame(data::AbstractVector{UInt8}; offset::Integer=1)
    is_skippable_frame(data; offset) || zerr("not a skippable frame")
    n = frame_compressed_size(data; offset)
    variant = Int(_u32le(data, offset) - SKIPPABLE_MAGIC_START)
    return variant, Vector{UInt8}(data[offset+8:offset+n-1])
end
