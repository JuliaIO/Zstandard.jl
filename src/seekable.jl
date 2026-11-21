# Zstandard seekable format (libzstd contrib/seekable_format, version 0.1.0):
# independent frames followed by a skippable frame holding a seek table, so
# ranges of the content can be decoded without decoding everything before
# them. Included in module Zstandard.

const SEEKABLE_MAGIC = 0x8F92EAB1
const SEEK_TABLE_SKIPPABLE_MAGIC = 0x184D2A5E
const SEEKABLE_MAX_FRAME_SIZE = 0x40000000       # ZSTD_SEEKABLE_MAX_FRAME_DECOMPRESSED_SIZE
const SEEKABLE_MAX_FRAMES = 0x8000000            # ZSTD_SEEKABLE_MAXFRAMES

"""
    ZstandardSeekTable

The seek table of a seekable Zstandard archive (see [`compress_seekable`](@ref)):
for each frame its compressed and decompressed sizes, offsets, and (if
recorded) the low 32 bits of the XXH64 of its content. `length(table)` is the
number of frames; `table.content_size` the total decompressed size.
"""
struct ZstandardSeekTable
    csize::Vector{Int}
    dsize::Vector{Int}
    coff::Vector{Int}            # 0-based offset of frame i in the archive
    doff::Vector{Int}            # 0-based offset of frame i's content
    checksums::Union{Nothing,Vector{UInt32}}
    content_size::Int
    table_size::Int              # bytes of the seek-table frame
end
Base.length(t::ZstandardSeekTable) = length(t.csize)
Base.show(io::IO, t::ZstandardSeekTable) =
    print(io, "ZstandardSeekTable(", length(t), " frames, ", t.content_size, " bytes",
          t.checksums === nothing ? "" : ", checksums", ")")

function _seek_table(entries::Vector{NTuple{3,Int}}, checksum::Bool)
    n = length(entries)
    esz = checksum ? 12 : 8
    fsize = n * esz + 9
    out = Vector{UInt8}(undef, 8 + fsize)
    put32!(i, v) = for k in 0:3; out[i + k] = (UInt32(v) >> (8k)) % UInt8; end
    put32!(1, SEEK_TABLE_SKIPPABLE_MAGIC)
    put32!(5, fsize)
    pos = 9
    for (c, d, h) in entries
        put32!(pos, c); put32!(pos + 4, d)
        checksum && put32!(pos + 8, h)
        pos += esz
    end
    put32!(pos, n)
    out[pos + 4] = checksum ? 0x80 : 0x00
    put32!(pos + 5, SEEKABLE_MAGIC)
    return out
end

"""
    compress_seekable(data; frame_size=1 MiB, checksum=true, nthreads=1, level=3, ...) -> Vector{UInt8}

Compress `data` into the Zstandard seekable format (as libzstd's
`contrib/seekable_format`): independent frames of `frame_size` bytes of content
each (at most 1 GiB), followed by a seek table in a skippable frame. Any
Zstandard decoder decodes the whole archive; [`decompress_range`](@ref) decodes
just a range, touching only the frames it overlaps. With `checksum=true` the
seek table records an XXH64-based checksum of each frame's content, verified
on decoding. Frames are compressed in parallel on up to `nthreads` tasks.
Other keywords (`level`, `dict`, `window_log`, ...) are passed to
[`compress`](@ref) for each frame, except `prefix` and `magicless=true`,
which [`decompress_range`](@ref) could not read back.
"""
function compress_seekable(data::Union{AbstractVector{UInt8},AbstractString}; frame_size::Integer=1 << 20,
                           checksum::Bool=true, nthreads::Integer=1, kwargs...)
    src = _bytes(data)
    1 <= frame_size <= SEEKABLE_MAX_FRAME_SIZE ||
        throw(ArgumentError("frame_size must be in 1:$(SEEKABLE_MAX_FRAME_SIZE)"))
    nthreads < 1 && throw(ArgumentError("nthreads must be at least 1"))
    get(kwargs, :magicless, false) && throw(ArgumentError("seekable archives cannot use magicless frames"))
    # decompress_range takes a dictionary but no prefix: the archive would be unreadable
    get(kwargs, :prefix, nothing) === nothing ||
        throw(ArgumentError("seekable archives cannot use a prefix; use dict"))
    n = length(src)
    nf = cld(n, Int(frame_size))
    nf > SEEKABLE_MAX_FRAMES && throw(ArgumentError("too many frames; use a larger frame_size"))
    ranges = [((k - 1) * frame_size + 1):min(k * frame_size, n) for k in 1:nf]
    one(r) = compress(view(src, r); kwargs...)
    frames = if nthreads > 1 && nf > 1
        sem = Base.Semaphore(Int(nthreads))
        fetch.([Threads.@spawn Base.acquire(() -> one(r), sem) for r in ranges])
    else
        map(one, ranges)
    end
    entries = NTuple{3,Int}[]
    for (r, f) in zip(ranges, frames)
        length(f) > typemax(UInt32) && throw(ArgumentError("a compressed frame exceeds 4 GiB"))
        push!(entries, (length(f), length(r), checksum ? Int(content_checksum(view(src, r))) : 0))
    end
    table = _seek_table(entries, checksum)
    out = Vector{UInt8}(undef, sum(length, frames; init=0) + length(table))
    pos = 1
    for f in frames
        copyto!(out, pos, f, 1, length(f)); pos += length(f)
    end
    copyto!(out, pos, table, 1, length(table))
    return out
end

_le32(b, i) = UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24

# Parse a seek table from its footer (the last 9 bytes) and a reader of the
# bytes before it: read(offset, n) returns the n bytes at 0-based offset.
function _parse_seek_table(total::Int, read_at)
    total < 17 && zerr("not a seekable archive (too short)")
    foot = read_at(total - 9, 9)
    _le32(foot, 6) == SEEKABLE_MAGIC || zerr("not a seekable archive (no seek table footer)")
    nf = Int(_le32(foot, 1))
    desc = foot[5]
    desc & 0x7c == 0 || zerr("seek table: reserved descriptor bits set")
    checksum = desc & 0x80 != 0
    esz = checksum ? 12 : 8
    tsize = 8 + nf * esz + 9
    tsize > total && zerr("seek table larger than the archive")
    tab = read_at(total - tsize, tsize)
    _le32(tab, 1) == SEEK_TABLE_SKIPPABLE_MAGIC || zerr("seek table: bad skippable frame magic")
    Int(_le32(tab, 5)) == tsize - 8 || zerr("seek table: frame size mismatch")
    csize = Vector{Int}(undef, nf); dsize = Vector{Int}(undef, nf)
    coff = Vector{Int}(undef, nf); doff = Vector{Int}(undef, nf)
    sums = checksum ? Vector{UInt32}(undef, nf) : nothing
    c = 0; d = 0
    for i in 1:nf
        p = 9 + (i - 1) * esz
        csize[i] = Int(_le32(tab, p)); dsize[i] = Int(_le32(tab, p + 4))
        # the writer's limit, also enforced on reading: sizes are untrusted
        dsize[i] > SEEKABLE_MAX_FRAME_SIZE && zerr("seek table: frame $i claims $(dsize[i]) bytes, " *
                                                   "more than the maximum frame size")
        checksum && (sums[i] = _le32(tab, p + 8))
        coff[i] = c; doff[i] = d
        c += csize[i]; d += dsize[i]
    end
    c + tsize > total && zerr("seek table: frames extend past the archive")
    return ZstandardSeekTable(csize, dsize, coff, doff, sums, d, tsize)
end

"""
    seek_table(archive::AbstractVector{UInt8}) -> ZstandardSeekTable
    seek_table(io::IO) -> ZstandardSeekTable

Read the seek table at the end of a seekable archive (a vector, or a seekable
`IO` such as a file). Throws a `ZstandardError` if there is none.
"""
seek_table(data::AbstractVector{UInt8}) =
    _parse_seek_table(length(data), (off, n) -> Vector{UInt8}(view(data, firstindex(data) + off:firstindex(data) + off + n - 1)))

function seek_table(io::IO)
    start = position(io)
    seekend(io); total = position(io)
    try
        return _parse_seek_table(total, (off, n) -> (seek(io, off); read(io, n)))
    finally
        seek(io, start)
    end
end

function _seekable_frame(raw::Vector{UInt8}, t::ZstandardSeekTable, i::Int, dict, st)
    out = decompress_frames(raw, st, dict)
    length(out) == t.dsize[i] || zerr("seekable frame $i: decoded $(length(out)) bytes, seek table says $(t.dsize[i])")
    if t.checksums !== nothing && content_checksum(out) != t.checksums[i]
        zerr("seekable frame $i: checksum mismatch")
    end
    return out
end

"""
    decompress_range(archive, range::UnitRange; table=seek_table(archive), dict=nothing) -> Vector{UInt8}

Decode bytes `range` (1-based) of the content of a seekable archive (a vector,
or a seekable `IO` such as a file, from which only the needed frames are
read). Only frames overlapping `range` are decoded. `dict` may be a
`ZstandardDictionary` or several (see [`ZstandardDictionarySet`](@ref)).
"""
function decompress_range(src::Union{AbstractVector{UInt8},IO}, range::AbstractUnitRange{<:Integer};
                          table::ZstandardSeekTable=seek_table(src),
                          dict::DictArg=nothing)
    t = table
    dict = decode_dict(dict)
    isempty(range) && return UInt8[]
    (first(range) >= 1 && last(range) <= t.content_size) ||
        throw(BoundsError(1:t.content_size, range))
    lo = first(range) - 1; hi = last(range)           # 0-based [lo, hi)
    i = searchsortedlast(t.doff, lo)
    while i > 1 && t.dsize[i] == 0 && t.doff[i] == lo; i -= 1; end
    # grown per decoded frame, not allocated from the (untrusted) seek table
    out = UInt8[]
    pos = 1
    _with_state() do st
        while pos <= hi - lo
            if t.dsize[i] > 0
                raw = src isa IO ? (seek(src, t.coff[i]); read(src, t.csize[i])) :
                      Vector{UInt8}(view(src, firstindex(src) + t.coff[i]:firstindex(src) + t.coff[i] + t.csize[i] - 1))
                length(raw) == t.csize[i] || zerr("truncated seekable archive")
                content = _seekable_frame(raw, t, i, dict, st)
                a = max(lo, t.doff[i]) - t.doff[i] + 1
                b = min(hi, t.doff[i] + t.dsize[i]) - t.doff[i]
                append!(out, view(content, a:b))
                pos += b - a + 1
            end
            i += 1
        end
    end
    return out
end
