# High-performance Zstandard decoder (RFC 8878).
#
# Design (follows the reference implementation):
#   * Frames are parsed straight from a byte vector; blocks are decoded into one
#     contiguous output buffer that also serves as the match history.
#   * Backward bitstreams use a 64-bit container with unaligned 8-byte reloads.
#     The reader is an immutable struct so it lives in registers in hot loops.
#   * FSE decoding tables are packed UInt64 entries (one load per state).
#   * Huffman literals use a flat single-symbol table; 4 streams are decoded
#     in lockstep for instruction-level parallelism.
#   * Sequence decoding and execution are fused. Literal and match copies use
#     "wildcopy" (copying in 16-byte chunks), which may write up to
#     WILDCOPY_SLACK bytes past the logical end, so buffers carry slack.

module Decoder

using ..XXHash: content_checksum

export ZstdError, ZstdDictionary, parse_dictionary, DecoderState, decompress_frames,
       FrameInfo, read_frame_info

const MAGIC_NUMBER = 0xFD2FB528
const SKIPPABLE_MAGIC_START = 0x184D2A50
const SKIPPABLE_MASK = 0xFFFFFFF0
const BLOCK_SIZE_MAX = 1 << 17
const WILDCOPY_SLACK = 32
const HUF_TABLELOG_MAX = 11
const LL_MAX_AL = 9
const ML_MAX_AL = 9
const OF_MAX_AL = 8

"""
    ZstdError(msg)

Exception thrown when Zstandard data is malformed or cannot be decoded.
"""
struct ZstdError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ZstdError) = print(io, "ZstdError: ", e.msg)
@noinline zerr(msg::String) = throw(ZstdError(msg))

# ---------------------------------------------------------------------------
# Unaligned little-endian memory helpers
# ---------------------------------------------------------------------------

@inline load64(p::Ptr{UInt8}) = ltoh(unsafe_load(Ptr{UInt64}(p)))
@inline load32(p::Ptr{UInt8}) = ltoh(unsafe_load(Ptr{UInt32}(p)))
@inline load8(p::Ptr{UInt8}, i::Int) = unsafe_load(p, i)  # 1-based

@inline function copy8(dst::Ptr{UInt8}, src::Ptr{UInt8})
    unsafe_store!(Ptr{UInt64}(dst), unsafe_load(Ptr{UInt64}(src)))
end
@inline function copy16(dst::Ptr{UInt8}, src::Ptr{UInt8})
    a = unsafe_load(Ptr{UInt64}(src))
    b = unsafe_load(Ptr{UInt64}(src + 8))
    unsafe_store!(Ptr{UInt64}(dst), a)
    unsafe_store!(Ptr{UInt64}(dst + 8), b)
end

"""Copy `n` bytes in 16-byte chunks. Requires `dst - src >= 16` or no overlap; may overwrite up to 15 bytes past `dst + n`."""
@inline function wildcopy16(dst::Ptr{UInt8}, src::Ptr{UInt8}, n::Int)
    i = 0
    while true
        copy16(dst + i, src + i)
        i += 16
        i >= n && break
    end
end

"""Copy `n` bytes in 8-byte chunks. Requires `dst - src >= 8`; may overwrite up to 7 bytes past `dst + n`."""
@inline function wildcopy8(dst::Ptr{UInt8}, src::Ptr{UInt8}, n::Int)
    i = 0
    while true
        copy8(dst + i, src + i)
        i += 8
        i >= n && break
    end
end

@inline function memset!(p::Ptr{UInt8}, v::UInt8, n::Int)
    ccall(:memset, Ptr{Cvoid}, (Ptr{UInt8}, Cint, Csize_t), p, v, n)
    return nothing
end

"""
Copy a match of length `ml` at distance `offset` to `op` from earlier output.
May write up to WILDCOPY_SLACK bytes beyond `op + ml`.
"""
@inline function match_copy!(op::Ptr{UInt8}, offset::Int, ml::Int)
    src = op - offset
    if offset >= 16
        if ml <= 32 || offset < ml
            wildcopy16(op, src, ml)
        else
            unsafe_copyto!(op, src, ml)
        end
    elseif offset == 1
        memset!(op, unsafe_load(src), ml)
    else
        # Short period: the output is periodic with period `offset`, hence also
        # with any multiple of it. Extend the pattern byte-wise up to a period
        # >= 8, then copy in 8-byte chunks.
        period = offset
        while period < 8
            period += offset
        end
        n = min(ml, period)
        for i in 0:n-1
            unsafe_store!(op + i, unsafe_load(src + i))
        end
        if ml > n
            wildcopy8(op + n, op + n - period, ml - n)
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Backward bit reader (libzstd BIT_DStream semantics)
# ---------------------------------------------------------------------------

struct BitD
    bits::UInt64
    consumed::Int
    ptr::Ptr{UInt8}    # start of the 8-byte window currently loaded
    start::Ptr{UInt8}  # first byte of the bitstream
end

@inline function bitd_init(start::Ptr{UInt8}, len::Int)
    len < 1 && zerr("empty bitstream")
    last = unsafe_load(start, len)
    last == 0x00 && zerr("bitstream end mark missing")
    if len >= 8
        ptr = start + len - 8
        bits = load64(ptr)
        consumed = leading_zeros(last) + 1
    else
        ptr = start
        bits = UInt64(0)
        for i in 0:len-1
            bits |= UInt64(unsafe_load(start, i + 1)) << (8 * i)
        end
        consumed = leading_zeros(last) + 1 + (8 - len) * 8
    end
    return BitD(bits, consumed, ptr, start)
end

# Read n bits (0 <= n <= 63) without consuming them.
@inline bitd_peek(b::BitD, n::Int) =
    ((b.bits << (b.consumed & 63)) >>> 1) >>> ((63 - n) & 63)
# Read n bits (1 <= n <= 64) without consuming; slightly cheaper.
@inline bitd_peek_nz(b::BitD, n::Int) =
    (b.bits << (b.consumed & 63)) >>> ((64 - n) & 63)
@inline bitd_skip(b::BitD, n::Int) = BitD(b.bits, b.consumed + n, b.ptr, b.start)
@inline function bitd_read(b::BitD, n::Int)
    return Int(bitd_peek(b, n)), bitd_skip(b, n)
end

@inline function bitd_reload(b::BitD)
    c = b.consumed
    c > 64 && return b                       # overflow: detected by caller
    if b.ptr >= b.start + 8
        ptr = b.ptr - (c >> 3)
        return BitD(load64(ptr), c & 7, ptr, b.start)
    end
    b.ptr == b.start && return b             # everything already loaded
    nb = c >> 3
    if b.ptr - nb < b.start
        nb = Int(b.ptr - b.start)
    end
    ptr = b.ptr - nb
    return BitD(load64(ptr), c - 8 * nb, ptr, b.start)
end

@inline bitd_finished(b::BitD) = b.ptr == b.start && b.consumed == 64
@inline bitd_overflow(b::BitD) = b.consumed > 64

# ---------------------------------------------------------------------------
# FSE tables
# ---------------------------------------------------------------------------
# Packed entry layout (as libzstd's ZSTD_seqSymbol):
#   bits  0..15  next state base
#   bits 16..23  number of state bits to read
#   bits 24..31  number of extra value bits
#   bits 32..63  base value

@inline fse_entry(newstate::Integer, nbbits::Integer, nbadd::Integer, base::Integer) =
    UInt64(newstate) | (UInt64(nbbits) << 16) | (UInt64(nbadd) << 24) | (UInt64(base) << 32)
@inline fse_newstate(e::UInt64) = Int(e & 0xffff)
@inline fse_nbbits(e::UInt64) = Int((e >> 16) & 0xff)
@inline fse_nbadd(e::UInt64) = Int((e >> 24) & 0xff)
@inline fse_base(e::UInt64) = Int(e >> 32)

const LL_BASE = UInt32[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
    8192, 16384, 32768, 65536]
const LL_BITS = UInt8[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
const ML_BASE = UInt32[3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
    19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
    35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
    4099, 8195, 16387, 32771, 65539]
const ML_BITS = UInt8[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
    12, 13, 14, 15, 16]
const OF_BASE = UInt32[UInt32(1) << i for i in 0:31]
const OF_BITS = UInt8[i for i in 0:31]
const ID_BASE = UInt32[i for i in 0:255]
const ID_BITS = zeros(UInt8, 256)

const LL_DEFAULT_NORM = Int16[4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1]
const ML_DEFAULT_NORM = Int16[1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1]
const OF_DEFAULT_NORM = Int16[1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]

"""
Build a packed FSE decoding table into `table` (resized to 2^al) from
normalized counts `norm[1:nsym]`. `vbase`/`vbits` map symbols to value
base/extra-bit counts.
"""
function build_fse_table!(table::Vector{UInt64}, norm::AbstractVector{Int16}, nsym::Int, al::Int,
                          vbase::Vector{UInt32}, vbits::Vector{UInt8},
                          symnext::Vector{UInt16}, tabsym::Vector{UInt8})
    tsize = 1 << al
    length(table) == tsize || resize!(table, tsize)
    length(tabsym) >= tsize || resize!(tabsym, tsize)
    nsym > length(vbase) && zerr("FSE table has too many symbols")
    high = tsize - 1
    @inbounds for s in 1:nsym
        p = norm[s]
        if p == -1
            tabsym[high + 1] = UInt8(s - 1)
            high -= 1
            symnext[s] = 1
        else
            symnext[s] = UInt16(max(p, 0))
        end
    end
    step = (tsize >> 1) + (tsize >> 3) + 3
    mask = tsize - 1
    pos = 0
    @inbounds for s in 1:nsym
        p = Int(norm[s])
        for _ in 1:p
            tabsym[pos + 1] = UInt8(s - 1)
            pos = (pos + step) & mask
            while pos > high
                pos = (pos + step) & mask
            end
        end
    end
    pos != 0 && zerr("FSE table spread failed (invalid normalized counts)")
    @inbounds for u in 1:tsize
        s = Int(tabsym[u]) + 1
        nxt = Int(symnext[s])
        symnext[s] += 1
        nb = al - (63 - leading_zeros(UInt64(nxt)))
        newstate = (nxt << nb) - tsize
        table[u] = fse_entry(newstate, nb, vbits[s], vbase[s])
    end
    return table
end

"""
Read an FSE normalized-count header from `p[1:len]` into `norm`.
Returns `(nsym, accuracy_log, bytes_consumed)`.
"""
function read_fse_header!(norm::Vector{Int16}, p::Ptr{UInt8}, len::Int, max_sym::Int, max_al::Int)
    len < 1 && zerr("truncated FSE table header")
    bitpos = 0
    @inline function getbits(bitpos, n)
        i = bitpos >> 3
        v = UInt32(0)
        for k in 0:3
            if i + k < len
                v |= UInt32(unsafe_load(p, i + k + 1)) << (8 * k)
            end
        end
        return Int((v >> (bitpos & 7)) & ((UInt32(1) << n) - UInt32(1)))
    end
    al = getbits(bitpos, 4) + 5
    bitpos += 4
    al > max_al && zerr("FSE accuracy log too large")
    remaining = 1 << al
    sym = 0
    while remaining > 0
        sym >= max_sym && zerr("FSE table has too many symbols")
        max_value = remaining + 1
        nbits = 64 - leading_zeros(UInt64(max_value))
        lower = nbits - 1
        threshold = (1 << nbits) - max_value - 1
        v = getbits(bitpos, lower)
        if v < threshold
            bitpos += lower
        else
            v = getbits(bitpos, nbits)
            if v >= (1 << lower)
                v -= threshold
            end
            bitpos += nbits
        end
        prob = v - 1
        sym += 1
        norm[sym] = Int16(prob)
        remaining -= prob == -1 ? 1 : prob
        if prob == 0
            while true
                flag = getbits(bitpos, 2)
                bitpos += 2
                for _ in 1:flag
                    sym >= max_sym && zerr("FSE table has too many symbols")
                    sym += 1
                    norm[sym] = 0
                end
                flag == 3 || break
            end
        end
        (bitpos >> 3) > len && zerr("truncated FSE table header")
    end
    remaining != 0 && zerr("FSE probabilities do not sum to table size")
    nbytes = (bitpos + 7) >> 3
    nbytes > len && zerr("truncated FSE table header")
    return sym, al, nbytes
end

function build_default_table(norm, al, vbase, vbits)
    t = UInt64[]
    build_fse_table!(t, norm, length(norm), al, vbase, vbits, zeros(UInt16, 256), zeros(UInt8, 512))
    return t
end

const LL_DEFAULT_TABLE = build_default_table(LL_DEFAULT_NORM, 6, LL_BASE, LL_BITS)
const ML_DEFAULT_TABLE = build_default_table(ML_DEFAULT_NORM, 6, ML_BASE, ML_BITS)
const OF_DEFAULT_TABLE = build_default_table(OF_DEFAULT_NORM, 5, OF_BASE, OF_BITS)

# ---------------------------------------------------------------------------
# Huffman tables
# ---------------------------------------------------------------------------
# Single-symbol table: entry = (symbol << 8) | nbits, size 2^tablelog.

"""
Decode a Huffman tree description at `p[1:len]` into `table`.
Returns `(tablelog, bytes_consumed, nsymbols)`; `ws[1:nsymbols]` holds the
weights including the implied last one.
"""
function read_huf_table!(table::Vector{UInt16}, ws::Vector{UInt8}, p::Ptr{UInt8}, len::Int,
                         norm::Vector{Int16}, symnext::Vector{UInt16}, tabsym::Vector{UInt8},
                         wtable::Vector{UInt64})
    len < 1 && zerr("truncated Huffman tree description")
    hb = Int(unsafe_load(p))
    nw = 0
    if hb < 128
        csize = hb
        csize + 1 > len && zerr("truncated Huffman tree description")
        csize < 2 && zerr("invalid Huffman weight stream")
        q = p + 1
        nsym, al, hlen = read_fse_header!(norm, q, csize, 256, 6)
        build_fse_table!(wtable, norm, nsym, al, ID_BASE, ID_BITS, symnext, tabsym)
        hlen >= csize && zerr("invalid Huffman weight stream")
        b = bitd_init(q + hlen, csize - hlen)
        s1, b = bitd_read(b, al)
        s2, b = bitd_read(b, al)
        tab = wtable
        @inbounds while true
            nw >= 255 && zerr("too many Huffman weights")
            e = tab[s1 + 1]
            nw += 1; ws[nw] = UInt8(fse_base(e))
            v, b = bitd_read(b, fse_nbbits(e)); s1 = fse_newstate(e) + v
            b = bitd_reload(b)
            if bitd_overflow(b)
                nw += 1; ws[nw] = UInt8(fse_base(tab[s2 + 1]))
                break
            end
            nw >= 255 && zerr("too many Huffman weights")
            e = tab[s2 + 1]
            nw += 1; ws[nw] = UInt8(fse_base(e))
            v, b = bitd_read(b, fse_nbbits(e)); s2 = fse_newstate(e) + v
            b = bitd_reload(b)
            if bitd_overflow(b)
                nw += 1; ws[nw] = UInt8(fse_base(tab[s1 + 1]))
                break
            end
        end
        consumed = 1 + csize
    else
        nw = hb - 127
        nbytes = (nw + 1) >> 1
        nbytes + 1 > len && zerr("truncated Huffman tree description")
        @inbounds for i in 0:nw-1
            byte = unsafe_load(p, 2 + (i >> 1))
            ws[i + 1] = iseven(i) ? (byte >> 4) : (byte & 0x0f)
        end
        consumed = 1 + nbytes
    end
    # Weight sum and implied last weight
    total = 0
    @inbounds for i in 1:nw
        w = Int(ws[i])
        w > HUF_TABLELOG_MAX + 1 && zerr("Huffman weight too large")
        w > 0 && (total += 1 << (w - 1))
    end
    total == 0 && zerr("empty Huffman weights")
    tl = 64 - leading_zeros(UInt64(total))
    tl > HUF_TABLELOG_MAX && zerr("Huffman table log too large")
    rest = (1 << tl) - total
    ispow2(rest) || zerr("invalid Huffman weights (incomplete tree)")
    nw >= 256 && zerr("too many Huffman symbols")
    nw += 1
    @inbounds ws[nw] = UInt8(trailing_zeros(rest) + 1)
    # Fill the table: weight ascending (longest codes first), symbol ascending.
    tsize = 1 << tl
    length(table) == tsize || resize!(table, tsize)
    # rank start positions
    rankstart = zeros(Int, 13)
    @inbounds for i in 1:nw
        w = Int(ws[i])
        w > 0 && (rankstart[w + 1] += 1 << (w - 1))
    end
    pos = 0
    @inbounds for w in 1:tl+1
        c = rankstart[w + 1]
        rankstart[w + 1] = pos
        pos += c
    end
    @inbounds for s in 1:nw
        w = Int(ws[s])
        w == 0 && continue
        nb = tl + 1 - w
        e = (UInt16(s - 1) << 8) | UInt16(nb)
        start = rankstart[w + 1]
        n = 1 << (w - 1)
        for k in 1:n
            table[start + k] = e
        end
        rankstart[w + 1] = start + n
    end
    return tl, consumed, nw
end

@inline function huf_decode1(b::BitD, tab::Ptr{UInt16}, tl::Int)
    e = unsafe_load(tab, Int(bitd_peek_nz(b, tl)) + 1)
    return (e >> 8) % UInt8, bitd_skip(b, Int(e & 0xff))
end

# Decode symbols from one stream into op[0:n-1].
@inline function huf_decode_tail!(op::Ptr{UInt8}, n::Int, b::BitD, tab::Ptr{UInt16}, tl::Int)
    i = 0
    while i + 4 <= n
        b = bitd_reload(b)
        s, b = huf_decode1(b, tab, tl); unsafe_store!(op + i, s)
        s, b = huf_decode1(b, tab, tl); unsafe_store!(op + i + 1, s)
        s, b = huf_decode1(b, tab, tl); unsafe_store!(op + i + 2, s)
        s, b = huf_decode1(b, tab, tl); unsafe_store!(op + i + 3, s)
        i += 4
    end
    b = bitd_reload(b)
    while i < n
        s, b = huf_decode1(b, tab, tl); unsafe_store!(op + i, s)
        i += 1
    end
    return b
end

function huf_decode_1stream!(op::Ptr{UInt8}, n::Int, src::Ptr{UInt8}, len::Int, tab::Ptr{UInt16}, tl::Int)
    b = bitd_init(src, len)
    b = huf_decode_tail!(op, n, b, tab, tl)
    bitd_finished(b) || zerr("Huffman stream not fully consumed (corrupted)")
    return nothing
end

function huf_decode_4streams!(op::Ptr{UInt8}, n::Int, src::Ptr{UInt8}, len::Int, tab::Ptr{UInt16}, tl::Int)
    len < 10 && zerr("Huffman 4-stream literals too short")
    l1 = Int(unsafe_load(src, 1)) | (Int(unsafe_load(src, 2)) << 8)
    l2 = Int(unsafe_load(src, 3)) | (Int(unsafe_load(src, 4)) << 8)
    l3 = Int(unsafe_load(src, 5)) | (Int(unsafe_load(src, 6)) << 8)
    l4 = len - 6 - l1 - l2 - l3
    (l1 < 1 || l2 < 1 || l3 < 1 || l4 < 1) && zerr("invalid Huffman jump table")
    seg = (n + 3) >> 2
    n4 = n - 3 * seg
    n4 < 0 && zerr("invalid Huffman 4-stream literal size")
    s1 = src + 6
    s2 = s1 + l1
    s3 = s2 + l2
    s4 = s3 + l3
    b1 = bitd_init(s1, l1)
    b2 = bitd_init(s2, l2)
    b3 = bitd_init(s3, l3)
    b4 = bitd_init(s4, l4)
    o1 = op
    o2 = op + seg
    o3 = op + 2seg
    o4 = op + 3seg
    # Lockstep: stream 4 is the shortest, so bound the loop by it.
    k = 0
    while k + 4 <= n4
        b1 = bitd_reload(b1); b2 = bitd_reload(b2); b3 = bitd_reload(b3); b4 = bitd_reload(b4)
        for j in 0:3
            x1, b1 = huf_decode1(b1, tab, tl)
            x2, b2 = huf_decode1(b2, tab, tl)
            x3, b3 = huf_decode1(b3, tab, tl)
            x4, b4 = huf_decode1(b4, tab, tl)
            unsafe_store!(o1 + k + j, x1)
            unsafe_store!(o2 + k + j, x2)
            unsafe_store!(o3 + k + j, x3)
            unsafe_store!(o4 + k + j, x4)
        end
        k += 4
    end
    b1 = huf_decode_tail!(o1 + k, seg - k, b1, tab, tl)
    b2 = huf_decode_tail!(o2 + k, seg - k, b2, tab, tl)
    b3 = huf_decode_tail!(o3 + k, seg - k, b3, tab, tl)
    b4 = huf_decode_tail!(o4 + k, n4 - k, b4, tab, tl)
    (bitd_finished(b1) && bitd_finished(b2) && bitd_finished(b3) && bitd_finished(b4)) ||
        zerr("Huffman stream not fully consumed (corrupted)")
    return nothing
end

# ---------------------------------------------------------------------------
# Dictionary
# ---------------------------------------------------------------------------

"""
    ZstdDictionary

A parsed Zstandard dictionary (raw content or formatted with entropy tables).
Create with [`parse_dictionary`](@ref).
"""
struct ZstdDictionary
    id::UInt32
    huf::Vector{UInt16}       # decoding tables; empty if absent
    huf_log::Int
    ll::Vector{UInt64}
    ml::Vector{UInt64}
    of::Vector{UInt64}
    rep_offsets::NTuple{3,Int}
    content::Vector{UInt8}
    # entropy statistics, used to build matching encoding tables
    huf_weights::Vector{UInt8}
    ll_norm::Vector{Int16}
    ml_norm::Vector{Int16}
    of_norm::Vector{Int16}
end

"""
    ZstdDictionary(content::AbstractVector{UInt8})

A raw-content dictionary (ID 0): `content` is used as history preceding the
data, without entropy tables. Same as `parse_dictionary` for data that does
not start with the dictionary magic number.
"""
ZstdDictionary(content::AbstractVector{UInt8}) =
    ZstdDictionary(UInt32(0), UInt16[], 0, UInt64[], UInt64[], UInt64[], (1, 4, 8),
                   Vector{UInt8}(content), UInt8[], Int16[], Int16[], Int16[])

has_entropy(d::ZstdDictionary) = !isempty(d.huf)

const DICT_MAGIC = 0xEC30A437

"""
    parse_dictionary(data::AbstractVector{UInt8}) -> ZstdDictionary

Parse a Zstandard dictionary. Data starting with the dictionary magic number
`0xEC30A437` is parsed as a formatted dictionary (ID, entropy tables, repeat
offsets, content); anything else is treated as raw content with ID 0.
"""
function parse_dictionary(data::AbstractVector{UInt8})
    d = Vector{UInt8}(data)
    if length(d) >= 8 && ltoh(reinterpret(UInt32, view(d, 1:4))[1]) == DICT_MAGIC
        id = ltoh(reinterpret(UInt32, view(d, 5:8))[1])
        norm = zeros(Int16, 256); symnext = zeros(UInt16, 256); tabsym = zeros(UInt8, 4096)
        ws = zeros(UInt8, 256); wtable = UInt64[]
        huf = UInt16[]; ll = UInt64[]; ml = UInt64[]; of = UInt64[]
        pos = 9
        GC.@preserve d begin
            p = pointer(d)
            rem() = length(d) - pos + 1
            tl, n, nw = read_huf_table!(huf, ws, p + pos - 1, rem(), norm, symnext, tabsym, wtable)
            pos += n
            weights = ws[1:nw]
            nsym, al, n = read_fse_header!(norm, p + pos - 1, rem(), 32, OF_MAX_AL); pos += n
            build_fse_table!(of, norm, nsym, al, OF_BASE, OF_BITS, symnext, tabsym)
            of_norm = norm[1:nsym]
            nsym, al, n = read_fse_header!(norm, p + pos - 1, rem(), 53, ML_MAX_AL); pos += n
            build_fse_table!(ml, norm, nsym, al, ML_BASE, ML_BITS, symnext, tabsym)
            ml_norm = norm[1:nsym]
            nsym, al, n = read_fse_header!(norm, p + pos - 1, rem(), 36, LL_MAX_AL); pos += n
            build_fse_table!(ll, norm, nsym, al, LL_BASE, LL_BITS, symnext, tabsym)
            ll_norm = norm[1:nsym]
            rem() < 12 && zerr("truncated dictionary")
            r1 = Int(load32(p + pos - 1)); r2 = Int(load32(p + pos + 3)); r3 = Int(load32(p + pos + 7))
            pos += 12
        end
        content = d[pos:end]
        for r in (r1, r2, r3)
            (r == 0 || r > length(content)) && zerr("invalid dictionary repeat offset")
        end
        return ZstdDictionary(id, huf, tl, ll, ml, of, (r1, r2, r3), content,
                              weights, ll_norm, ml_norm, of_norm)
    end
    return ZstdDictionary(d)
end

# ---------------------------------------------------------------------------
# Decoder state (reusable scratch)
# ---------------------------------------------------------------------------

"""
    DecoderState()

Reusable scratch space and entropy state for decoding. Not thread-safe; use one
per task.
"""
mutable struct DecoderState
    rep1::Int
    rep2::Int
    rep3::Int
    lit::Vector{UInt8}
    huf_own::Vector{UInt16}
    huf::Vector{UInt16}       # current Huffman table (empty = none)
    huf_log::Int
    ll_own::Vector{UInt64}
    ml_own::Vector{UInt64}
    of_own::Vector{UInt64}
    ll_rle::Vector{UInt64}
    ml_rle::Vector{UInt64}
    of_rle::Vector{UInt64}
    llT::Vector{UInt64}       # current tables (empty = none)
    mlT::Vector{UInt64}
    ofT::Vector{UInt64}
    norm::Vector{Int16}
    symnext::Vector{UInt16}
    tabsym::Vector{UInt8}
    ws::Vector{UInt8}
    wtable::Vector{UInt64}
end

const EMPTY_U64 = UInt64[]
const EMPTY_U16 = UInt16[]

function DecoderState()
    DecoderState(1, 4, 8, Vector{UInt8}(undef, BLOCK_SIZE_MAX + WILDCOPY_SLACK),
        UInt16[], EMPTY_U16, 0,
        UInt64[], UInt64[], UInt64[], UInt64[0], UInt64[0], UInt64[0],
        EMPTY_U64, EMPTY_U64, EMPTY_U64,
        zeros(Int16, 256), zeros(UInt16, 256), zeros(UInt8, 4096), zeros(UInt8, 256), UInt64[])
end

function reset_frame!(st::DecoderState, dict::Union{Nothing,ZstdDictionary})
    if dict === nothing
        st.rep1, st.rep2, st.rep3 = 1, 4, 8
        st.huf = EMPTY_U16; st.huf_log = 0
        st.llT = EMPTY_U64; st.mlT = EMPTY_U64; st.ofT = EMPTY_U64
    else
        st.rep1, st.rep2, st.rep3 = dict.rep_offsets
        st.huf = dict.huf; st.huf_log = dict.huf_log
        st.llT = dict.ll; st.mlT = dict.ml; st.ofT = dict.of
    end
    return st
end

# ---------------------------------------------------------------------------
# Literals section
# ---------------------------------------------------------------------------

# Decode the literals section at src[1:len] into st.lit. Returns (bytes_consumed, nlit).
function decode_literals!(st::DecoderState, src::Ptr{UInt8}, len::Int)
    len < 1 && zerr("empty block")
    b0 = Int(unsafe_load(src))
    ltype = b0 & 3
    sf = (b0 >> 2) & 3
    if ltype <= 1
        if sf == 0 || sf == 2
            regen = b0 >> 3; hs = 1
        elseif sf == 1
            len < 2 && zerr("truncated literals header")
            regen = (b0 >> 4) | (Int(unsafe_load(src, 2)) << 4); hs = 2
        else
            len < 3 && zerr("truncated literals header")
            regen = (b0 >> 4) | (Int(unsafe_load(src, 2)) << 4) | (Int(unsafe_load(src, 3)) << 12); hs = 3
        end
        regen > BLOCK_SIZE_MAX && zerr("literals size too large")
        lit = st.lit
        GC.@preserve lit begin
            if ltype == 0
                hs + regen > len && zerr("truncated raw literals")
                unsafe_copyto!(pointer(lit), src + hs, regen)
                return hs + regen, regen
            else
                hs + 1 > len && zerr("truncated RLE literals")
                memset!(pointer(lit), unsafe_load(src, hs + 1), regen)
                return hs + 1, regen
            end
        end
    end
    # Compressed or treeless
    if sf <= 1
        len < 3 && zerr("truncated literals header")
        h = b0 | (Int(unsafe_load(src, 2)) << 8) | (Int(unsafe_load(src, 3)) << 16)
        regen = (h >> 4) & 0x3FF; csize = (h >> 14) & 0x3FF; hs = 3
    elseif sf == 2
        len < 4 && zerr("truncated literals header")
        h = b0 | (Int(unsafe_load(src, 2)) << 8) | (Int(unsafe_load(src, 3)) << 16) | (Int(unsafe_load(src, 4)) << 24)
        regen = (h >> 4) & 0x3FFF; csize = (h >> 18) & 0x3FFF; hs = 4
    else
        len < 5 && zerr("truncated literals header")
        h = b0 | (Int(unsafe_load(src, 2)) << 8) | (Int(unsafe_load(src, 3)) << 16) |
            (Int(unsafe_load(src, 4)) << 24) | (Int(unsafe_load(src, 5)) << 32)
        regen = (h >> 4) & 0x3FFFF; csize = (h >> 22) & 0x3FFFF; hs = 5
    end
    regen > BLOCK_SIZE_MAX && zerr("literals size too large")
    hs + csize > len && zerr("truncated compressed literals")
    q = src + hs
    tsize = 0
    if ltype == 2
        tl, tsize, _ = read_huf_table!(st.huf_own, st.ws, q, csize, st.norm, st.symnext, st.tabsym, st.wtable)
        st.huf = st.huf_own
        st.huf_log = tl
    elseif isempty(st.huf)
        zerr("treeless literals block without a previous Huffman table")
    end
    tab = st.huf
    lit = st.lit
    GC.@preserve tab lit begin
        if sf == 0
            huf_decode_1stream!(pointer(lit), regen, q + tsize, csize - tsize, pointer(tab), st.huf_log)
        else
            huf_decode_4streams!(pointer(lit), regen, q + tsize, csize - tsize, pointer(tab), st.huf_log)
        end
    end
    return hs + csize, regen
end

# ---------------------------------------------------------------------------
# Sequences section
# ---------------------------------------------------------------------------

@inline function select_table!(st::DecoderState, mode::Int, src::Ptr{UInt8}, pos::Int, len::Int,
                               own::Vector{UInt64}, rle::Vector{UInt64}, current::Vector{UInt64},
                               default::Vector{UInt64}, max_sym::Int, max_al::Int,
                               vbase::Vector{UInt32}, vbits::Vector{UInt8})
    if mode == 0
        return default, pos
    elseif mode == 1
        pos > len && zerr("truncated RLE sequence table")
        s = Int(unsafe_load(src, pos))
        s >= max_sym && zerr("invalid RLE sequence symbol")
        @inbounds rle[1] = fse_entry(0, 0, vbits[s + 1], vbase[s + 1])
        return rle, pos + 1
    elseif mode == 2
        pos > len && zerr("truncated FSE sequence table")
        nsym, al, n = read_fse_header!(st.norm, src + pos - 1, len - pos + 1, max_sym, max_al)
        build_fse_table!(own, st.norm, nsym, al, vbase, vbits, st.symnext, st.tabsym)
        return own, pos + n
    else
        isempty(current) && zerr("repeat sequence table mode without a previous table")
        return current, pos
    end
end

"""
Decode one compressed block at `src[1:len]` and write its output at `op`.
`hist` is the earliest valid match source within the output buffer (frame
start); `olimit` bounds the output. Returns the new output pointer.
"""
function decode_compressed_block!(st::DecoderState, src::Ptr{UInt8}, len::Int,
                                  op::Ptr{UInt8}, hist::Ptr{UInt8}, olimit::Ptr{UInt8},
                                  dict::Union{Nothing,ZstdDictionary})
    lpos, nlit = decode_literals!(st, src, len)
    pos = lpos + 1
    pos > len && zerr("missing sequences section")
    b0 = Int(unsafe_load(src, pos)); pos += 1
    if b0 < 128
        nseq = b0
    elseif b0 < 255
        pos > len && zerr("truncated sequences header")
        nseq = ((b0 - 128) << 8) + Int(unsafe_load(src, pos)); pos += 1
    else
        pos + 1 > len && zerr("truncated sequences header")
        nseq = Int(unsafe_load(src, pos)) + (Int(unsafe_load(src, pos + 1)) << 8) + 0x7F00; pos += 2
    end
    lit = st.lit
    if nseq == 0
        pos <= len && zerr("extraneous data in sequences section")
        op + nlit > olimit && zerr("block output too large")
        GC.@preserve lit unsafe_copyto!(op, pointer(lit), nlit)
        return op + nlit
    end
    pos > len && zerr("truncated sequences header")
    modes = Int(unsafe_load(src, pos)); pos += 1
    (modes & 3) != 0 && zerr("reserved bits set in sequences header")
    llT, pos = select_table!(st, (modes >> 6) & 3, src, pos, len, st.ll_own, st.ll_rle, st.llT,
                             LL_DEFAULT_TABLE, 36, LL_MAX_AL, LL_BASE, LL_BITS)
    ofT, pos = select_table!(st, (modes >> 4) & 3, src, pos, len, st.of_own, st.of_rle, st.ofT,
                             OF_DEFAULT_TABLE, 32, OF_MAX_AL, OF_BASE, OF_BITS)
    mlT, pos = select_table!(st, (modes >> 2) & 3, src, pos, len, st.ml_own, st.ml_rle, st.mlT,
                             ML_DEFAULT_TABLE, 53, ML_MAX_AL, ML_BASE, ML_BITS)
    st.llT = llT; st.ofT = ofT; st.mlT = mlT
    pos > len && zerr("missing sequence bitstream")
    GC.@preserve lit llT ofT mlT dict begin
        op = execute_sequences!(st, nseq, src + pos - 1, len - pos + 1,
                                pointer(llT), trailing_zeros(length(llT)),
                                pointer(ofT), trailing_zeros(length(ofT)),
                                pointer(mlT), trailing_zeros(length(mlT)),
                                pointer(lit), nlit, op, hist, olimit, dict)
    end
    return op
end

@noinline function dict_match!(op::Ptr{UInt8}, hist::Ptr{UInt8}, offset::Int, ml::Int,
                              dict::Union{Nothing,ZstdDictionary})
    back = offset - Int(op - hist)
    if dict === nothing || back > length(dict.content)
        zerr("match offset beyond available history (corrupted)")
    end
    content = dict.content
    GC.@preserve content begin
        dsrc = pointer(content) + length(content) - back
        n1 = min(back, ml)
        unsafe_copyto!(op, dsrc, n1)
    end
    op += n1
    ml -= n1
    for i in 0:ml-1     # remaining bytes come from the frame start (may overlap)
        unsafe_store!(op + i, unsafe_load(op + i - offset))
    end
    return nothing
end

function execute_sequences!(st::DecoderState, nseq::Int, src::Ptr{UInt8}, len::Int,
                            llT::Ptr{UInt64}, llAL::Int, ofT::Ptr{UInt64}, ofAL::Int,
                            mlT::Ptr{UInt64}, mlAL::Int,
                            lit::Ptr{UInt8}, nlit::Int,
                            op::Ptr{UInt8}, hist::Ptr{UInt8}, olimit::Ptr{UInt8},
                            dict::Union{Nothing,ZstdDictionary})
    litend = lit + nlit
    b = bitd_init(src, len)
    llS, b = bitd_read(b, llAL)
    ofS, b = bitd_read(b, ofAL)
    mlS, b = bitd_read(b, mlAL)
    rep1, rep2, rep3 = st.rep1, st.rep2, st.rep3
    for i in 1:nseq
        b = bitd_reload(b)
        lle = unsafe_load(llT, llS + 1)
        mle = unsafe_load(mlT, mlS + 1)
        ofe = unsafe_load(ofT, ofS + 1)
        ofb = fse_nbadd(ofe); mlb = fse_nbadd(mle); llb = fse_nbadd(lle)
        v, b = bitd_read(b, ofb)
        ofval = fse_base(ofe) + v
        v, b = bitd_read(b, mlb)
        ml = fse_base(mle) + v
        if ofb + mlb + llb > 31
            b = bitd_reload(b)
        end
        v, b = bitd_read(b, llb)
        ll = fse_base(lle) + v
        if ofval > 3
            offset = ofval - 3
            rep3 = rep2; rep2 = rep1; rep1 = offset
        else
            idx = ofval + (ll == 0)
            if idx == 1
                offset = rep1
            elseif idx == 2
                offset = rep2
                rep2 = rep1; rep1 = offset
            elseif idx == 3
                offset = rep3
                rep3 = rep2; rep2 = rep1; rep1 = offset
            else
                offset = rep1 - 1
                offset == 0 && zerr("invalid repeat offset 0 (corrupted)")
                rep3 = rep2; rep2 = rep1; rep1 = offset
            end
        end
        if i < nseq
            v, b = bitd_read(b, fse_nbbits(lle)); llS = fse_newstate(lle) + v
            v, b = bitd_read(b, fse_nbbits(mle)); mlS = fse_newstate(mle) + v
            v, b = bitd_read(b, fse_nbbits(ofe)); ofS = fse_newstate(ofe) + v
        end
        # --- execute ---
        (op + ll + ml > olimit) && zerr("block output too large (corrupted)")
        (lit + ll > litend) && zerr("literal length exceeds literals (corrupted)")
        if ll <= 16
            copy16(op, lit)
        else
            unsafe_copyto!(op, lit, ll)
        end
        op += ll
        lit += ll
        if offset > Int(op - hist)
            dict_match!(op, hist, offset, ml, dict)
        else
            match_copy!(op, offset, ml)
        end
        op += ml
    end
    bitd_finished(b) || zerr("sequence bitstream not fully consumed (corrupted)")
    st.rep1, st.rep2, st.rep3 = rep1, rep2, rep3
    rest = Int(litend - lit)
    op + rest > olimit && zerr("block output too large (corrupted)")
    unsafe_copyto!(op, lit, rest)
    return op + rest
end

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

"""
    FrameInfo

Parsed Zstandard frame header. `content_size` is `-1` when absent.
"""
struct FrameInfo
    header_size::Int
    window_size::Int
    content_size::Int64
    dict_id::UInt32
    checksum::Bool
    single_segment::Bool
end

"""
    read_frame_info(p::Ptr{UInt8}, len) -> FrameInfo

Parse the frame header following the magic number at `p[1:len]`.
"""
function read_frame_info(p::Ptr{UInt8}, len::Int)
    len < 1 && zerr("truncated frame header")
    fd = Int(unsafe_load(p))
    fcs_flag = fd >> 6
    single = (fd >> 5) & 1 == 1
    (fd >> 3) & 1 == 1 && zerr("reserved bit set in frame header")
    checksum = (fd >> 2) & 1 == 1
    did_flag = fd & 3
    did_size = (0, 1, 2, 4)[did_flag + 1]
    fcs_size = (single ? 1 : 0, 2, 4, 8)[fcs_flag + 1]
    hs = 1 + (single ? 0 : 1) + did_size + fcs_size
    len < hs && zerr("truncated frame header")
    pos = 2
    window = 0
    if !single
        wd = Int(unsafe_load(p, pos)); pos += 1
        ex = (wd >> 3) + 10
        ex > 41 && zerr("window size too large")
        wb = 1 << ex
        window = wb + (wb >> 3) * (wd & 7)
    end
    did = UInt32(0)
    for k in 0:did_size-1
        did |= UInt32(unsafe_load(p, pos + k)) << (8k)
    end
    pos += did_size
    fcs = Int64(-1)
    if fcs_size > 0
        v = UInt64(0)
        for k in 0:fcs_size-1
            v |= UInt64(unsafe_load(p, pos + k)) << (8k)
        end
        fcs_size == 2 && (v += 256)
        v > typemax(Int64) && zerr("frame content size too large")
        fcs = Int64(v)
    end
    if single
        window = Int(fcs)
    end
    return FrameInfo(hs, window, fcs, did, checksum, single)
end

# Pre-size estimate of a frame's content from its block headers, starting at
# 1-based position `pos` of the input at `p` (last valid index `n`). Raw and
# RLE sizes are exact (they are what decoding will produce); a compressed
# block counts as at most a block, but no more than 64 times its compressed
# size plus 4 KiB, so that forged headers cannot claim gigabytes from a few
# bytes (larger outputs grow as they decode). Stops quietly at malformed data,
# which decoding reports.
function frame_presize(p::Ptr{UInt8}, pos::Int, n::Int, window::Int)
    bmax = min(BLOCK_SIZE_MAX, window)
    total = 0
    while pos + 2 <= n
        bh = Int(unsafe_load(p, pos)) | (Int(unsafe_load(p, pos + 1)) << 8) | (Int(unsafe_load(p, pos + 2)) << 16)
        btype = (bh >> 1) & 3; bsize = bh >> 3
        (btype == 3 || bsize > bmax) && break
        pos += 3 + (btype == 1 ? 1 : bsize)
        pos - 1 > n && break
        total += btype == 2 ? min(bmax, 64 * bsize + 4096) : bsize
        bh & 1 == 1 && break
    end
    return total
end

@inline function ensure_capacity!(out::Vector{UInt8}, need::Int)
    if length(out) < need
        resize!(out, max(need, 2 * length(out)))
    end
    return out
end

"""
    decompress_frames(data, st, dict; range=1:length(data)) -> Vector{UInt8}

Decode all (concatenated) frames in `data[range]` in memory. `range` must
start and end on frame boundaries.
"""
function decompress_frames(data::AbstractVector{UInt8}, st::DecoderState=DecoderState(),
                           dict::Union{Nothing,ZstdDictionary}=nothing;
                           range::UnitRange{Int}=1:length(data))
    src = data isa Vector{UInt8} ? data : Vector{UInt8}(data)
    checkbounds(src, range)
    n = range.stop            # last valid input index
    out = Vector{UInt8}(undef, 0)
    produced = 0
    pos = range.start
    first = true
    GC.@preserve src begin
        p = pointer(src)
        while pos <= n
            n - pos + 1 < 4 && zerr("truncated frame (magic number)")
            magic = load32(p + pos - 1)
            pos += 4
            if magic & SKIPPABLE_MASK == SKIPPABLE_MAGIC_START
                n - pos + 1 < 4 && zerr("truncated skippable frame")
                sz = Int(load32(p + pos - 1)); pos += 4
                pos + sz - 1 > n && zerr("truncated skippable frame")
                pos += sz
                continue
            end
            magic != MAGIC_NUMBER && zerr("unknown frame magic number 0x$(string(magic, base=16))")
            fi = read_frame_info(p + pos - 1, n - pos + 1)
            pos += fi.header_size
            if fi.dict_id != 0
                dict === nothing && zerr("frame requires dictionary ID $(fi.dict_id)")
                (dict.id != 0 && dict.id != fi.dict_id) &&
                    zerr("dictionary ID mismatch: frame requires $(fi.dict_id), got $(dict.id)")
            end
            reset_frame!(st, dict)
            frame_start = produced
            # Pre-size the output from the block headers, and from the
            # recorded content size when it is smaller. Both are untrusted, so
            # frame_presize limits what junk can claim; outputs larger than
            # the guess grow as they decode.
            guess = frame_presize(p, pos, n, fi.window_size)
            fi.content_size >= 0 && (guess = min(guess, Int(fi.content_size)))
            if first
                resize!(out, guess + WILDCOPY_SLACK)
                first = false
            else
                ensure_capacity!(out, produced + guess + WILDCOPY_SLACK)
            end
            while true
                n - pos + 1 < 3 && zerr("truncated block header")
                bh = Int(unsafe_load(p, pos)) | (Int(unsafe_load(p, pos + 1)) << 8) | (Int(unsafe_load(p, pos + 2)) << 16)
                pos += 3
                last = bh & 1 == 1
                btype = (bh >> 1) & 3
                bsize = bh >> 3
                if btype == 0
                    pos + bsize - 1 > n && zerr("truncated raw block")
                    bsize > BLOCK_SIZE_MAX && zerr("block too large")
                    ensure_capacity!(out, produced + bsize + WILDCOPY_SLACK)
                    GC.@preserve out unsafe_copyto!(pointer(out) + produced, p + pos - 1, bsize)
                    produced += bsize
                    pos += bsize
                elseif btype == 1
                    pos > n && zerr("truncated RLE block")
                    bsize > BLOCK_SIZE_MAX && zerr("block too large")
                    ensure_capacity!(out, produced + bsize + WILDCOPY_SLACK)
                    GC.@preserve out memset!(pointer(out) + produced, unsafe_load(p, pos), bsize)
                    produced += bsize
                    pos += 1
                elseif btype == 2
                    pos + bsize - 1 > n && zerr("truncated compressed block")
                    bsize > BLOCK_SIZE_MAX && zerr("block too large")
                    lim = BLOCK_SIZE_MAX
                    if fi.content_size >= 0
                        lim = min(lim, Int(fi.content_size) - (produced - frame_start))
                        lim < 0 && zerr("frame content size exceeded")
                    end
                    ensure_capacity!(out, produced + lim + WILDCOPY_SLACK)
                    GC.@preserve out begin
                        base = pointer(out)
                        op = decode_compressed_block!(st, p + pos - 1, bsize, base + produced,
                                                      base + frame_start, base + produced + lim, dict)
                        produced = Int(op - base)
                    end
                    pos += bsize
                else
                    zerr("reserved block type")
                end
                last && break
            end
            if fi.content_size >= 0 && produced - frame_start != fi.content_size
                zerr("frame content size mismatch: header says $(fi.content_size), decoded $(produced - frame_start)")
            end
            if fi.checksum
                n - pos + 1 < 4 && zerr("truncated frame checksum")
                expected = load32(p + pos - 1)
                pos += 4
                actual = content_checksum(view(out, frame_start+1:produced))
                actual != expected && zerr("checksum mismatch")
            end
        end
    end
    resize!(out, produced)
    return out
end

end # module
