# Zstandard compressor (RFC 8878), structured after the reference implementation.
#
#   * A level table selects a match-finding strategy and its parameters:
#     fast (single hash), dfast (long + short hash), greedy / lazy / lazy2
#     (hash chain with lazy evaluation). All parsers try repeat offsets first.
#   * The input is compressed in blocks of up to 128 KiB; hash tables persist
#     across blocks so matches can reach back a full window.
#   * Sequences are entropy coded with FSE using cost-based selection between
#     predefined, RLE, freshly-built and repeated tables. Literals are Huffman
#     coded (direct or FSE-compressed weights, 1 or 4 streams), or reuse the
#     previous block's table (treeless) when cheaper.

module Encoder

using XXHashNative: xxh64
import ..Decoder: LL_BASE, LL_BITS, ML_BASE, ML_BITS, LL_DEFAULT_NORM, ML_DEFAULT_NORM,
                  OF_DEFAULT_NORM, MAGIC_NUMBER, BLOCK_SIZE_MAX

export CompressionContext, compress_frame!, compression_parameters, MIN_LEVEL, MAX_LEVEL

const MIN_LEVEL = -7
const MAX_LEVEL = 22
const HUF_MAX_BITS = 11
const LL_MAX_AL = 9
const ML_MAX_AL = 9
const OF_MAX_AL = 8
const MIN_MATCH = 3

# ---------------------------------------------------------------------------
# Compression parameters (after ZSTD_defaultCParameters for large inputs)
# ---------------------------------------------------------------------------

@enum Strategy S_FAST S_DFAST S_GREEDY S_LAZY S_LAZY2

struct CParams
    window_log::Int
    chain_log::Int
    hash_log::Int
    search_log::Int
    min_match::Int
    target_length::Int
    strategy::Strategy
end

# window, chain, hash, search, minMatch, targetLength, strategy
# Levels 13+ use libzstd's window/table sizes but lazy2 parsing (the binary-tree
# and optimal parsers of libzstd levels 13-22 are not implemented); search depth
# is capped where deeper chains stopped paying for themselves on real data.
const LEVEL_TABLE = CParams[
    CParams(19, 12, 13, 1, 6, 1, S_FAST),     # base for negative levels
    CParams(19, 13, 14, 1, 7, 0, S_FAST),     # 1
    CParams(20, 15, 16, 1, 6, 0, S_FAST),     # 2
    CParams(21, 16, 17, 1, 5, 0, S_DFAST),    # 3
    CParams(21, 18, 18, 1, 5, 0, S_DFAST),    # 4
    CParams(21, 18, 19, 3, 5, 2, S_GREEDY),   # 5
    CParams(21, 18, 19, 3, 5, 4, S_LAZY),     # 6
    CParams(21, 19, 20, 4, 5, 8, S_LAZY),     # 7
    CParams(21, 19, 20, 4, 5, 16, S_LAZY2),   # 8
    CParams(22, 20, 21, 4, 5, 16, S_LAZY2),   # 9
    CParams(22, 21, 22, 5, 5, 16, S_LAZY2),   # 10
    CParams(22, 21, 22, 6, 5, 16, S_LAZY2),   # 11
    CParams(22, 22, 23, 6, 5, 32, S_LAZY2),   # 12
    CParams(22, 22, 22, 6, 5, 32, S_LAZY2),   # 13
    CParams(22, 22, 23, 6, 5, 48, S_LAZY2),   # 14
    CParams(22, 23, 23, 7, 5, 64, S_LAZY2),   # 15
    CParams(22, 23, 23, 7, 4, 96, S_LAZY2),   # 16
    CParams(23, 23, 23, 7, 4, 128, S_LAZY2),  # 17
    CParams(23, 24, 23, 7, 4, 192, S_LAZY2),  # 18
    CParams(23, 24, 23, 7, 4, 256, S_LAZY2),  # 19
    CParams(25, 25, 23, 8, 4, 256, S_LAZY2),  # 20
    CParams(26, 26, 24, 8, 4, 512, S_LAZY2),  # 21
    CParams(27, 27, 25, 8, 4, 999, S_LAZY2),  # 22
]

"""
    compression_parameters(level, src_size) -> CParams

Parameters for `level`, shrunk for small inputs as the reference
implementation does (smaller tables for small data are faster and lose
nothing).
"""
function compression_parameters(level::Integer, src_size::Integer)
    level = clamp(level, MIN_LEVEL, MAX_LEVEL)
    level == 0 && (level = 3)
    p = level < 0 ? LEVEL_TABLE[1] : LEVEL_TABLE[level + 1]
    target = level < 0 ? -level : p.target_length
    wlog = p.window_log
    if src_size >= 0
        src_log = max(10, 64 - leading_zeros(UInt64(max(src_size - 1, 1))))
        wlog = min(wlog, src_log)
    end
    btplus = p.strategy >= S_GREEDY
    clog = min(p.chain_log, wlog + (btplus ? 1 : 0))
    hlog = min(p.hash_log, wlog + 1)
    return CParams(wlog, clog, hlog, p.search_log, p.min_match, target, p.strategy)
end

# ---------------------------------------------------------------------------
# Memory helpers
# ---------------------------------------------------------------------------

@inline load64(p::Ptr{UInt8}) = ltoh(unsafe_load(Ptr{UInt64}(p)))
@inline load32(p::Ptr{UInt8}) = ltoh(unsafe_load(Ptr{UInt32}(p)))
@inline store64(p::Ptr{UInt8}, v::UInt64) = unsafe_store!(Ptr{UInt64}(p), htol(v))
@inline highbit(x::Integer) = 63 - leading_zeros(UInt64(x))

"""Number of equal bytes at `a` and `b`, not reading at or beyond `alimit`."""
@inline function zcount(a::Ptr{UInt8}, b::Ptr{UInt8}, alimit::Ptr{UInt8})
    start = a
    while a + 8 <= alimit
        d = load64(a) ⊻ load64(b)
        if d != 0
            return Int(a - start) + (trailing_zeros(d) >> 3)
        end
        a += 8; b += 8
    end
    while a < alimit && unsafe_load(a) == unsafe_load(b)
        a += 1; b += 1
    end
    return Int(a - start)
end

# Hashes of the first `mls` bytes at p (reads 8 bytes).
const PRIME4 = 0x9E3779B1
const PRIME5 = 0x000000CF1BBCDCBB
const PRIME6 = 0x0000CF1BBCDCBF9B
const PRIME7 = 0x00CF1BBCDCBFA563
const PRIME8 = 0xCF1BBCDCB7A56463
@inline function zhash(p::Ptr{UInt8}, hlog::Int, mls::Int)
    if mls == 4
        return Int((load32(p) * PRIME4) >> ((32 - hlog) & 31))
    elseif mls == 5
        return Int(((load64(p) << 24) * PRIME5) >> ((64 - hlog) & 63))
    elseif mls == 6
        return Int(((load64(p) << 16) * PRIME6) >> ((64 - hlog) & 63))
    elseif mls == 7
        return Int(((load64(p) << 8) * PRIME7) >> ((64 - hlog) & 63))
    else
        return Int((load64(p) * PRIME8) >> ((64 - hlog) & 63))
    end
end

# ---------------------------------------------------------------------------
# Sequence store
# ---------------------------------------------------------------------------

mutable struct SeqStore
    lit::Vector{UInt8}
    nlit::Int
    ll::Vector{UInt32}
    ml::Vector{UInt32}
    off::Vector{UInt32}     # raw match distance
    nseq::Int
end
SeqStore() = SeqStore(Vector{UInt8}(undef, BLOCK_SIZE_MAX + 32), 0,
                      Vector{UInt32}(undef, BLOCK_SIZE_MAX ÷ 3 + 2),
                      Vector{UInt32}(undef, BLOCK_SIZE_MAX ÷ 3 + 2),
                      Vector{UInt32}(undef, BLOCK_SIZE_MAX ÷ 3 + 2), 0)

@inline function store_seq!(ss::SeqStore, anchor::Ptr{UInt8}, ll::Int, offset::Int, ml::Int)
    if ll > 0
        GC.@preserve ss unsafe_copyto!(pointer(ss.lit) + ss.nlit, anchor, ll)
        ss.nlit += ll
    end
    n = ss.nseq + 1
    @inbounds ss.ll[n] = ll % UInt32
    @inbounds ss.ml[n] = ml % UInt32
    @inbounds ss.off[n] = offset % UInt32
    ss.nseq = n
    return nothing
end

@inline function store_last_literals!(ss::SeqStore, anchor::Ptr{UInt8}, n::Int)
    if n > 0
        GC.@preserve ss unsafe_copyto!(pointer(ss.lit) + ss.nlit, anchor, n)
        ss.nlit += n
    end
end

# ---------------------------------------------------------------------------
# Match finders. Each parses [istart, iend) of the input whose first byte is
# `base` (positions are 1-based offsets from base, 0 = empty slot) and fills
# the SeqStore. `lowlimit` is the lowest valid match position (window).
# Return the updated parser repeat offsets.
# ---------------------------------------------------------------------------

const K_SEARCH_STRENGTH = 8
const HASH_READ_SIZE = 8

@inline pos_of(p::Ptr{UInt8}, base::Ptr{UInt8}) = Int(p - base) + 1
@inline ptr_of(i::Integer, base::Ptr{UInt8}) = base + (i - 1)

function parse_fast!(ss::SeqStore, htab::Vector{Int32}, hlog::Int, mls::Int, step0::Int,
                     base::Ptr{UInt8}, istart::Ptr{UInt8}, iend::Ptr{UInt8}, lowlimit::Int,
                     rep1::Int, rep2::Int)
    ilimit = iend - HASH_READ_SIZE
    anchor = istart
    ip = istart
    ip == base && (ip += 1)
    GC.@preserve htab begin
        ht = pointer(htab)
        while ip < ilimit
            cur = pos_of(ip, base)
            h = zhash(ip, hlog, mls)
            midx = Int(unsafe_load(ht, h + 1))
            unsafe_store!(ht, cur % Int32, h + 1)
            # repeat offset at ip+1
            if rep1 > 0 && cur + 1 - rep1 >= lowlimit && load32(ip + 1 - rep1) == load32(ip + 1)
                ml = zcount(ip + 5, ip + 5 - rep1, iend) + 4
                ip += 1
                store_seq!(ss, anchor, Int(ip - anchor), rep1, ml)
            elseif midx >= lowlimit && midx > 0 && load32(ptr_of(midx, base)) == load32(ip)
                m = ptr_of(midx, base)
                ml = zcount(ip + 4, m + 4, iend) + 4
                while ip > anchor && m > ptr_of(lowlimit, base) && unsafe_load(ip - 1) == unsafe_load(m - 1)
                    ip -= 1; m -= 1; ml += 1
                end
                offset = Int(ip - m)
                rep2 = rep1; rep1 = offset
                store_seq!(ss, anchor, Int(ip - anchor), offset, ml)
            else
                ip += ((Int(ip - anchor) >> K_SEARCH_STRENGTH) + step0)
                continue
            end
            ip += ml
            anchor = ip
            if ip <= ilimit
                # fill the table with a position inside the match
                p2 = ip - 2
                unsafe_store!(ht, pos_of(p2, base) % Int32, zhash(p2, hlog, mls) + 1)
                # immediate repcode (ll == 0)
                while ip <= ilimit && rep2 > 0 && pos_of(ip, base) - rep2 >= lowlimit &&
                      load32(ip) == load32(ip - rep2)
                    rl = zcount(ip + 4, ip + 4 - rep2, iend) + 4
                    rep1, rep2 = rep2, rep1
                    unsafe_store!(ht, pos_of(ip, base) % Int32, zhash(ip, hlog, mls) + 1)
                    store_seq!(ss, anchor, 0, rep1, rl)
                    ip += rl
                    anchor = ip
                end
            end
        end
    end
    store_last_literals!(ss, anchor, Int(iend - anchor))
    return rep1, rep2
end

function parse_dfast!(ss::SeqStore, hlong::Vector{Int32}, hllog::Int, hsmall::Vector{Int32},
                      hslog::Int, mls::Int, base::Ptr{UInt8}, istart::Ptr{UInt8}, iend::Ptr{UInt8},
                      lowlimit::Int, rep1::Int, rep2::Int)
    ilimit = iend - HASH_READ_SIZE
    anchor = istart
    ip = istart
    ip == base && (ip += 1)
    lowp = ptr_of(max(lowlimit, 1), base)
    GC.@preserve hlong hsmall begin
        hl = pointer(hlong); hs = pointer(hsmall)
        while ip < ilimit
            cur = pos_of(ip, base)
            h8 = zhash(ip, hllog, 8)
            hsm = zhash(ip, hslog, mls)
            ml_idx = Int(unsafe_load(hl, h8 + 1))
            ms_idx = Int(unsafe_load(hs, hsm + 1))
            unsafe_store!(hl, cur % Int32, h8 + 1)
            unsafe_store!(hs, cur % Int32, hsm + 1)
            if rep1 > 0 && cur + 1 - rep1 >= lowlimit && load32(ip + 1 - rep1) == load32(ip + 1)
                ml = zcount(ip + 5, ip + 5 - rep1, iend) + 4
                ip += 1
                store_seq!(ss, anchor, Int(ip - anchor), rep1, ml)
            else
                found = false
                ml = 0; offset = 0
                if ml_idx >= lowlimit && ml_idx > 0 && load64(ptr_of(ml_idx, base)) == load64(ip)
                    m = ptr_of(ml_idx, base)
                    ml = zcount(ip + 8, m + 8, iend) + 8
                    offset = Int(ip - m)
                    while ip > anchor && m > lowp && unsafe_load(ip - 1) == unsafe_load(m - 1)
                        ip -= 1; m -= 1; ml += 1
                    end
                    found = true
                elseif ms_idx >= lowlimit && ms_idx > 0 && load32(ptr_of(ms_idx, base)) == load32(ip)
                    # check for a long match at ip+1
                    h3 = zhash(ip + 1, hllog, 8)
                    l3 = Int(unsafe_load(hl, h3 + 1))
                    unsafe_store!(hl, (cur + 1) % Int32, h3 + 1)
                    if l3 >= lowlimit && l3 > 0 && load64(ptr_of(l3, base)) == load64(ip + 1)
                        ip += 1
                        m = ptr_of(l3, base)
                        ml = zcount(ip + 8, m + 8, iend) + 8
                    else
                        m = ptr_of(ms_idx, base)
                        ml = zcount(ip + 4, m + 4, iend) + 4
                    end
                    offset = Int(ip - m)
                    while ip > anchor && m > lowp && unsafe_load(ip - 1) == unsafe_load(m - 1)
                        ip -= 1; m -= 1; ml += 1
                    end
                    found = true
                end
                if !found
                    ip += ((Int(ip - anchor) >> K_SEARCH_STRENGTH) + 1)
                    continue
                end
                rep2 = rep1; rep1 = offset
                store_seq!(ss, anchor, Int(ip - anchor), offset, ml)
            end
            ip += ml
            anchor = ip
            if ip <= ilimit
                # fill tables at positions inside the match
                ins = ptr_of(cur + 2, base)
                if ins < ip
                    unsafe_store!(hl, pos_of(ins, base) % Int32, zhash(ins, hllog, 8) + 1)
                    unsafe_store!(hs, pos_of(ins, base) % Int32, zhash(ins, hslog, mls) + 1)
                end
                unsafe_store!(hl, pos_of(ip - 2, base) % Int32, zhash(ip - 2, hllog, 8) + 1)
                unsafe_store!(hs, pos_of(ip - 1, base) % Int32, zhash(ip - 1, hslog, mls) + 1)
                while ip <= ilimit && rep2 > 0 && pos_of(ip, base) - rep2 >= lowlimit &&
                      load32(ip) == load32(ip - rep2)
                    rl = zcount(ip + 4, ip + 4 - rep2, iend) + 4
                    rep1, rep2 = rep2, rep1
                    unsafe_store!(hs, pos_of(ip, base) % Int32, zhash(ip, hslog, mls) + 1)
                    unsafe_store!(hl, pos_of(ip, base) % Int32, zhash(ip, hllog, 8) + 1)
                    store_seq!(ss, anchor, 0, rep1, rl)
                    ip += rl
                    anchor = ip
                end
            end
        end
    end
    store_last_literals!(ss, anchor, Int(iend - anchor))
    return rep1, rep2
end

# Hash chain: insert all positions in [next, target) and return the head for `target`.
@inline function hc_insert!(ht::Ptr{Int32}, ch::Ptr{Int32}, hlog::Int, cmask::Int, mls::Int,
                            base::Ptr{UInt8}, next::Int, target::Int)
    i = next
    while i < target
        h = zhash(ptr_of(i, base), hlog, mls)
        unsafe_store!(ch, unsafe_load(ht, h + 1), (i & cmask) + 1)
        unsafe_store!(ht, i % Int32, h + 1)
        i += 1
    end
    return Int(unsafe_load(ht, zhash(ptr_of(target, base), hlog, mls) + 1))
end

# Best match at ip via the hash chain. Returns (length, offset); updates `next`.
@inline function hc_find_best(ht::Ptr{Int32}, ch::Ptr{Int32}, hlog::Int, clog::Int, mls::Int,
                              attempts::Int, base::Ptr{UInt8}, ip::Ptr{UInt8}, iend::Ptr{UInt8},
                              lowlimit::Int, next::Int)
    cur = pos_of(ip, base)
    cmask = (1 << clog) - 1
    midx = hc_insert!(ht, ch, hlog, cmask, mls, base, next, cur)
    minchain = cur > (1 << clog) ? cur - (1 << clog) : 0
    best = 3
    bestoff = 0
    lowl = max(lowlimit, 1)
    while attempts > 0 && midx >= lowl
        m = ptr_of(midx, base)
        if unsafe_load(m + best) == unsafe_load(ip + best) && load32(m) == load32(ip)
            l = zcount(ip + 4, m + 4, iend) + 4
            if l > best
                best = l
                bestoff = cur - midx
                ip + l == iend && break
            end
        end
        midx <= minchain && break
        midx = Int(unsafe_load(ch, (midx & cmask) + 1))
        attempts -= 1
    end
    return (bestoff == 0 ? 0 : best), bestoff, cur
end

function parse_lazy!(ss::SeqStore, htab::Vector{Int32}, hlog::Int, ctab::Vector{Int32}, clog::Int,
                     mls::Int, attempts::Int, depth::Int, target_len::Int, base::Ptr{UInt8},
                     istart::Ptr{UInt8}, iend::Ptr{UInt8}, lowlimit::Int, rep1::Int, rep2::Int,
                     next::Int)
    ilimit = iend - HASH_READ_SIZE
    anchor = istart
    ip = istart
    ip == base && (ip += 1)
    lowp = ptr_of(max(lowlimit, 1), base)
    GC.@preserve htab ctab begin
        ht = pointer(htab); ch = pointer(ctab)
        while ip < ilimit
            ml = 0; offset = 0; start = ip + 1
            cur = pos_of(ip, base)
            # repcode at ip+1
            if rep1 > 0 && cur + 1 - rep1 >= lowlimit && load32(ip + 1 - rep1) == load32(ip + 1)
                ml = zcount(ip + 5, ip + 5 - rep1, iend) + 4
                offset = rep1
                start = ip + 1
            end
            if !(depth == 0 && ml > 0)
                l2, o2, nxt = hc_find_best(ht, ch, hlog, clog, mls, attempts, base, ip, iend, lowlimit, next)
                next = nxt
                if l2 > ml
                    ml = l2; offset = o2; start = ip
                end
            end
            if ml < 4
                ip += ((Int(ip - anchor) >> K_SEARCH_STRENGTH) + 1)
                continue
            end
            # lazy evaluation
            if depth >= 1 && ml < target_len
                while ip < ilimit
                    ip += 1
                    cur2 = pos_of(ip, base)
                    if rep1 > 0 && cur2 - rep1 >= lowlimit && load32(ip) == load32(ip - rep1)
                        mlr = zcount(ip + 4, ip + 4 - rep1, iend) + 4
                        gain2 = mlr * 3
                        gain1 = ml * 3 - highbit(offset + 3) + 1
                        if gain2 > gain1
                            ml = mlr; offset = rep1; start = ip
                        end
                    end
                    l2, o2, nxt = hc_find_best(ht, ch, hlog, clog, mls, attempts, base, ip, iend, lowlimit, next)
                    next = nxt
                    gain2 = l2 * 4 - highbit(o2 + 3)
                    gain1 = ml * 4 - highbit(offset + 3) + 4
                    if l2 >= 4 && gain2 > gain1
                        ml = l2; offset = o2; start = ip
                        continue
                    end
                    if depth == 2 && ip < ilimit
                        ip += 1
                        cur2 = pos_of(ip, base)
                        if rep1 > 0 && cur2 - rep1 >= lowlimit && load32(ip) == load32(ip - rep1)
                            mlr = zcount(ip + 4, ip + 4 - rep1, iend) + 4
                            gain2 = mlr * 4
                            gain1 = ml * 4 - highbit(offset + 3) + 1
                            if gain2 > gain1
                                ml = mlr; offset = rep1; start = ip
                            end
                        end
                        l2, o2, nxt = hc_find_best(ht, ch, hlog, clog, mls, attempts, base, ip, iend, lowlimit, next)
                        next = nxt
                        gain2 = l2 * 4 - highbit(o2 + 3)
                        gain1 = ml * 4 - highbit(offset + 3) + 7
                        if l2 >= 4 && gain2 > gain1
                            ml = l2; offset = o2; start = ip
                            continue
                        end
                    end
                    break
                end
            end
            # catch up: extend the match backwards
            if offset != rep1
                m = start - offset
                while start > anchor && m > lowp && unsafe_load(start - 1) == unsafe_load(m - 1)
                    start -= 1; m -= 1; ml += 1
                end
                rep2 = rep1; rep1 = offset
            end
            store_seq!(ss, anchor, Int(start - anchor), offset, ml)
            ip = start + ml
            anchor = ip
            # immediate repcode with rep2
            while ip <= ilimit && rep2 > 0 && pos_of(ip, base) - rep2 >= lowlimit &&
                  load32(ip) == load32(ip - rep2)
                rl = zcount(ip + 4, ip + 4 - rep2, iend) + 4
                rep1, rep2 = rep2, rep1
                store_seq!(ss, anchor, 0, rep1, rl)
                ip += rl
                anchor = ip
            end
        end
    end
    store_last_literals!(ss, anchor, Int(iend - anchor))
    return rep1, rep2, next
end

# ---------------------------------------------------------------------------
# Backward bit writer (BIT_CStream)
# ---------------------------------------------------------------------------

struct BitC
    bits::UInt64
    pos::Int
    ptr::Ptr{UInt8}
end
@inline bitc_add(b::BitC, v::Integer, n::Int) =
    BitC(b.bits | ((UInt64(v) & ((UInt64(1) << (n & 63)) - 1)) << (b.pos & 63)), b.pos + n, b.ptr)
@inline function bitc_flush(b::BitC)
    store64(b.ptr, b.bits)
    nb = b.pos >> 3
    return BitC(nb >= 8 ? UInt64(0) : (b.bits >> ((nb << 3) & 63)), b.pos & 7, b.ptr + nb)
end
@inline function bitc_close(b::BitC, start::Ptr{UInt8})
    b = bitc_flush(bitc_add(b, 1, 1))
    return Int(b.ptr - start) + (b.pos > 0 ? 1 : 0)
end

# ---------------------------------------------------------------------------
# FSE encoding
# ---------------------------------------------------------------------------

mutable struct FSECTable
    al::Int
    maxsym::Int
    norm::Vector{Int16}
    state::Vector{UInt16}
    dnb::Vector{Int32}       # deltaNbBits
    dfs::Vector{Int32}       # deltaFindState
end
FSECTable() = FSECTable(0, 0, zeros(Int16, 256), zeros(UInt16, 4096), zeros(Int32, 256), zeros(Int32, 256))

function build_ctable!(t::FSECTable, norm::AbstractVector{Int16}, maxsym::Int, al::Int,
                       tabsym::Vector{UInt8}, cumul::Vector{Int})
    tsize = 1 << al
    t.al = al
    t.maxsym = maxsym
    copyto!(t.norm, 1, norm, 1, maxsym + 1)
    length(t.state) < tsize && resize!(t.state, tsize)
    length(tabsym) < tsize && resize!(tabsym, tsize)
    high = tsize - 1
    cumul[1] = 0
    @inbounds for u in 1:maxsym+1
        if norm[u] == -1
            cumul[u + 1] = cumul[u] + 1
            tabsym[high + 1] = UInt8(u - 1)
            high -= 1
        else
            cumul[u + 1] = cumul[u] + max(Int(norm[u]), 0)
        end
    end
    step = (tsize >> 1) + (tsize >> 3) + 3
    mask = tsize - 1
    pos = 0
    @inbounds for s in 1:maxsym+1
        for _ in 1:Int(norm[s])
            tabsym[pos + 1] = UInt8(s - 1)
            pos = (pos + step) & mask
            while pos > high
                pos = (pos + step) & mask
            end
        end
    end
    @assert pos == 0
    @inbounds for u in 0:tsize-1
        s = Int(tabsym[u + 1]) + 1
        t.state[cumul[s] + 1] = UInt16(tsize + u)
        cumul[s] += 1
    end
    total = 0
    @inbounds for s in 1:maxsym+1
        p = Int(norm[s])
        if p == 0
            t.dnb[s] = Int32(((al + 1) << 16) - tsize)
        elseif p == -1 || p == 1
            t.dnb[s] = Int32((al << 16) - tsize)
            t.dfs[s] = Int32(total - 1)
            total += 1
        else
            maxbits = al - highbit(p - 1)
            minstate = p << maxbits
            t.dnb[s] = Int32((maxbits << 16) - minstate)
            t.dfs[s] = Int32(total - p)
            total += p
        end
    end
    return t
end

@inline function fse_init_state(t::FSECTable, sym::Int)
    @inbounds begin
        dnb = Int(t.dnb[sym + 1])
        nb = (dnb + (1 << 15)) >> 16
        v = (nb << 16) - dnb
        return Int(t.state[(v >> nb) + Int(t.dfs[sym + 1]) + 1])
    end
end

@inline function fse_encode(b::BitC, v::Int, t::FSECTable, sym::Int)
    @inbounds begin
        nb = (v + Int(t.dnb[sym + 1])) >> 16
        b = bitc_add(b, v, nb)
        return b, Int(t.state[(v >> nb) + Int(t.dfs[sym + 1]) + 1])
    end
end

@inline fse_flush_state(b::BitC, v::Int, t::FSECTable) = bitc_flush(bitc_add(b, v, t.al))

"""Choose an accuracy log (FSE_optimalTableLog)."""
function optimal_table_log(max_log::Int, total::Int, maxsym::Int)
    maxbits_src = highbit(total - 1) - 2
    minbits = min(highbit(total - 1) + 1, highbit(max(maxsym, 1)) + 2)
    tl = max_log
    maxbits_src < tl && (tl = maxbits_src)
    minbits > tl && (tl = minbits)
    return clamp(tl, 5, 12)
end

"""
Normalize `counts[1:maxsym+1]` (sum `total`, at least two nonzero) to sum to
`2^al`. Low-frequency symbols get the "less than 1" probability -1.
"""
function normalize_counts!(norm::Vector{Int16}, counts::Vector{Int}, total::Int, maxsym::Int, al::Int)
    tsize = 1 << al
    low = total >> al
    remaining = tsize
    largest = 0; largestp = 0
    @inbounds for s in 1:maxsym+1
        c = counts[s]
        if c == 0
            norm[s] = 0
        elseif c <= low
            norm[s] = -1
            remaining -= 1
        else
            p = max(1, round(Int, c * tsize / total, RoundDown))
            # round up when the fractional part is large (as the reference's rtbTable)
            frac = c * tsize / total - p
            if p < 8 && frac > 0.5
                p += 1
            end
            norm[s] = Int16(p)
            remaining -= p
            if p > largestp
                largestp = p; largest = s
            end
        end
    end
    if remaining == 0
        return norm
    end
    if remaining > 0 || -remaining < (largestp >> 1)
        norm[largest] += Int16(remaining)
        return norm
    end
    # Too much to take from the largest: shave the biggest probabilities one by one.
    while remaining < 0
        bi = 0; bp = 1
        @inbounds for s in 1:maxsym+1
            if norm[s] > bp
                bp = Int(norm[s]); bi = s
            end
        end
        bi == 0 && error("FSE normalization failed")
        norm[bi] -= Int16(1)
        remaining += 1
    end
    return norm
end

"""Write an FSE table description (normalized counts) at dst[pos]. Returns new pos."""
function write_fse_header!(dst::Vector{UInt8}, pos::Int, norm::Vector{Int16}, maxsym::Int, al::Int)
    bits = UInt64(0); nbits = 0
    @inline function put(bits, nbits, v, n)
        bits |= UInt64(v) << nbits
        nbits += n
        while nbits >= 8
            dst[pos] = bits % UInt8
            pos += 1
            bits >>= 8
            nbits -= 8
        end
        return bits, nbits
    end
    bits, nbits = put(bits, nbits, al - 5, 4)
    remaining = 1 << al
    s = 1
    @inbounds while remaining > 0 && s <= maxsym + 1
        prob = Int(norm[s])
        max_value = remaining + 1
        nb = 64 - leading_zeros(UInt64(max_value))
        lower = nb - 1
        threshold = (1 << nb) - max_value - 1
        val = prob + 1
        if val < threshold
            bits, nbits = put(bits, nbits, val, lower)
        elseif val < (1 << lower)
            bits, nbits = put(bits, nbits, val, nb)                    # top bit 0
        else
            bits, nbits = put(bits, nbits, val - (1 << lower) + threshold + (1 << lower), nb)
        end
        remaining -= prob == -1 ? 1 : prob
        s += 1
        if prob == 0
            run = 0
            while s <= maxsym + 1 && norm[s] == 0
                run += 1; s += 1
            end
            while true
                c = min(run, 3)
                bits, nbits = put(bits, nbits, c, 2)
                run -= c
                c < 3 && break
            end
        end
    end
    if nbits > 0
        dst[pos] = bits % UInt8
        pos += 1
    end
    return pos
end

"""Approximate cost in bits of coding `counts` with `norm` (Inf if a symbol is missing)."""
function fse_cost(counts::Vector{Int}, maxsym::Int, norm::AbstractVector{Int16}, nmax::Int, al::Int)
    cost = 0.0
    @inbounds for s in 1:maxsym+1
        c = counts[s]
        c == 0 && continue
        s > nmax + 1 && return Inf
        p = Int(norm[s])
        p == 0 && return Inf
        p == -1 && (p = 1)
        cost += c * (al - log2(p))
    end
    return cost
end

# ---------------------------------------------------------------------------
# Huffman encoding
# ---------------------------------------------------------------------------

mutable struct HufCTable
    maxsym::Int
    tl::Int
    nbits::Vector{UInt8}
    code::Vector{UInt16}
end
HufCTable() = HufCTable(-1, 0, zeros(UInt8, 256), zeros(UInt16, 256))

"""Code lengths for counts[1:maxsym+1] (Huffman), limited to `maxbits`."""
function huf_lengths!(lens::Vector{UInt8}, counts::Vector{Int}, maxsym::Int, maxbits::Int,
                      syms::Vector{Int}, freq::Vector{Int}, parent::Vector{Int})
    fill!(lens, 0x00)
    n = 0
    @inbounds for s in 1:maxsym+1
        if counts[s] > 0
            n += 1
            syms[n] = s
        end
    end
    sort!(view(syms, 1:n), by = s -> counts[s], alg = InsertionSort)
    # Two-queue Huffman construction. Nodes 1..n are leaves (sorted), n+1.. internal.
    @inbounds for i in 1:n
        freq[i] = counts[syms[i]]
    end
    leaf = 1; node = n + 1; nint = n
    @inbounds for _ in 1:n-1
        a = 0; b = 0
        for k in 1:2
            if leaf <= n && (node > nint || freq[leaf] <= freq[node])
                x = leaf; leaf += 1
            else
                x = node; node += 1
            end
            k == 1 ? (a = x) : (b = x)
        end
        nint += 1
        freq[nint] = freq[a] + freq[b]
        parent[a] = nint; parent[b] = nint
    end
    # depths: root = nint has depth 0
    depth = freq  # reuse storage
    @inbounds depth[nint] = 0
    @inbounds for i in nint-1:-1:1
        depth[i] = depth[parent[i]] + 1
    end
    lengths = zeros(Int, maxsym + 1)
    @inbounds for i in 1:n
        lengths[syms[i]] = depth[i]
    end
    limit_lengths!(lengths, maxbits)
    @inbounds for s in 1:maxsym+1
        lens[s] = UInt8(lengths[s])
    end
    return maximum(lengths)
end

"""Limit code lengths to `maxbits` while keeping the prefix code complete."""
function limit_lengths!(lengths::Vector{Int}, maxbits::Int)
    any(>(maxbits), lengths) || return lengths
    for i in eachindex(lengths)
        lengths[i] > maxbits && (lengths[i] = maxbits)
    end
    avail = 1 << maxbits
    used = sum(l > 0 ? 1 << (maxbits - l) : 0 for l in lengths)
    # Over-subscribed: lengthen the longest codes that are still below maxbits
    # (cheapest in expected bits for rare symbols).
    while used > avail
        bi = 0; bl = 0
        for i in eachindex(lengths)
            l = lengths[i]
            if 0 < l < maxbits && l > bl
                bl = l; bi = i
            end
        end
        bi == 0 && break
        used -= 1 << (maxbits - bl)
        lengths[bi] = bl + 1
        used += 1 << (maxbits - bl - 1)
    end
    # Under-subscribed: shorten the longest codes to fill the gap exactly.
    while used < avail
        gap = avail - used
        bi = 0; bl = 1
        for i in eachindex(lengths)
            l = lengths[i]
            if l > bl && (1 << (maxbits - l)) <= gap
                bl = l; bi = i
            end
        end
        bi == 0 && break
        used += 1 << (maxbits - bl)
        lengths[bi] = bl - 1
    end
    return lengths
end

"""Assign canonical codes (longest codes first, symbols ascending) as the decoder expects."""
function huf_codes!(t::HufCTable, lens::Vector{UInt8}, maxsym::Int, tl::Int)
    t.maxsym = maxsym
    t.tl = tl
    nper = zeros(Int, tl + 2)
    @inbounds for s in 1:maxsym+1
        l = Int(lens[s])
        l > 0 && (nper[l + 1] += 1)
    end
    valper = zeros(Int, tl + 2)
    v = 0
    @inbounds for l in tl:-1:1
        valper[l + 1] = v
        v += nper[l + 1]
        v >>= 1
    end
    @inbounds for s in 1:256
        l = s <= maxsym + 1 ? Int(lens[s]) : 0
        t.nbits[s] = UInt8(l)
        if l > 0
            t.code[s] = UInt16(valper[l + 1])
            valper[l + 1] += 1
        end
    end
    return t
end

"""Huffman-encode `src[0:n-1]` as one bitstream at dst. Returns compressed size."""
function huf_encode_stream(dst::Ptr{UInt8}, src::Ptr{UInt8}, n::Int, t::HufCTable)
    nbits = t.nbits; code = t.code
    b = BitC(UInt64(0), 0, dst)
    GC.@preserve nbits code begin
        nb = pointer(nbits); cd = pointer(code)
        i = n
        # Encode from the end; 4 symbols (<= 44 bits) per flush.
        r = n & 3
        while r > 0
            s = Int(unsafe_load(src, i)) + 1
            b = bitc_add(b, unsafe_load(cd, s), Int(unsafe_load(nb, s)))
            i -= 1; r -= 1
        end
        b = bitc_flush(b)
        while i > 0
            s = Int(unsafe_load(src, i)) + 1
            b = BitC(b.bits | (UInt64(unsafe_load(cd, s)) << (b.pos & 63)), b.pos + Int(unsafe_load(nb, s)), b.ptr)
            s = Int(unsafe_load(src, i - 1)) + 1
            b = BitC(b.bits | (UInt64(unsafe_load(cd, s)) << (b.pos & 63)), b.pos + Int(unsafe_load(nb, s)), b.ptr)
            s = Int(unsafe_load(src, i - 2)) + 1
            b = BitC(b.bits | (UInt64(unsafe_load(cd, s)) << (b.pos & 63)), b.pos + Int(unsafe_load(nb, s)), b.ptr)
            s = Int(unsafe_load(src, i - 3)) + 1
            b = BitC(b.bits | (UInt64(unsafe_load(cd, s)) << (b.pos & 63)), b.pos + Int(unsafe_load(nb, s)), b.ptr)
            b = bitc_flush(b)
            i -= 4
        end
    end
    return bitc_close(b, dst)
end

"""Estimated encoded size in bytes of the literals with table t (Inf if a symbol is missing)."""
function huf_cost(counts::Vector{Int}, maxsym::Int, t::HufCTable)
    t.maxsym < 0 && return typemax(Int)
    bits = 0
    @inbounds for s in 1:maxsym+1
        c = counts[s]
        c == 0 && continue
        (s > t.maxsym + 1 || t.nbits[s] == 0) && return typemax(Int)
        bits += c * Int(t.nbits[s])
    end
    return bits >> 3
end

# ---------------------------------------------------------------------------
# Compression context
# ---------------------------------------------------------------------------

"""
    CompressionContext()

Reusable compression state (match-finder tables, entropy tables, scratch
buffers). Not thread-safe; use one per task.
"""
mutable struct CompressionContext
    params::CParams
    level::Int
    htab::Vector{Int32}
    ctab::Vector{Int32}       # chain table (lazy) or short hash table (dfast)
    next_to_update::Int
    prep1::Int                # parser repeat-offset guesses
    prep2::Int
    rep::NTuple{3,Int}        # exact decoder repeat offsets
    ss::SeqStore
    # sequence coding scratch
    llc::Vector{UInt8}
    mlc::Vector{UInt8}
    ofc::Vector{UInt8}
    ofv::Vector{UInt32}
    counts::Vector{Int}
    norm::Vector{Int16}
    tabsym::Vector{UInt8}
    cumul::Vector{Int}
    # entropy tables: current and previous-block (for repeat modes)
    ll_t::FSECTable; ml_t::FSECTable; of_t::FSECTable
    ll_prev::FSECTable; ml_prev::FSECTable; of_prev::FSECTable
    ll_prev_ok::Bool; ml_prev_ok::Bool; of_prev_ok::Bool
    ll_def::FSECTable; ml_def::FSECTable; of_def::FSECTable
    huf::HufCTable
    huf_prev::HufCTable
    huf_prev_ok::Bool
    lens::Vector{UInt8}
    hsyms::Vector{Int}; hfreq::Vector{Int}; hparent::Vector{Int}
    wnorm::Vector{Int16}; wt::FSECTable; wcounts::Vector{Int}; weights::Vector{UInt8}
    # output scratch
    blk::Vector{UInt8}
    tmp::Vector{UInt8}
end

function default_ctable(norm, al, tabsym, cumul)
    t = FSECTable()
    build_ctable!(t, norm, length(norm) - 1, al, tabsym, cumul)
    return t
end

function CompressionContext()
    tabsym = zeros(UInt8, 4096); cumul = zeros(Int, 258)
    CompressionContext(LEVEL_TABLE[4], 3, Int32[], Int32[], 1, 1, 4, (1, 4, 8), SeqStore(),
        zeros(UInt8, BLOCK_SIZE_MAX ÷ 3 + 2), zeros(UInt8, BLOCK_SIZE_MAX ÷ 3 + 2),
        zeros(UInt8, BLOCK_SIZE_MAX ÷ 3 + 2), zeros(UInt32, BLOCK_SIZE_MAX ÷ 3 + 2),
        zeros(Int, 256), zeros(Int16, 256), tabsym, cumul,
        FSECTable(), FSECTable(), FSECTable(), FSECTable(), FSECTable(), FSECTable(),
        false, false, false,
        default_ctable(LL_DEFAULT_NORM, 6, tabsym, cumul),
        default_ctable(ML_DEFAULT_NORM, 6, tabsym, cumul),
        default_ctable(OF_DEFAULT_NORM, 5, tabsym, cumul),
        HufCTable(), HufCTable(), false,
        zeros(UInt8, 256), zeros(Int, 256), zeros(Int, 512), zeros(Int, 512),
        zeros(Int16, 16), FSECTable(), zeros(Int, 16), zeros(UInt8, 256),
        zeros(UInt8, 1024), zeros(UInt8, 1024))
end

function reset_context!(cc::CompressionContext, p::CParams, level::Int)
    cc.params = p
    cc.level = level
    hsize = 1 << p.hash_log
    length(cc.htab) != hsize && resize!(cc.htab, hsize)
    fill!(cc.htab, Int32(0))
    if p.strategy == S_DFAST || p.strategy >= S_GREEDY
        csize = 1 << p.chain_log
        length(cc.ctab) != csize && resize!(cc.ctab, csize)
        fill!(cc.ctab, Int32(0))
    end
    cc.next_to_update = 1
    cc.prep1, cc.prep2 = 1, 4
    cc.rep = (1, 4, 8)
    cc.ll_prev_ok = cc.ml_prev_ok = cc.of_prev_ok = false
    cc.huf_prev_ok = false
    return cc
end

# ---------------------------------------------------------------------------
# Literals section
# ---------------------------------------------------------------------------

function write_raw_literals!(dst::Vector{UInt8}, pos::Int, src::Ptr{UInt8}, n::Int)
    if n < 32
        dst[pos] = UInt8(n << 3); pos += 1
    elseif n < 4096
        dst[pos] = UInt8(0x04 | ((n & 0x0F) << 4)); dst[pos+1] = UInt8(n >> 4); pos += 2
    else
        dst[pos] = UInt8(0x0C | ((n & 0x0F) << 4)); dst[pos+1] = UInt8((n >> 4) & 0xFF)
        dst[pos+2] = UInt8(n >> 12); pos += 3
    end
    GC.@preserve dst unsafe_copyto!(pointer(dst, pos), src, n)
    return pos + n
end

function write_rle_literals!(dst::Vector{UInt8}, pos::Int, byte::UInt8, n::Int)
    if n < 32
        dst[pos] = UInt8(0x01 | (n << 3)); pos += 1
    elseif n < 4096
        dst[pos] = UInt8(0x05 | ((n & 0x0F) << 4)); dst[pos+1] = UInt8(n >> 4); pos += 2
    else
        dst[pos] = UInt8(0x0D | ((n & 0x0F) << 4)); dst[pos+1] = UInt8((n >> 4) & 0xFF)
        dst[pos+2] = UInt8(n >> 12); pos += 3
    end
    dst[pos] = byte
    return pos + 1
end

"""Write the Huffman tree description for `t` to dst[pos]. Returns new pos, or 0 if not representable."""
function write_huf_tree!(cc::CompressionContext, dst::Vector{UInt8}, pos::Int, t::HufCTable)
    maxsym = t.maxsym
    tl = t.tl
    ws = cc.weights
    nw = maxsym     # weights for symbols 0..maxsym-1; the last one is implied
    @inbounds for s in 1:nw
        l = Int(t.nbits[s])
        ws[s] = l == 0 ? 0x00 : UInt8(tl + 1 - l)
    end
    # Try FSE-compressed weights
    wc = cc.wcounts
    fill!(wc, 0)
    maxw = 0
    @inbounds for s in 1:nw
        w = Int(ws[s]); wc[w + 1] += 1; maxw = max(maxw, w)
    end
    fse_pos = 0
    if nw >= 2 && maximum(view(wc, 1:maxw+1)) < nw && maximum(view(wc, 1:maxw+1)) > 1
        al = optimal_table_log(6, nw, maxw)
        normalize_counts!(cc.wnorm, wc, nw, maxw, al)
        build_ctable!(cc.wt, cc.wnorm, maxw, al, cc.tabsym, cc.cumul)
        start = pos
        hp = write_fse_header!(dst, pos + 1, cc.wnorm, maxw, al)
        # two interleaved states, encoded backwards
        GC.@preserve dst begin
            p0 = pointer(dst, hp)
            b = BitC(UInt64(0), 0, p0)
            wt = cc.wt
            i = nw
            if isodd(nw)
                s1 = fse_init_state(wt, Int(ws[i])); i -= 1
                s2 = fse_init_state(wt, Int(ws[i])); i -= 1
                b, s1 = fse_encode(b, s1, wt, Int(ws[i])); i -= 1
                b = bitc_flush(b)
            else
                s2 = fse_init_state(wt, Int(ws[i])); i -= 1
                s1 = fse_init_state(wt, Int(ws[i])); i -= 1
            end
            while i > 0
                b, s2 = fse_encode(b, s2, wt, Int(ws[i])); i -= 1
                b, s1 = fse_encode(b, s1, wt, Int(ws[i])); i -= 1
                b = bitc_flush(b)
            end
            b = fse_flush_state(b, s2, wt)
            b = fse_flush_state(b, s1, wt)
            sz = bitc_close(b, p0)
        end
        csize = hp - start - 1 + sz
        if csize < 128 && (maxsym > 128 || csize < (nw + 1) >> 1)
            dst[start] = UInt8(csize)
            fse_pos = start + 1 + csize
        end
    end
    fse_pos > 0 && return fse_pos
    maxsym > 128 && return 0
    dst[pos] = UInt8(127 + nw); pos += 1
    @inbounds for i in 1:2:nw
        hi = ws[i]
        lo = i + 1 <= nw ? ws[i + 1] : 0x00
        dst[pos] = (hi << 4) | lo; pos += 1
    end
    return pos
end

function write_compressed_lit_header!(dst::Vector{UInt8}, pos::Int, ltype::Int, single::Bool,
                                      regen::Int, csize::Int)
    if single || (regen < 1024 && csize < 1024)
        sf = single ? 0 : 1
        h = ltype | (sf << 2) | (regen << 4) | (csize << 14)
        dst[pos] = h % UInt8; dst[pos+1] = (h >> 8) % UInt8; dst[pos+2] = (h >> 16) % UInt8
        return pos + 3
    elseif regen < 16384 && csize < 16384
        h = ltype | (2 << 2) | (regen << 4) | (csize << 18)
        for k in 0:3; dst[pos+k] = (h >> (8k)) % UInt8; end
        return pos + 4
    else
        h = ltype | (3 << 2) | (regen << 4) | (csize << 22)
        for k in 0:4; dst[pos+k] = (h >> (8k)) % UInt8; end
        return pos + 5
    end
end

"""Encode literals into dst[pos]. Returns new pos."""
function encode_literals!(cc::CompressionContext, dst::Vector{UInt8}, pos::Int, lit::Vector{UInt8}, n::Int)
    GC.@preserve lit begin
        lp = pointer(lit)
        # Very small literal runs are not worth a table.
        if n <= 63 && !cc.huf_prev_ok
            n > 0 && all(==(lit[1]), view(lit, 1:n)) && n > 2 && return write_rle_literals!(dst, pos, lit[1], n)
            return write_raw_literals!(dst, pos, lp, n)
        end
        n == 0 && return write_raw_literals!(dst, pos, lp, 0)
        counts = cc.counts
        fill!(counts, 0)
        @inbounds for i in 1:n
            counts[Int(lit[i]) + 1] += 1
        end
        maxsym = 255
        while counts[maxsym + 1] == 0; maxsym -= 1; end
        largest = maximum(counts)
        largest == n && return write_rle_literals!(dst, pos, lit[1], n)
        largest <= (n >> 7) + 4 && return write_raw_literals!(dst, pos, lp, n)
        min_gain = (n >> 6) + 2
        single = n < 256
        hs = single || n < 1024 ? 3 : (n < 16384 ? 4 : 5)
        # Option A: reuse previous table (treeless)
        reuse_cost = cc.huf_prev_ok ? huf_cost(counts, maxsym, cc.huf_prev) : typemax(Int)
        # Option B: new table
        tl = huf_lengths!(cc.lens, counts, maxsym, HUF_MAX_BITS, cc.hsyms, cc.hfreq, cc.hparent)
        huf_codes!(cc.huf, cc.lens, maxsym, tl)
        new_cost = huf_cost(counts, maxsym, cc.huf)
        tmp = cc.tmp
        # Huffman output can exceed n (codes up to 11 bits) before the raw fallback.
        length(tmp) < (11n >> 3) + 1024 && resize!(tmp, (11n >> 3) + 1024)
        treeless = reuse_cost < typemax(Int) && reuse_cost <= new_cost + 40 + (maxsym >> 1)
        t = treeless ? cc.huf_prev : cc.huf
        tpos = 1
        if !treeless
            tpos = write_huf_tree!(cc, tmp, 1, t)
            tpos == 0 && return write_raw_literals!(dst, pos, lp, n)
        end
        GC.@preserve tmp begin
            q = pointer(tmp)
            if single
                sz = huf_encode_stream(q + tpos - 1, lp, n, t)
                tpos += sz
            else
                seg = (n + 3) >> 2
                jt = tpos
                tpos += 6
                s1 = huf_encode_stream(q + tpos - 1, lp, seg, t); tpos += s1
                s2 = huf_encode_stream(q + tpos - 1, lp + seg, seg, t); tpos += s2
                s3 = huf_encode_stream(q + tpos - 1, lp + 2seg, seg, t); tpos += s3
                s4 = huf_encode_stream(q + tpos - 1, lp + 3seg, n - 3seg, t); tpos += s4
                (s1 > 0xFFFF || s2 > 0xFFFF || s3 > 0xFFFF) && return write_raw_literals!(dst, pos, lp, n)
                tmp[jt] = s1 % UInt8; tmp[jt+1] = (s1 >> 8) % UInt8
                tmp[jt+2] = s2 % UInt8; tmp[jt+3] = (s2 >> 8) % UInt8
                tmp[jt+4] = s3 % UInt8; tmp[jt+5] = (s3 >> 8) % UInt8
            end
        end
        csize = tpos - 1
        if csize >= n - min_gain || csize >= (1 << 18)
            return write_raw_literals!(dst, pos, lp, n)
        end
        pos = write_compressed_lit_header!(dst, pos, treeless ? 3 : 2, single, n, csize)
        copyto!(dst, pos, tmp, 1, csize)
        if !treeless
            # this table becomes the reference for the next block
            cc.huf, cc.huf_prev = cc.huf_prev, cc.huf
            cc.huf_prev_ok = true
        end
        return pos + csize
    end
end

# ---------------------------------------------------------------------------
# Sequences section
# ---------------------------------------------------------------------------

const LL_CODE = UInt8[searchsortedlast(LL_BASE, i) - 1 for i in 0:63]
const ML_CODE = UInt8[searchsortedlast(ML_BASE, i + 3) - 1 for i in 0:127]

@inline ll_code(ll::Int) = ll < 64 ? Int(@inbounds LL_CODE[ll + 1]) : highbit(ll) + 19
@inline ml_code(mlbase::Int) = mlbase < 128 ? Int(@inbounds ML_CODE[mlbase + 1]) : highbit(mlbase) + 36

const MODE_PREDEF = 0
const MODE_RLE = 1
const MODE_FSE = 2
const MODE_REPEAT = 3

"""Pick the coding mode for one sequence field and prepare its CTable."""
function select_mode!(cc::CompressionContext, codes::Vector{UInt8}, nseq::Int, maxcode::Int,
                      max_al::Int, cur::FSECTable, prev::FSECTable, prev_ok::Bool,
                      def::FSECTable, def_al::Int, dst::Vector{UInt8}, pos::Int)
    counts = cc.counts
    fill!(view(counts, 1:maxcode+1), 0)
    @inbounds for i in 1:nseq
        counts[Int(codes[i]) + 1] += 1
    end
    maxsym = maxcode
    while maxsym > 0 && counts[maxsym + 1] == 0; maxsym -= 1; end
    largest = maximum(view(counts, 1:maxsym+1))
    if largest == nseq
        dst[pos] = UInt8(maxsym)
        rle = cur
        rle.al = 0
        rle.maxsym = maxsym
        return MODE_RLE, rle, pos + 1
    end
    predef_cost = fse_cost(counts, maxsym, def.norm, def.maxsym, def_al)
    repeat_cost = prev_ok ? fse_cost(counts, maxsym, prev.norm, prev.maxsym, prev.al) : Inf
    fse_c = Inf
    al = 0
    if nseq >= 8
        al = optimal_table_log(max_al, nseq, maxsym)
        normalize_counts!(cc.norm, counts, nseq, maxsym, al)
        hdr = write_fse_header!(cc.tmp, 1, cc.norm, maxsym, al) - 1
        fse_c = fse_cost(counts, maxsym, cc.norm, maxsym, al) + 8 * hdr
    end
    best = min(predef_cost, repeat_cost, fse_c)
    if best == fse_c && fse_c < Inf
        build_ctable!(cur, cc.norm, maxsym, al, cc.tabsym, cc.cumul)
        pos = write_fse_header!(dst, pos, cc.norm, maxsym, al)
        return MODE_FSE, cur, pos
    elseif best == repeat_cost && repeat_cost < predef_cost
        return MODE_REPEAT, prev, pos
    else
        return MODE_PREDEF, def, pos
    end
end

"""Encode the sequences section into dst[pos]. Returns new pos."""
function encode_sequences!(cc::CompressionContext, dst::Vector{UInt8}, pos::Int)
    ss = cc.ss
    nseq = ss.nseq
    if nseq < 128
        dst[pos] = UInt8(nseq); pos += 1
    elseif nseq < 0x7F00
        dst[pos] = UInt8((nseq >> 8) + 128); dst[pos+1] = UInt8(nseq & 0xFF); pos += 2
    else
        dst[pos] = 0xFF; v = nseq - 0x7F00
        dst[pos+1] = UInt8(v & 0xFF); dst[pos+2] = UInt8(v >> 8); pos += 3
    end
    nseq == 0 && return pos
    # Compute codes and offset values (tracking the decoder's repeat offsets)
    r1, r2, r3 = cc.rep
    llc = cc.llc; mlc = cc.mlc; ofc = cc.ofc; ofv = cc.ofv
    @inbounds for i in 1:nseq
        ll = Int(ss.ll[i]); off = Int(ss.off[i])
        llc[i] = UInt8(ll_code(ll))
        mlc[i] = UInt8(ml_code(Int(ss.ml[i]) - MIN_MATCH))
        if ll > 0
            v = off == r1 ? 1 : off == r2 ? 2 : off == r3 ? 3 : off + 3
        else
            v = off == r2 ? 1 : off == r3 ? 2 : off == r1 - 1 ? 3 : off + 3
        end
        # update repeat offsets exactly as the decoder will
        if v > 3
            r3 = r2; r2 = r1; r1 = off
        else
            idx = v + (ll == 0)
            if idx == 2
                r2 = r1; r1 = off
            elseif idx == 3
                r3 = r2; r2 = r1; r1 = off
            elseif idx == 4
                r3 = r2; r2 = r1; r1 = off
            end
        end
        ofv[i] = UInt32(v)
        ofc[i] = UInt8(highbit(v))
    end
    cc.rep = (r1, r2, r3)
    modes_pos = pos
    pos += 1
    llm, llt, pos = select_mode!(cc, llc, nseq, 35, LL_MAX_AL, cc.ll_t, cc.ll_prev, cc.ll_prev_ok, cc.ll_def, 6, dst, pos)
    ofm, oft, pos = select_mode!(cc, ofc, nseq, 31, OF_MAX_AL, cc.of_t, cc.of_prev, cc.of_prev_ok, cc.of_def, 5, dst, pos)
    mlm, mlt, pos = select_mode!(cc, mlc, nseq, 52, ML_MAX_AL, cc.ml_t, cc.ml_prev, cc.ml_prev_ok, cc.ml_def, 6, dst, pos)
    dst[modes_pos] = UInt8((llm << 6) | (ofm << 4) | (mlm << 2))
    # Bitstream (sequences encoded last to first)
    need = pos + 16 * nseq + 64
    length(dst) < need && resize!(dst, need)
    GC.@preserve dst ss llt oft mlt begin
        start = pointer(dst, pos)
        b = BitC(UInt64(0), 0, start)
        n = nseq
        llrle = llm == MODE_RLE; mlrle = mlm == MODE_RLE; ofrle = ofm == MODE_RLE
        @inbounds begin
            sml = mlrle ? 0 : fse_init_state(mlt, Int(mlc[n]))
            sof = ofrle ? 0 : fse_init_state(oft, Int(ofc[n]))
            sll = llrle ? 0 : fse_init_state(llt, Int(llc[n]))
            lc = Int(llc[n]); mc = Int(mlc[n]); oc = Int(ofc[n])
            b = bitc_add(b, Int(ss.ll[n]) - Int(LL_BASE[lc + 1]), Int(LL_BITS[lc + 1]))
            b = bitc_add(b, Int(ss.ml[n]) - Int(ML_BASE[mc + 1]), Int(ML_BITS[mc + 1]))
            b = bitc_flush(b)
            b = bitc_add(b, ofv[n], oc)
            b = bitc_flush(b)
            for i in n-1:-1:1
                lc = Int(llc[i]); mc = Int(mlc[i]); oc = Int(ofc[i])
                ofrle || ((b, sof) = fse_encode(b, sof, oft, oc))
                mlrle || ((b, sml) = fse_encode(b, sml, mlt, mc))
                llrle || ((b, sll) = fse_encode(b, sll, llt, lc))
                b = bitc_flush(b)
                b = bitc_add(b, Int(ss.ll[i]) - Int(LL_BASE[lc + 1]), Int(LL_BITS[lc + 1]))
                b = bitc_add(b, Int(ss.ml[i]) - Int(ML_BASE[mc + 1]), Int(ML_BITS[mc + 1]))
                b = bitc_flush(b)
                b = bitc_add(b, ofv[i], oc)
                b = bitc_flush(b)
            end
            mlrle || (b = fse_flush_state(b, sml, mlt))
            ofrle || (b = fse_flush_state(b, sof, oft))
            llrle || (b = fse_flush_state(b, sll, llt))
        end
        sz = bitc_close(b, start)
    end
    # Tables used now become the "previous" tables for repeat mode.
    llm == MODE_FSE && ((cc.ll_t, cc.ll_prev) = (cc.ll_prev, cc.ll_t); cc.ll_prev_ok = true)
    ofm == MODE_FSE && ((cc.of_t, cc.of_prev) = (cc.of_prev, cc.of_t); cc.of_prev_ok = true)
    mlm == MODE_FSE && ((cc.ml_t, cc.ml_prev) = (cc.ml_prev, cc.ml_t); cc.ml_prev_ok = true)
    llm == MODE_PREDEF && (copy_ctable!(cc.ll_prev, cc.ll_def); cc.ll_prev_ok = true)
    ofm == MODE_PREDEF && (copy_ctable!(cc.of_prev, cc.of_def); cc.of_prev_ok = true)
    mlm == MODE_PREDEF && (copy_ctable!(cc.ml_prev, cc.ml_def); cc.ml_prev_ok = true)
    llm == MODE_RLE && (cc.ll_prev_ok = false)
    ofm == MODE_RLE && (cc.of_prev_ok = false)
    mlm == MODE_RLE && (cc.ml_prev_ok = false)
    return pos + sz
end

function copy_ctable!(dst::FSECTable, src::FSECTable)
    dst.al = src.al; dst.maxsym = src.maxsym
    copyto!(dst.norm, src.norm)
    length(dst.state) < length(src.state) && resize!(dst.state, length(src.state))
    copyto!(dst.state, 1, src.state, 1, 1 << src.al)
    copyto!(dst.dnb, src.dnb); copyto!(dst.dfs, src.dfs)
    return dst
end

# ---------------------------------------------------------------------------
# Blocks and frames
# ---------------------------------------------------------------------------

struct EntropySnapshot
    rep::NTuple{3,Int}
    ll_ok::Bool; ml_ok::Bool; of_ok::Bool; huf_ok::Bool
end

function write_block_header!(out::Vector{UInt8}, pos::Int, last::Bool, btype::Int, size::Int)
    h = Int(last) | (btype << 1) | (size << 3)
    out[pos] = h % UInt8; out[pos+1] = (h >> 8) % UInt8; out[pos+2] = (h >> 16) % UInt8
    return pos + 3
end

function parse_block!(cc::CompressionContext, base::Ptr{UInt8}, bstart::Ptr{UInt8}, bend::Ptr{UInt8})
    p = cc.params
    ss = cc.ss
    ss.nlit = 0; ss.nseq = 0
    window = 1 << p.window_log
    lowlimit = max(1, pos_of(bend, base) - window)
    n = Int(bend - bstart)
    if n < HASH_READ_SIZE + 4
        store_last_literals!(ss, bstart, n)
        return
    end
    mls = clamp(p.min_match, 4, 7)
    if p.strategy == S_FAST
        step = p.target_length + 1
        cc.prep1, cc.prep2 = parse_fast!(ss, cc.htab, p.hash_log, mls, step, base, bstart, bend,
                                         lowlimit, cc.prep1, cc.prep2)
    elseif p.strategy == S_DFAST
        cc.prep1, cc.prep2 = parse_dfast!(ss, cc.htab, p.hash_log, cc.ctab, p.chain_log, mls,
                                          base, bstart, bend, lowlimit, cc.prep1, cc.prep2)
    else
        depth = p.strategy == S_GREEDY ? 0 : p.strategy == S_LAZY ? 1 : 2
        mls = clamp(p.min_match, 4, 6)
        cc.next_to_update = max(cc.next_to_update, lowlimit)
        cc.prep1, cc.prep2, cc.next_to_update = parse_lazy!(ss, cc.htab, p.hash_log, cc.ctab,
            p.chain_log, mls, 1 << p.search_log, depth, max(p.target_length, 4), base, bstart, bend,
            lowlimit, cc.prep1, cc.prep2, cc.next_to_update)
    end
    return
end

"""Compress one block into out[pos]. Returns new pos."""
function compress_block!(cc::CompressionContext, out::Vector{UInt8}, pos::Int, base::Ptr{UInt8},
                         bstart::Ptr{UInt8}, bend::Ptr{UInt8}, last::Bool)
    n = Int(bend - bstart)
    # RLE block
    if n > 0
        b0 = unsafe_load(bstart)
        isrle = true
        for i in 1:n-1
            if unsafe_load(bstart, i + 1) != b0
                isrle = false; break
            end
        end
        if isrle && n > 3
            pos = write_block_header!(out, pos, last, 1, n)
            out[pos] = b0
            # keep the match finder's view consistent
            parse_block!(cc, base, bstart, bend)
            return pos + 1
        end
    end
    parse_block!(cc, base, bstart, bend)
    snap = EntropySnapshot(cc.rep, cc.ll_prev_ok, cc.ml_prev_ok, cc.of_prev_ok, cc.huf_prev_ok)
    blk = cc.blk
    need = 2n + 1024
    length(blk) < need && resize!(blk, need)
    q = encode_literals!(cc, blk, 1, cc.ss.lit, cc.ss.nlit)
    q = encode_sequences!(cc, blk, q)
    csize = q - 1
    if csize >= n || csize > BLOCK_SIZE_MAX
        # raw block; the decoder's entropy state does not change
        cc.rep = snap.rep
        cc.ll_prev_ok = snap.ll_ok; cc.ml_prev_ok = snap.ml_ok; cc.of_prev_ok = snap.of_ok
        cc.huf_prev_ok = snap.huf_ok
        # A table swapped in during this block is no longer known to the decoder.
        cc.huf_prev_ok = false; cc.ll_prev_ok = false; cc.ml_prev_ok = false; cc.of_prev_ok = false
        pos = write_block_header!(out, pos, last, 0, n)
        GC.@preserve out unsafe_copyto!(pointer(out, pos), bstart, n)
        return pos + n
    end
    pos = write_block_header!(out, pos, last, 2, csize)
    copyto!(out, pos, blk, 1, csize)
    return pos + csize
end

function write_frame_header!(out::Vector{UInt8}, pos::Int, src_size::Int, window_log::Int, checksum::Bool)
    for k in 0:3
        out[pos + k] = (MAGIC_NUMBER >> (8k)) % UInt8
    end
    pos += 4
    window = 1 << window_log
    single = src_size <= window
    fcs_code = src_size < 256 ? 0 : src_size < 65536 + 256 ? 1 : src_size <= 0xFFFFFFFF ? 2 : 3
    (fcs_code == 0 && !single) && (fcs_code = 1)
    fd = (fcs_code << 6) | (Int(single) << 5) | (Int(checksum) << 2)
    out[pos] = UInt8(fd); pos += 1
    if !single
        out[pos] = UInt8((window_log - 10) << 3); pos += 1
    end
    v = fcs_code == 1 ? src_size - 256 : src_size
    nb = (1, 2, 4, 8)[fcs_code + 1]
    for k in 0:nb-1
        out[pos + k] = (v >> (8k)) % UInt8
    end
    return pos + nb
end

"""
    compress_frame!(cc, data, level; checksum=false) -> Vector{UInt8}

Compress `data` as a single Zstandard frame.
"""
function compress_frame!(cc::CompressionContext, data::AbstractVector{UInt8}, level::Integer;
                         checksum::Bool=false)
    src = data isa Vector{UInt8} ? data : Vector{UInt8}(data)
    n = length(src)
    p = compression_parameters(level, n)
    reset_context!(cc, p, Int(level))
    bound = n + (n >> 7) + 64 + 3 * (n ÷ BLOCK_SIZE_MAX + 1)
    out = Vector{UInt8}(undef, bound)
    pos = write_frame_header!(out, 1, n, p.window_log, checksum)
    GC.@preserve src begin
        base = pointer(src)
        if n == 0
            pos = write_block_header!(out, pos, true, 0, 0)
        else
            off = 0
            while off < n
                bn = min(BLOCK_SIZE_MAX, n - off)
                last = off + bn == n
                length(out) < pos + bn + 16 && resize!(out, pos + bn + 1024)
                pos = compress_block!(cc, out, pos, base, base + off, base + off + bn, last)
                off += bn
            end
        end
    end
    if checksum
        h = xxh64(src) % UInt32
        length(out) < pos + 4 && resize!(out, pos + 4)
        for k in 0:3
            out[pos + k] = (h >> (8k)) % UInt8
        end
        pos += 4
    end
    resize!(out, pos - 1)
    return out
end

end # module
