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

using ..XXHash: xxh64, content_checksum, ChecksumState, checksum_update!, checksum_digest
import ..Decoder: LL_BASE, LL_BITS, ML_BASE, ML_BITS, LL_DEFAULT_NORM, ML_DEFAULT_NORM,
                  OF_DEFAULT_NORM, MAGIC_NUMBER, BLOCK_SIZE_MAX, ZstdDictionary, has_entropy

export CompressionContext, compress_frame!, compression_parameters, MIN_LEVEL, MAX_LEVEL,
       StreamCompressor, stream_write!, stream_flush!, stream_finish!, stream_pledge!,
       PreparedDictionary, prepare_dictionary, ParameterOverrides, parameter_overrides, NO_OVERRIDES

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

@enum Strategy S_FAST S_DFAST S_GREEDY S_LAZY S_LAZY2 S_BTLAZY2 S_BTOPT S_BTULTRA S_BTULTRA2

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
# As libzstd 1.5.7: levels 13-15 use btlazy2, 16-17 the optimal parser with
# whole-bit pricing (btopt), 18 the full optimal parser (btultra), 19-22
# btultra2 (btultra with statistics seeded by a first pass).
# Greedy/lazy levels find matches with libzstd's row-based match finder (rows
# of 2^clamp(searchLog, 4, 6) entries; chainLog is unused); btlazy2 and the
# optimal parser use a binary tree of 2^(chainLog-1) positions. For the optimal
# parser, targetLength is the "sufficient" match length. Level 16 hashes 4
# bytes rather than libzstd's 5 (slightly better ratio at a similar speed).
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
    CParams(22, 22, 22, 4, 5, 32, S_BTLAZY2), # 13
    CParams(22, 22, 23, 5, 5, 32, S_BTLAZY2), # 14
    CParams(22, 23, 23, 6, 5, 32, S_BTLAZY2), # 15
    CParams(22, 22, 22, 5, 4, 48, S_BTOPT),   # 16
    CParams(23, 23, 22, 6, 4, 64, S_BTOPT),   # 17
    CParams(23, 23, 22, 6, 3, 64, S_BTULTRA), # 18
    CParams(23, 24, 22, 7, 3, 256, S_BTULTRA2),# 19
    CParams(25, 25, 23, 7, 3, 256, S_BTULTRA2),# 20
    CParams(26, 26, 24, 7, 3, 512, S_BTULTRA2),# 21
    CParams(27, 27, 25, 9, 3, 999, S_BTULTRA2),# 22
]

"""
    ParameterOverrides

Explicit compression parameters replacing a level's defaults (`-1` = unset).
Build with [`parameter_overrides`](@ref).
"""
struct ParameterOverrides
    window_log::Int
    chain_log::Int
    hash_log::Int
    search_log::Int
    min_match::Int
    target_length::Int
    strategy::Int        # Int(Strategy) or -1
end

const NO_OVERRIDES = ParameterOverrides(-1, -1, -1, -1, -1, -1, -1)

# libzstd strategy names
const STRATEGY_NAMES = Dict(:fast => S_FAST, :dfast => S_DFAST, :greedy => S_GREEDY,
                            :lazy => S_LAZY, :lazy2 => S_LAZY2, :btlazy2 => S_BTLAZY2,
                            :btopt => S_BTOPT, :btultra => S_BTULTRA, :btultra2 => S_BTULTRA2)

function checked_param(name::Symbol, v, lo::Int, hi::Int)
    v === nothing && return -1
    v isa Integer || throw(ArgumentError("$name must be an integer"))
    lo <= v <= hi || throw(ArgumentError("$name = $v is outside $lo:$hi"))
    return Int(v)
end

"""
    parameter_overrides(; window_log, hash_log, chain_log, search_log, min_match,
                          target_length, strategy) -> ParameterOverrides

Validate explicit compression parameters (each `nothing` = the level's value),
with the meaning of libzstd's `ZSTD_c_*` parameters:

- `window_log` (10-30): log2 of the maximum match distance (window size)
- `hash_log` (6-27): log2 of the main hash table size
- `chain_log` (6-28): log2 of the chain / secondary table size (unused by the
  greedy and lazy strategies, whose row-based match finder sizes rows from
  `search_log`, as in libzstd)
- `search_log` (1-26): log2 of the number of match candidates searched
- `min_match` (3-7): minimum match length searched for (the match finders
  use 4-7 for fast/dfast, 4-6 for greedy/lazy, 3-4 for btopt/btultra)
- `target_length` (0-131072): for fast, a step size (acceleration); for
  btopt/btultra, a length taken without optimizing (unused by greedy/lazy,
  as in libzstd)
- `strategy`: `:fast`, `:dfast`, `:greedy`, `:lazy`, `:lazy2`, `:btlazy2`,
  `:btopt`, `:btultra` or `:btultra2` (libzstd's strategies)

Parameters are adapted to the input size afterwards, as in libzstd (e.g.
the window shrinks for small inputs).
"""
function parameter_overrides(; window_log=nothing, hash_log=nothing, chain_log=nothing,
                             search_log=nothing, min_match=nothing, target_length=nothing,
                             strategy=nothing)
    st = -1
    if strategy !== nothing
        haskey(STRATEGY_NAMES, strategy) ||
            throw(ArgumentError("unknown strategy $(repr(strategy)); use one of " *
                                join(repr.(sort(collect(keys(STRATEGY_NAMES)))), ", ")))
        st = Int(STRATEGY_NAMES[strategy])
    end
    ParameterOverrides(checked_param(:window_log, window_log, 10, 30),
                       checked_param(:chain_log, chain_log, 6, 28),
                       checked_param(:hash_log, hash_log, 6, 27),
                       checked_param(:search_log, search_log, 1, 26),
                       checked_param(:min_match, min_match, 3, 7),
                       checked_param(:target_length, target_length, 0, 1 << 17), st)
end

pick(v::Int, default) = v >= 0 ? v : default

apply_overrides(p::CParams, ov::ParameterOverrides) =
    ov === NO_OVERRIDES ? p :
    CParams(pick(ov.window_log, p.window_log), pick(ov.chain_log, p.chain_log),
            pick(ov.hash_log, p.hash_log), pick(ov.search_log, p.search_log),
            pick(ov.min_match, p.min_match), pick(ov.target_length, p.target_length),
            ov.strategy >= 0 ? Strategy(ov.strategy) : p.strategy)

"""Block size for parameters `p`: RFC 8878 limits blocks to
`Block_Maximum_Size = min(Window_Size, 128 KiB)`."""
block_size(p::CParams) = min(BLOCK_SIZE_MAX, 1 << p.window_log)

"""
    compression_parameters(level, src_size[, overrides]) -> CParams

Parameters for `level`, shrunk for small inputs as the reference
implementation does (smaller tables for small data are faster and lose
nothing).
"""
function compression_parameters(level::Integer, src_size::Integer,
                                ov::ParameterOverrides=NO_OVERRIDES)
    level = clamp(level, MIN_LEVEL, MAX_LEVEL)
    level == 0 && (level = 3)
    p = level < 0 ? LEVEL_TABLE[1] : LEVEL_TABLE[level + 1]
    target = level < 0 ? -level : p.target_length
    # explicit parameters replace the level's, then everything is adapted to
    # the input size (as ZSTD_getCParamsFromCCtxParams + ZSTD_adjustCParams)
    p = apply_overrides(p, ov)
    ov.target_length >= 0 && (target = ov.target_length)
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
const PRIME3 = 0x9E3779B1
const PRIME4 = 0x9E3779B1
const PRIME5 = 0x000000CF1BBCDCBB
const PRIME6 = 0x0000CF1BBCDCBF9B
const PRIME7 = 0x00CF1BBCDCBFA563
const PRIME8 = 0xCF1BBCDCB7A56463
@inline function zhash(p::Ptr{UInt8}, hlog::Int, mls::Int)
    if mls == 3
        return Int(((load32(p) << 8) * PRIME3) >> ((32 - hlog) & 31))
    elseif mls == 4
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
    wlimit::Ptr{UInt8}      # literals ending at or before this may be copied in 16-byte chunks
end
SeqStore() = SeqStore(Vector{UInt8}(undef, BLOCK_SIZE_MAX + 32), 0,
                      Vector{UInt32}(undef, BLOCK_SIZE_MAX ÷ 3 + 2),
                      Vector{UInt32}(undef, BLOCK_SIZE_MAX ÷ 3 + 2),
                      Vector{UInt32}(undef, BLOCK_SIZE_MAX ÷ 3 + 2), 0, C_NULL)

@inline function store_seq!(ss::SeqStore, anchor::Ptr{UInt8}, ll::Int, offset::Int, ml::Int)
    if ll > 0
        GC.@preserve ss begin
            dst = pointer(ss.lit) + ss.nlit
            if anchor + ll <= ss.wlimit && ll <= 32
                # wildcopy: may write up to 15 bytes past (the literal buffer has slack)
                unsafe_store!(Ptr{UInt128}(dst), unsafe_load(Ptr{UInt128}(anchor)))
                ll > 16 && unsafe_store!(Ptr{UInt128}(dst + 16), unsafe_load(Ptr{UInt128}(anchor + 16)))
            else
                unsafe_copyto!(dst, anchor, ll)
            end
        end
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

const K_STEP_INCR = 1 << (K_SEARCH_STRENGTH - 1)

# libzstd 1.5's ZSTD_compressBlock_fast_noDict_generic: two adjacent positions
# per step (ip0, ip1) with the repcode checked ahead at ip2; the step starts at
# targetLength + 1 (at least 2) and grows by one every K_STEP_INCR bytes
# without a match.
function parse_fast!(ss::SeqStore, htab::Vector{Int32}, hlog::Int, mls::Int, step0::Int,
                     base::Ptr{UInt8}, istart::Ptr{UInt8}, iend::Ptr{UInt8}, lowlimit::Int,
                     rep1::Int, rep2::Int)
    ilimit = iend - HASH_READ_SIZE
    anchor = istart
    ip0 = istart
    lowp = ptr_of(lowlimit, base)
    ip0 == lowp && (ip0 += 1)
    stepsize = max(step0, 2)
    # repeat offsets reaching before the window are invalid in this block
    maxrep = pos_of(ip0, base) - lowlimit
    saved1 = 0; saved2 = 0
    rep2 > maxrep && (saved2 = rep2; rep2 = 0)
    rep1 > maxrep && (saved1 = rep1; rep1 = 0)
    GC.@preserve htab begin
        ht = pointer(htab)
        @inbounds while true
            # _start
            step = stepsize
            nextstep = ip0 + K_STEP_INCR
            ip1 = ip0 + 1
            ip2 = ip0 + step
            ip3 = ip2 + 1
            ip3 >= ilimit && break
            hash0 = zhash(ip0, hlog, mls)
            hash1 = zhash(ip1, hlog, mls)
            midx = Int(unsafe_load(ht, hash0 + 1))
            found = 0          # 1: repcode at ip0 (match0 set), 2: new offset at ip0 (midx)
            cur0 = 0
            match0 = ip0
            while true
                cur0 = pos_of(ip0, base)
                unsafe_store!(ht, cur0 % Int32, hash0 + 1)
                if rep1 > 0 && load32(ip2) == load32(ip2 - rep1)
                    ip0 = ip2
                    match0 = ip0 - rep1
                    if match0 > lowp && unsafe_load(ip0 - 1) == unsafe_load(match0 - 1)
                        ip0 -= 1; match0 -= 1
                    end
                    unsafe_store!(ht, pos_of(ip1, base) % Int32, hash1 + 1)
                    found = 1
                    break
                end
                if midx >= lowlimit && midx > 0 && load32(ptr_of(midx, base)) == load32(ip0)
                    unsafe_store!(ht, pos_of(ip1, base) % Int32, hash1 + 1)
                    found = 2
                    break
                end
                midx = Int(unsafe_load(ht, hash1 + 1))
                hash0 = hash1
                hash1 = zhash(ip2, hlog, mls)
                ip0 = ip1; ip1 = ip2; ip2 = ip3
                cur0 = pos_of(ip0, base)
                unsafe_store!(ht, cur0 % Int32, hash0 + 1)
                if midx >= lowlimit && midx > 0 && load32(ptr_of(midx, base)) == load32(ip0)
                    step <= 4 && unsafe_store!(ht, pos_of(ip1, base) % Int32, hash1 + 1)
                    found = 2
                    break
                end
                midx = Int(unsafe_load(ht, hash1 + 1))
                hash0 = hash1
                hash1 = zhash(ip2, hlog, mls)
                ip0 = ip1; ip1 = ip2
                ip2 = ip0 + step
                ip3 = ip1 + step
                if ip2 >= nextstep
                    step += 1
                    nextstep += K_STEP_INCR
                end
                ip3 < ilimit || break
            end
            found == 0 && break
            if found == 2
                match0 = ptr_of(midx, base)
                rep2 = rep1
                rep1 = Int(ip0 - match0)
                while ip0 > anchor && match0 > lowp && unsafe_load(ip0 - 1) == unsafe_load(match0 - 1)
                    ip0 -= 1; match0 -= 1
                end
            end
            # _match
            ml = zcount(ip0, match0, iend)
            store_seq!(ss, anchor, Int(ip0 - anchor), Int(ip0 - match0), ml)
            ip0 += ml
            anchor = ip0
            if ip0 <= ilimit
                p2 = ptr_of(cur0 + 2, base)
                unsafe_store!(ht, (cur0 + 2) % Int32, zhash(p2, hlog, mls) + 1)
                unsafe_store!(ht, pos_of(ip0 - 2, base) % Int32, zhash(ip0 - 2, hlog, mls) + 1)
                while rep2 > 0 && ip0 <= ilimit && load32(ip0) == load32(ip0 - rep2)
                    rl = zcount(ip0 + 4, ip0 + 4 - rep2, iend) + 4
                    rep1, rep2 = rep2, rep1
                    unsafe_store!(ht, pos_of(ip0, base) % Int32, zhash(ip0, hlog, mls) + 1)
                    store_seq!(ss, anchor, 0, rep1, rl)
                    ip0 += rl
                    anchor = ip0
                end
            end
        end
    end
    store_last_literals!(ss, anchor, Int(iend - anchor))
    saved2 = (saved1 != 0 && rep1 != 0) ? saved1 : saved2
    return (rep1 != 0 ? rep1 : saved1), (rep2 != 0 ? rep2 : saved2)
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

# Row-based match finder (libzstd's ZSTD_row_*), used by the greedy and lazy
# strategies. The hash table is split into rows of 2^rlog entries; each row
# keeps the most recent positions whose hash falls in it as a ring (newest at
# the row's head), plus a 1-byte tag per entry from the next hash bits. A
# search compares the tags of a whole row at once and only visits entries with
# a matching tag, newest first.
#
# Layout: `htab` holds the positions (2^hash_log entries); `ctab`, read as
# bytes, holds the tags (2^hash_log bytes) followed by one head byte per row.
@inline row_log(p) = min(clamp(p.search_log, 4, 6), p.hash_log)
@inline row_tab_len(p) = ((1 << p.hash_log) + (1 << (p.hash_log - row_log(p)))) >> 2 + 1
@inline is_row(p) = S_GREEDY <= p.strategy <= S_LAZY2

const PREFETCH_IR = """
declare void @llvm.prefetch.p0(ptr, i32, i32, i32)
define void @entry(i64 %a) #0 {
  %p = inttoptr i64 %a to ptr
  call void @llvm.prefetch.p0(ptr %p, i32 0, i32 3, i32 1)
  ret void
}
attributes #0 = { alwaysinline }
"""
@inline prefetch(p::Ptr) = Base.llvmcall((PREFETCH_IR, "entry"), Cvoid, Tuple{UInt}, UInt(p))

@inline function row_prefetch(pos::Ptr{Int32}, tags::Ptr{UInt8}, rbits::Int, rlog::Int, mls::Int, p::Ptr{UInt8})
    rows = (zhash(p, rbits + 8, mls) >> 8) << rlog
    prefetch(tags + rows)
    prefetch(pos + 4rows)
    return
end

@inline function row_insert!(pos::Ptr{Int32}, tags::Ptr{UInt8}, rbits::Int, rlog::Int, mls::Int,
                             base::Ptr{UInt8}, next::Int, target::Int)
    heads = tags + (1 << (rbits + rlog))
    rmask = (1 << rlog) - 1
    i = next
    while i < target
        i + 8 < target && row_prefetch(pos, tags, rbits, rlog, mls, ptr_of(i + 8, base))
        h = zhash(ptr_of(i, base), rbits + 8, mls)
        row = h >> 8
        hd = (Int(unsafe_load(heads, row + 1)) - 1) & rmask
        unsafe_store!(heads, hd % UInt8, row + 1)
        slot = (row << rlog) + hd + 1
        unsafe_store!(tags, h % UInt8, slot)
        unsafe_store!(pos, i % Int32, slot)
        i += 1
    end
    return
end

# Bit k set iff byte k of x is zero (exact: no carries between bytes).
@inline function zero_bytes(x::UInt64)
    y = (x & 0x7F7F7F7F7F7F7F7F) + 0x7F7F7F7F7F7F7F7F
    return ((~(y | x | 0x7F7F7F7F7F7F7F7F) >> 7) * 0x0102040810204080) >> 56
end

# Bit k set iff tags[k] == tag, for the 2^rlog tags of a row.
@inline function row_tag_mask(tr::Ptr{UInt8}, tag::UInt8, rlog::Int)
    t = UInt64(tag) * 0x0101010101010101
    m = zero_bytes(load64(tr) ⊻ t) | (zero_bytes(load64(tr + 8) ⊻ t) << 8)
    if rlog >= 5
        m |= (zero_bytes(load64(tr + 16) ⊻ t) << 16) | (zero_bytes(load64(tr + 24) ⊻ t) << 24)
        if rlog == 6
            m |= (zero_bytes(load64(tr + 32) ⊻ t) << 32) | (zero_bytes(load64(tr + 40) ⊻ t) << 40) |
                 (zero_bytes(load64(tr + 48) ⊻ t) << 48) | (zero_bytes(load64(tr + 56) ⊻ t) << 56)
        end
    end
    return m
end

# Best match at ip via the row table. Returns (length, offset, next).
@inline function row_find_best(pos::Ptr{Int32}, tags::Ptr{UInt8}, rbits::Int, rlog::Int, mls::Int,
                               attempts::Int, base::Ptr{UInt8}, ip::Ptr{UInt8}, iend::Ptr{UInt8},
                               lowlimit::Int, next::Int)
    ilimit = iend - HASH_READ_SIZE
    cur = pos_of(ip, base)
    row_insert!(pos, tags, rbits, rlog, mls, base, next, cur)
    h = zhash(ip, rbits + 8, mls)
    row = h >> 8
    rows = row << rlog
    nent = 1 << rlog
    hd = Int(unsafe_load(tags + (1 << (rbits + rlog)), row + 1))
    m = row_tag_mask(tags + rows, h % UInt8, rlog)
    ip + 1 < ilimit && row_prefetch(pos, tags, rbits, rlog, mls, ip + 1)
    # rotate so that bit j is slot (hd + j) mod nent: newest first
    emask = nent == 64 ? typemax(UInt64) : (UInt64(1) << nent) - 1
    m = ((m >> hd) | (m << ((nent - hd) & 63))) & emask
    best = 3
    bestoff = 0
    lowl = max(lowlimit, 1)
    # first pass: prefetch the candidates' data, so the comparisons below
    # overlap their cache misses (as libzstd's match buffer does)
    mm = m; k = attempts
    while mm != 0 && k > 0
        j = trailing_zeros(mm)
        mm &= mm - 1
        midx = Int(unsafe_load(pos, rows + ((hd + j) & (nent - 1)) + 1))
        if lowl <= midx < cur
            prefetch(ptr_of(midx, base))
            k -= 1
        end
    end
    while m != 0 && attempts > 0
        j = trailing_zeros(m)
        m &= m - 1
        midx = Int(unsafe_load(pos, rows + ((hd + j) & (nent - 1)) + 1))
        (lowl <= midx < cur) || continue
        attempts -= 1
        mp = ptr_of(midx, base)
        if unsafe_load(mp + best) == unsafe_load(ip + best) && load32(mp) == load32(ip)
            l = zcount(ip + 4, mp + 4, iend) + 4
            if l > best
                best = l
                bestoff = cur - midx
                ip + l == iend && break
            end
        end
    end
    return (bestoff == 0 ? 0 : best), bestoff, cur
end

const K_LAZY_SKIPPING_STEP = 8

function parse_lazy!(::Val{BT}, ss::SeqStore, htab::Vector{Int32}, hlog::Int, ctab::Vector{Int32}, rlog::Int,
                     mls::Int, attempts::Int, depth::Int, base::Ptr{UInt8},
                     istart::Ptr{UInt8}, iend::Ptr{UInt8}, lowlimit::Int, rep1::Int, rep2::Int,
                     next::Int) where {BT}
    ilimit = iend - HASH_READ_SIZE
    anchor = istart
    ip = istart
    ip == base && (ip += 1)
    lowp = ptr_of(max(lowlimit, 1), base)
    rbits = hlog - rlog
    GC.@preserve htab ctab begin
        ht = pointer(htab); ch = BT ? pointer(ctab) : Ptr{UInt8}(pointer(ctab))
        while ip < ilimit
            ml = 0; offset = 0; start = ip + 1; isrep = true
            cur = pos_of(ip, base)
            # repcode at ip+1
            if rep1 > 0 && cur + 1 - rep1 >= lowlimit && load32(ip + 1 - rep1) == load32(ip + 1)
                ml = zcount(ip + 5, ip + 5 - rep1, iend) + 4
                offset = rep1
                start = ip + 1
            end
            if !(depth == 0 && ml > 0)
                l2, o2, nxt = (BT ? bt_find_best(ht, ch, hlog, rlog, mls, attempts, base, ip, iend, lowlimit, next) :
                                row_find_best(ht, ch, rbits, rlog, mls, attempts, base, ip, iend, lowlimit, next))
                next = nxt
                if l2 > ml
                    ml = l2; offset = o2; start = ip; isrep = false
                end
            end
            if ml < 4
                step = (Int(ip - anchor) >> K_SEARCH_STRENGTH) + 1
                ip += step
                # long literal runs: stop inserting the skipped positions
                # (libzstd's lazySkipping)
                step > K_LAZY_SKIPPING_STEP && (next = pos_of(ip, base))
                continue
            end
            # lazy evaluation
            if depth >= 1
                while ip < ilimit
                    ip += 1
                    cur2 = pos_of(ip, base)
                    ocost = isrep ? 0 : highbit(offset + 3)
                    if rep1 > 0 && cur2 - rep1 >= lowlimit && load32(ip) == load32(ip - rep1)
                        mlr = zcount(ip + 4, ip + 4 - rep1, iend) + 4
                        gain2 = mlr * 3
                        gain1 = ml * 3 - ocost + 1
                        if gain2 > gain1
                            ml = mlr; offset = rep1; start = ip; isrep = true
                        end
                    end
                    l2, o2, nxt = (BT ? bt_find_best(ht, ch, hlog, rlog, mls, attempts, base, ip, iend, lowlimit, next) :
                                row_find_best(ht, ch, rbits, rlog, mls, attempts, base, ip, iend, lowlimit, next))
                    next = nxt
                    gain2 = l2 * 4 - highbit(o2 + 3)
                    ocost = isrep ? 0 : highbit(offset + 3)
                    gain1 = ml * 4 - ocost + 4
                    if l2 >= 4 && gain2 > gain1
                        ml = l2; offset = o2; start = ip; isrep = false
                        continue
                    end
                    if depth == 2 && ip < ilimit
                        ip += 1
                        cur2 = pos_of(ip, base)
                        ocost = isrep ? 0 : highbit(offset + 3)
                        if rep1 > 0 && cur2 - rep1 >= lowlimit && load32(ip) == load32(ip - rep1)
                            mlr = zcount(ip + 4, ip + 4 - rep1, iend) + 4
                            gain2 = mlr * 4
                            gain1 = ml * 4 - ocost + 1
                            if gain2 > gain1
                                ml = mlr; offset = rep1; start = ip
                            end
                        end
                        l2, o2, nxt = (BT ? bt_find_best(ht, ch, hlog, rlog, mls, attempts, base, ip, iend, lowlimit, next) :
                                row_find_best(ht, ch, rbits, rlog, mls, attempts, base, ip, iend, lowlimit, next))
                        next = nxt
                        gain2 = l2 * 4 - highbit(o2 + 3)
                        ocost = isrep ? 0 : highbit(offset + 3)
                        gain1 = ml * 4 - ocost + 7
                        if l2 >= 4 && gain2 > gain1
                            ml = l2; offset = o2; start = ip; isrep = false
                            continue
                        end
                    end
                    break
                end
            end
            # catch up: extend the match backwards
            if !isrep
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

include("encoder_opt.jl")
include("presplit.jl")

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

"""Huffman code lengths for `counts[1:maxsym+1]`, limited to `maxbits`."""
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

include("postsplit.jl")

# ---------------------------------------------------------------------------
# Compression context
# ---------------------------------------------------------------------------

"""
    CompressionContext()

Reusable compression state (match-finder tables, entropy tables, scratch
buffers). Not thread-safe; use one per task.
"""
const OUT_SCRATCH_MAX = 1 << 26     # 64 MiB

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
    opt::OptState
    savings::Int              # input minus output bytes so far in the frame (block splitting)
    fp_past::Vector{Int}      # block-splitter fingerprints
    fp_new::Vector{Int}
    fp_mid::Vector{Int}
    split::Union{Nothing,SplitState}   # post-splitting scratch, created on first use
    counts4::Vector{Int32}    # interleaved histogram scratch
    outbuf::Vector{UInt8}     # one-shot output scratch (see OUT_SCRATCH_MAX)
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
        zeros(UInt8, 1024), zeros(UInt8, 1024), OptState(), 0, zeros(Int, 1024), zeros(Int, 1024),
        zeros(Int, 256), nothing, zeros(Int32, 4 * 64), UInt8[])
end

function reset_context!(cc::CompressionContext, p::CParams, level::Int; clear::Bool=true)
    cc.params = p
    cc.level = level
    hsize = 1 << p.hash_log
    length(cc.htab) != hsize && resize!(cc.htab, hsize)
    clear && fill!(cc.htab, Int32(0))
    if p.strategy == S_DFAST || p.strategy >= S_GREEDY
        csize = is_row(p) ? row_tab_len(p) : 1 << p.chain_log
        length(cc.ctab) != csize && resize!(cc.ctab, csize)
        clear && fill!(cc.ctab, Int32(0))
    end
    cc.next_to_update = 1
    cc.prep1, cc.prep2 = 1, 4
    cc.rep = (1, 4, 8)
    cc.ll_prev_ok = cc.ml_prev_ok = cc.of_prev_ok = false
    cc.huf_prev_ok = false
    cc.opt.have_stats = false
    cc.savings = 0
    return cc
end

norm_log(norm::Vector{Int16}) = highbit(sum(x -> x == -1 ? 1 : Int(x), norm))

"""Start a frame that uses `dict`: repeat offsets and entropy tables come from it."""
function apply_dict_entropy!(cc::CompressionContext, dict::ZstdDictionary)
    cc.rep = dict.rep_offsets
    cc.prep1, cc.prep2 = dict.rep_offsets[1], dict.rep_offsets[2]
    has_entropy(dict) || return cc
    for (t, norm) in ((cc.ll_prev, dict.ll_norm), (cc.ml_prev, dict.ml_norm), (cc.of_prev, dict.of_norm))
        build_ctable!(t, norm, length(norm) - 1, norm_log(norm), cc.tabsym, cc.cumul)
    end
    cc.ll_prev_ok = cc.ml_prev_ok = cc.of_prev_ok = true
    ws = dict.huf_weights
    tl = dict.huf_log
    lens = cc.lens
    fill!(lens, 0x00)
    for i in eachindex(ws)
        ws[i] > 0 && (lens[i] = UInt8(tl + 1 - ws[i]))
    end
    huf_codes!(cc.huf_prev, lens, length(ws) - 1, tl)
    cc.huf_prev_ok = true
    return cc
end

"""Insert dictionary positions [1, n) of `base` into the match-finder tables."""
load_dict!(cc::CompressionContext, base::Ptr{UInt8}, n::Int) = load_history!(cc, base, 1, n + 1)

"""Insert history positions [from, to) of `base` into the match-finder tables."""
function load_history!(cc::CompressionContext, base::Ptr{UInt8}, from::Int, to::Int)
    p = cc.params
    to - from < HASH_READ_SIZE + 1 && return cc
    last = to - 1 - HASH_READ_SIZE
    mls = clamp(p.min_match, 4, 7)
    cc.next_to_update = from
    if p.strategy == S_FAST
        @inbounds for i in from:last
            cc.htab[zhash(ptr_of(i, base), p.hash_log, mls) + 1] = i % Int32
        end
    elseif p.strategy == S_DFAST
        @inbounds for i in from:last
            cc.htab[zhash(ptr_of(i, base), p.hash_log, 8) + 1] = i % Int32
            cc.ctab[zhash(ptr_of(i, base), p.chain_log, mls) + 1] = i % Int32
        end
    end
    # hash-chain strategies insert lazily from next_to_update = 1
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
        # As libzstd (ZSTD_literalsCompressionIsDisabled): the accelerated fast
        # levels (negative levels, or fast with a target length) store literals raw.
        cc.params.strategy == S_FAST && cc.params.target_length > 0 && return write_raw_literals!(dst, pos, lp, n)
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

"""
Histogram of codes[1:n] (values 0:maxcode) into counts, using four
interleaved tables so runs of one code do not serialize on the increments
(as libzstd's HIST_count).
"""
function count_codes!(counts::Vector{Int}, c4::Vector{Int32}, codes::Vector{UInt8}, n::Int, maxcode::Int)
    w = maxcode + 1
    fill!(view(c4, 1:4w), Int32(0))
    GC.@preserve c4 codes begin
        pc = pointer(c4); pk = pointer(codes)
        i = 1
        @inbounds while i + 3 <= n
            a = Int(unsafe_load(pk, i)); b = Int(unsafe_load(pk, i + 1))
            c = Int(unsafe_load(pk, i + 2)); d = Int(unsafe_load(pk, i + 3))
            unsafe_store!(pc, unsafe_load(pc, a + 1) + Int32(1), a + 1)
            unsafe_store!(pc, unsafe_load(pc, w + b + 1) + Int32(1), w + b + 1)
            unsafe_store!(pc, unsafe_load(pc, 2w + c + 1) + Int32(1), 2w + c + 1)
            unsafe_store!(pc, unsafe_load(pc, 3w + d + 1) + Int32(1), 3w + d + 1)
            i += 4
        end
        @inbounds while i <= n
            a = Int(unsafe_load(pk, i))
            unsafe_store!(pc, unsafe_load(pc, a + 1) + Int32(1), a + 1)
            i += 1
        end
    end
    @inbounds for s in 1:w
        counts[s] = Int(c4[s]) + Int(c4[w + s]) + Int(c4[2w + s]) + Int(c4[3w + s])
    end
    return counts
end

"""Pick the coding mode for one sequence field and prepare its CTable."""
function select_mode!(cc::CompressionContext, codes::Vector{UInt8}, nseq::Int, maxcode::Int,
                      max_al::Int, cur::FSECTable, prev::FSECTable, prev_ok::Bool,
                      def::FSECTable, def_al::Int, dst::Vector{UInt8}, pos::Int)
    counts = cc.counts
    count_codes!(counts, cc.counts4, codes, nseq, maxcode)
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
        llc[i] = ll_code(ll) % UInt8
        mlc[i] = ml_code(Int(ss.ml[i]) - MIN_MATCH) % UInt8
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
        ofv[i] = v % UInt32
        ofc[i] = highbit(v) % UInt8
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
            # Raw pointers: stores into the output through pointers would otherwise
            # force the table fields to be reloaded on every iteration.
            GC.@preserve llc mlc ofc ofv llt mlt oft begin
                pllc = pointer(llc); pmlc = pointer(mlc); pofc = pointer(ofc); pofv = pointer(ofv)
                pll = pointer(ss.ll); pml = pointer(ss.ml)
                lst = pointer(llt.state); ldn = pointer(llt.dnb); ldf = pointer(llt.dfs)
                mst = pointer(mlt.state); mdn = pointer(mlt.dnb); mdf = pointer(mlt.dfs)
                ost = pointer(oft.state); odn = pointer(oft.dnb); odf = pointer(oft.dfs)
                pllb = pointer(LL_BITS); pllbase = pointer(LL_BASE); pmlb = pointer(ML_BITS); pmlbase = pointer(ML_BASE)
                for i in n-1:-1:1
                    lc = Int(unsafe_load(pllc, i)); mc = Int(unsafe_load(pmlc, i)); oc = Int(unsafe_load(pofc, i))
                    if !ofrle
                        nb = (sof + Int(unsafe_load(odn, oc + 1))) >> 16
                        b = bitc_add(b, sof, nb)
                        sof = Int(unsafe_load(ost, (sof >> nb) + Int(unsafe_load(odf, oc + 1)) + 1))
                    end
                    if !mlrle
                        nb = (sml + Int(unsafe_load(mdn, mc + 1))) >> 16
                        b = bitc_add(b, sml, nb)
                        sml = Int(unsafe_load(mst, (sml >> nb) + Int(unsafe_load(mdf, mc + 1)) + 1))
                    end
                    if !llrle
                        nb = (sll + Int(unsafe_load(ldn, lc + 1))) >> 16
                        b = bitc_add(b, sll, nb)
                        sll = Int(unsafe_load(lst, (sll >> nb) + Int(unsafe_load(ldf, lc + 1)) + 1))
                    end
                    # at most 7 + 26 bits pending here
                    llb = Int(unsafe_load(pllb, lc + 1)); mlb = Int(unsafe_load(pmlb, mc + 1))
                    b.pos + llb + mlb > 63 && (b = bitc_flush(b))
                    b = bitc_add(b, Int(unsafe_load(pll, i)) - Int(unsafe_load(pllbase, lc + 1)), llb)
                    b = bitc_add(b, Int(unsafe_load(pml, i)) - Int(unsafe_load(pmlbase, mc + 1)), mlb)
                    b.pos + oc > 63 && (b = bitc_flush(b))
                    b = bitc_add(b, Int(unsafe_load(pofv, i)), oc)
                    b = bitc_flush(b)
                end
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

include("ldm.jl")

struct EntropySnapshot
    rep::NTuple{3,Int}
    ll_ok::Bool; ml_ok::Bool; of_ok::Bool; huf_ok::Bool
end

function write_block_header!(out::Vector{UInt8}, pos::Int, last::Bool, btype::Int, size::Int)
    h = Int(last) | (btype << 1) | (size << 3)
    out[pos] = h % UInt8; out[pos+1] = (h >> 8) % UInt8; out[pos+2] = (h >> 16) % UInt8
    return pos + 3
end

const PREDEF_THRESHOLD = 1024

# btultra2 (ZSTD_initStats_ultra): on the first block of a frame with no
# history, a first pass only seeds the optimal parser's statistics; its
# sequences and table entries are then forgotten.
function seed_stats_ultra!(cc::CompressionContext, base::Ptr{UInt8}, bstart::Ptr{UInt8}, bend::Ptr{UInt8})
    if cc.params.strategy == S_BTULTRA2 && !cc.opt.have_stats && pos_of(bstart, base) == 1 &&
       bend - bstart > PREDEF_THRESHOLD
        parse_range!(cc, base, bstart, bend, true)
        cc.ss.nlit = 0; cc.ss.nseq = 0
        fill!(cc.htab, Int32(0)); fill!(cc.ctab, Int32(0))
        cc.next_to_update = 1
    end
    return
end

function parse_block!(cc::CompressionContext, base::Ptr{UInt8}, bstart::Ptr{UInt8}, bend::Ptr{UInt8})
    cc.ss.nlit = 0; cc.ss.nseq = 0
    seed_stats_ultra!(cc, base, bstart, bend)
    parse_range!(cc, base, bstart, bend, true)
end

"""
Parse [bstart, bend) and append its sequences (and trailing literals) to the
sequence store. `first` marks the first range of a block (the optimal parser
refreshes its statistics then).
"""
function parse_range!(cc::CompressionContext, base::Ptr{UInt8}, bstart::Ptr{UInt8}, bend::Ptr{UInt8},
                      first::Bool)
    p = cc.params
    ss = cc.ss
    ss.wlimit = bend - 32
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
    elseif p.strategy >= S_BTOPT
        cc.next_to_update = max(cc.next_to_update, lowlimit)
        cc.next_to_update = parse_opt!(ss, cc.opt, cc.htab, p.hash_log, cc.ctab, p.chain_log,
            clamp(p.min_match, 3, 4), 1 << p.search_log, max(p.target_length, 8), p.strategy >= S_BTULTRA,
            base, bstart, bend, lowlimit, cc.rep, cc.next_to_update, first)
    else
        depth = p.strategy == S_GREEDY ? 0 : p.strategy == S_LAZY ? 1 : 2
        mls = clamp(p.min_match, 4, 6)
        cc.next_to_update = max(cc.next_to_update, lowlimit)
        if p.strategy == S_BTLAZY2
            cc.prep1, cc.prep2, cc.next_to_update = parse_lazy!(Val(true), ss, cc.htab, p.hash_log, cc.ctab,
                p.chain_log - 1, mls, 1 << p.search_log, depth, base, bstart, bend,
                lowlimit, cc.prep1, cc.prep2, cc.next_to_update)
        else
            cc.prep1, cc.prep2, cc.next_to_update = parse_lazy!(Val(false), ss, cc.htab, p.hash_log, cc.ctab,
                row_log(p), mls, 1 << min(p.search_log, row_log(p)), depth, base, bstart, bend,
                lowlimit, cc.prep1, cc.prep2, cc.next_to_update)
        end
    end
    return
end

"""Compress one block into out[pos]. Returns new pos."""
function compress_block!(cc::CompressionContext, out::Vector{UInt8}, pos::Int, base::Ptr{UInt8},
                         bstart::Ptr{UInt8}, bend::Ptr{UInt8}, last::Bool,
                         ldm::Union{Nothing,LdmCursor}=nothing)
    newpos = compress_block_body!(cc, out, pos, base, bstart, bend, last, ldm)
    cc.savings += Int(bend - bstart) - (newpos - pos)
    return newpos
end

function compress_block_body!(cc::CompressionContext, out::Vector{UInt8}, pos::Int, base::Ptr{UInt8},
                              bstart::Ptr{UInt8}, bend::Ptr{UInt8}, last::Bool,
                              ldm::Union{Nothing,LdmCursor})
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
            ldm === nothing ? parse_block!(cc, base, bstart, bend) : parse_block_ldm!(cc, base, bstart, bend, ldm)
            return pos + 1
        end
    end
    ldm === nothing ? parse_block!(cc, base, bstart, bend) : parse_block_ldm!(cc, base, bstart, bend, ldm)
    if cc.params.strategy >= S_BTOPT && cc.params.window_log >= 17
        cc.split === nothing && (cc.split = SplitState())
        p2 = emit_split_block!(cc, out, pos, bstart, n, last)
        p2 != 0 && return p2
    end
    return emit_parsed_block!(cc, out, pos, bstart, n, last)
end

"""Encode the parsed sequences in cc.ss for source [bstart, bstart+n) as one block."""
function emit_parsed_block!(cc::CompressionContext, out::Vector{UInt8}, pos::Int,
                            bstart::Ptr{UInt8}, n::Int, last::Bool)
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

"""
Write a frame header. `src_size < 0` means unknown (no Frame_Content_Size);
`dict_id == 0` omits the dictionary ID.
"""
function write_frame_header!(out::Vector{UInt8}, pos::Int, src_size::Int, window_log::Int,
                             checksum::Bool, dict_id::UInt32=UInt32(0))
    for k in 0:3
        out[pos + k] = (MAGIC_NUMBER >> (8k)) % UInt8
    end
    pos += 4
    window = 1 << window_log
    known = src_size >= 0
    single = known && src_size <= window
    if !known
        fcs_code = 0
    else
        fcs_code = src_size < 256 ? 0 : src_size < 65536 + 256 ? 1 : src_size <= 0xFFFFFFFF ? 2 : 3
        (fcs_code == 0 && !single) && (fcs_code = 1)
    end
    did_code = dict_id == 0 ? 0 : dict_id < 256 ? 1 : dict_id < 65536 ? 2 : 3
    fd = (fcs_code << 6) | (Int(single) << 5) | (Int(checksum) << 2) | did_code
    out[pos] = UInt8(fd); pos += 1
    if !single
        out[pos] = UInt8((window_log - 10) << 3); pos += 1
    end
    nd = (0, 1, 2, 4)[did_code + 1]
    for k in 0:nd-1
        out[pos + k] = (dict_id >> (8k)) % UInt8
    end
    pos += nd
    if known
        v = fcs_code == 1 ? src_size - 256 : src_size
        nb = (1, 2, 4, 8)[fcs_code + 1]
        for k in 0:nb-1
            out[pos + k] = (v >> (8k)) % UInt8
        end
        pos += nb
    end
    return pos
end

include("prepared.jl")

"""
    compress_frame!(cc, data, level; checksum=false) -> Vector{UInt8}

Compress `data` as a single Zstandard frame.
"""
function compress_frame!(cc::CompressionContext, data::AbstractVector{UInt8}, level::Integer;
                         checksum::Bool=false,
                         dict::Union{Nothing,ZstdDictionary,PreparedDictionary}=nothing,
                         long::Bool=false, params::ParameterOverrides=NO_OVERRIDES)
    prepared = nothing
    if dict isa PreparedDictionary
        level = dict.level
        prepared = (!long && use_prepared(dict, length(data), level, params)) ? dict : nothing
        params = dict.overrides
        dict = dict.dict
    end
    n = length(data)
    dlen = dict === nothing ? 0 : length(dict.content)
    if dlen > 0
        # The dictionary content is history preceding the data.
        src = Vector{UInt8}(undef, dlen + n)
        copyto!(src, 1, dict.content, 1, dlen)
        copyto!(src, dlen + 1, data, 1, n)
    else
        src = data isa Vector{UInt8} ? data : Vector{UInt8}(data)
    end
    p = compression_parameters(level, n + dlen, params)
    if long
        # long-distance matching uses a 128 MiB window (as `zstd --long`)
        src_log = max(10, 64 - leading_zeros(UInt64(max(n + dlen - 1, 1))))
        wlog = max(p.window_log, min(LDM_WINDOW_LOG, src_log))
        p = CParams(wlog, p.chain_log, p.hash_log, p.search_log, p.min_match, p.target_length, p.strategy)
    end
    if prepared !== nothing
        p = prepared.params
        use_prepared!(cc, prepared)
    else
        reset_context!(cc, p, Int(level))
        dict === nothing || apply_dict_entropy!(cc, dict)
    end
    bound = n + (n >> 7) + 64 + 3 * (n ÷ BLOCK_SIZE_MAX + 1)
    # Compress into the context's scratch buffer (reused across calls, up to
    # OUT_SCRATCH_MAX) and copy out the exact result: allocating the worst-case
    # size on every call costs more in GC than the copy.
    scratch = bound <= OUT_SCRATCH_MAX
    if scratch
        length(cc.outbuf) < bound && resize!(cc.outbuf, bound)
        out = cc.outbuf
    else
        out = Vector{UInt8}(undef, bound)
    end
    pos = write_frame_header!(out, 1, n, p.window_log, checksum, dict === nothing ? UInt32(0) : dict.id)
    GC.@preserve src begin
        base = pointer(src)
        dlen > 0 && prepared === nothing && load_dict!(cc, base, dlen)
        ldm = nothing
        if long && n >= 1 << 16
            mm = p.strategy >= S_BTULTRA ? 32 : 64
            ldm = ldm_sequences(base, dlen + 1, dlen + n, 1 << p.window_log, mm,
                                max(6, min(20, p.window_log - 7)))
        end
        bmax = block_size(p)
        if n == 0
            pos = write_block_header!(out, pos, true, 0, 0)
        else
            off = dlen
            while off < dlen + n
                bn = next_block_size(cc, base + off, dlen + n - off, bmax)
                last = off + bn == dlen + n
                length(out) < pos + bn + 16 && resize!(out, pos + bn + 1024)
                pos = compress_block!(cc, out, pos, base, base + off, base + off + bn, last, ldm)
                off += bn
            end
        end
    end
    if checksum
        h = dlen > 0 ? content_checksum(view(src, dlen+1:dlen+n)) : content_checksum(src)
        length(out) < pos + 4 && resize!(out, pos + 4)
        for k in 0:3
            out[pos + k] = (h >> (8k)) % UInt8
        end
        pos += 4
    end
    scratch && return out[1:pos-1]
    resize!(out, pos - 1)
    return out
end

# ---------------------------------------------------------------------------
# Multithreaded compression (one frame, independent jobs with overlapping history)
# ---------------------------------------------------------------------------

"""
    mt_layout(n, level) -> (params, job_size, overlap)

Job layout for multithreaded compression of `n` bytes, after libzstd's
defaults: jobs of at least one window (min 1 MiB; four windows for the
optimal parser, whose history is expensive to load), each loading part of the
preceding data as history (window/8 for fast..lazy2, more for optimal parsing).
"""
function mt_layout(n::Int, level::Integer, ov::ParameterOverrides=NO_OVERRIDES)
    p = compression_parameters(level, n, ov)
    window = 1 << p.window_log
    job = max(1 << 20, p.strategy >= S_BTOPT ? 4window : window)
    # libzstd's default overlapLog: 9 for btultra2, 8 btopt/btultra, 7 lazy2/btlazy2, 6 otherwise
    overlap = window >> (p.strategy >= S_BTULTRA2 ? 0 : p.strategy >= S_BTOPT ? 1 :
                         p.strategy >= S_LAZY2 ? 2 : 3)
    return p, job, overlap
end

"""
    compress_job!(cc, p, level, data, job_start, job_end, overlap, last) -> Vector{UInt8}

Compress `data[job_start:job_end]` into blocks (no frame header), using up to
`overlap` preceding bytes as history. Jobs other than the first start with
invalidated repeat offsets and no previous entropy tables, so their output can
follow any preceding job in the same frame.
"""
function compress_job!(cc::CompressionContext, p::CParams, level::Integer, data::Vector{UInt8},
                       job_start::Int, job_end::Int, overlap::Int, last::Bool)
    reset_context!(cc, p, Int(level))
    if job_start > 1
        cc.rep = (0, 0, 0)          # unknown: never emit a repcode until real offsets are known
        cc.prep1 = cc.prep2 = 0
    end
    n = job_end - job_start + 1
    out = Vector{UInt8}(undef, n + (n >> 7) + 64 + 3 * (n ÷ BLOCK_SIZE_MAX + 1))
    pos = 1
    GC.@preserve data begin
        base = pointer(data)
        hist = max(1, job_start - overlap)
        hist < job_start && load_history!(cc, base, hist, job_start)
        off = job_start - 1
        bmax = block_size(p)
        while off < job_end
            bn = next_block_size(cc, base + off, job_end - off, bmax)
            lastb = last && off + bn == job_end
            length(out) < pos + bn + 16 && resize!(out, pos + bn + 1024)
            pos = compress_block!(cc, out, pos, base, base + off, base + off + bn, lastb)
            off += bn
        end
    end
    resize!(out, pos - 1)
    return out
end

"""Frame header bytes (as written by compress_frame!) for an input of n bytes."""
function frame_header_bytes(n::Int, p::CParams, checksum::Bool)
    out = Vector{UInt8}(undef, 32)
    pos = write_frame_header!(out, 1, n, p.window_log, checksum)
    return resize!(out, pos - 1)
end

# ---------------------------------------------------------------------------
# Streaming compression
# ---------------------------------------------------------------------------

"""
    StreamCompressor(; level=3, checksum=false, dict=nothing, pledged_size=nothing)

Incremental compressor producing one frame. Input is fed with
[`stream_write!`](@ref); compressed bytes accumulate in `sc.out[1:sc.olen]` and
are taken by the caller. Memory use is bounded by the window size of the level.

With `pledged_size` (or [`stream_pledge!`](@ref) before the first write), the
frame header records that content size and the compression parameters are
sized to it, as for one-shot compression. Exactly that many bytes must then be
written before the frame is finished.
"""
mutable struct StreamCompressor
    cc::CompressionContext
    level::Int
    checksum::Bool
    dict::Union{Nothing,ZstdDictionary,PreparedDictionary}
    buf::Vector{UInt8}   # [history | pending input]
    len::Int             # valid bytes in buf
    pend::Int            # first byte not yet compressed (1-based)
    cap::Int             # maximum buffer size
    gran::Int            # compaction granularity (multiple of the chain table size)
    out::Vector{UInt8}
    olen::Int
    started::Bool
    finished::Bool
    xxh::ChecksumState
    pledged::Int         # pledged content size of the current frame, -1 if unknown
    total::Int           # bytes written to the current frame
    params::ParameterOverrides
    bsize::Int           # block size of the current frame
end

function StreamCompressor(; level::Union{Nothing,Integer}=nothing, checksum::Bool=false,
                          dict::Union{Nothing,ZstdDictionary,PreparedDictionary}=nothing,
                          pledged_size::Union{Nothing,Integer}=nothing,
                          params::ParameterOverrides=NO_OVERRIDES)
    if dict isa PreparedDictionary
        use_prepared(dict, 0, level, params)    # checks level and parameters
        level = dict.level
        params = dict.overrides
    end
    level = level === nothing ? 3 : Int(level)
    sc = StreamCompressor(CompressionContext(), level, checksum, dict, UInt8[], 0, 1, 0, 0,
                          UInt8[], 0, false, false, ChecksumState(), -1, 0, params, BLOCK_SIZE_MAX)
    pledged_size === nothing || stream_pledge!(sc, pledged_size)
    return sc
end

"""
    stream_pledge!(sc::StreamCompressor, n)

Pledge that the next frame will contain exactly `n` bytes (a negative `n`
means unknown). Must be called before the frame's first write.
"""
function stream_pledge!(sc::StreamCompressor, n::Integer)
    sc.started && throw(ArgumentError("the content size must be pledged before writing to the frame"))
    sc.pledged = n < 0 ? -1 : Int(n)
    return sc
end

function out_reserve!(sc::StreamCompressor, n::Int)
    need = sc.olen + n
    length(sc.out) < need && resize!(sc.out, max(need, 2 * length(sc.out)))
    return sc
end

function stream_begin!(sc::StreamCompressor)
    cc = sc.cc
    pd = sc.dict isa PreparedDictionary && sc.pledged >= 0 && use_prepared(sc.dict, sc.pledged, nothing) ?
         sc.dict : nothing
    dict = sc.dict isa PreparedDictionary ? sc.dict.dict : sc.dict
    dlen = dict === nothing ? 0 : length(dict.content)
    if pd !== nothing
        p = pd.params
        use_prepared!(cc, pd)
    else
        p = compression_parameters(sc.level, sc.pledged < 0 ? -1 : sc.pledged + dlen, sc.params)
        reset_context!(cc, p, sc.level)
        dict === nothing || apply_dict_entropy!(cc, dict)
    end
    window = 1 << p.window_log
    sc.bsize = block_size(p)
    sc.gran = 1 << max(p.chain_log, 17)
    sc.cap = window + dlen + sc.gran + 2 * BLOCK_SIZE_MAX
    resize!(sc.buf, min(sc.cap, max(dlen + 2 * BLOCK_SIZE_MAX, 1 << 18)))
    sc.len = 0
    if dlen > 0
        copyto!(sc.buf, 1, dict.content, 1, dlen)
        sc.len = dlen
        pd === nothing && GC.@preserve sc load_dict!(cc, pointer(sc.buf), dlen)
    end
    sc.pend = sc.len + 1
    out_reserve!(sc, 32)
    sc.olen = write_frame_header!(sc.out, sc.olen + 1, sc.pledged, p.window_log, sc.checksum,
                                  dict === nothing ? UInt32(0) : dict.id) - 1
    sc.xxh = ChecksumState()
    sc.total = 0
    sc.started = true
    sc.finished = false
    return sc
end

# Shift tables and buffer down by `d` bytes (a multiple of sc.gran).
function rebase!(sc::StreamCompressor, d::Int)
    cc = sc.cc
    dubt = cc.params.strategy == S_BTLAZY2
    for t in (is_row(cc.params) ? (cc.htab,) : (cc.htab, cc.ctab))   # row tags are not positions
        marks = dubt && t === cc.ctab
        @inbounds for i in eachindex(t)
            if marks && iseven(i)
                # DUBT: keep the "unsorted" marks (second slot of each pair), and
                # never turn a shifted position into one
                t[i] == DUBT_UNSORTED && continue
                v = Int(t[i]) - d
                t[i] = v <= 1 ? Int32(0) : v % Int32
            else
                v = Int(t[i]) - d
                t[i] = v < 1 ? Int32(0) : v % Int32
            end
        end
    end
    cc.next_to_update = max(1, cc.next_to_update - d)
    copyto!(sc.buf, 1, sc.buf, d + 1, sc.len - d)
    sc.len -= d
    sc.pend -= d
    return sc
end

# Make room for n more input bytes (n <= BLOCK_SIZE_MAX).
function make_input_room!(sc::StreamCompressor, n::Int)
    sc.len + n <= length(sc.buf) && return sc
    if length(sc.buf) < sc.cap
        resize!(sc.buf, min(sc.cap, max(2 * length(sc.buf), sc.len + n)))
        sc.len + n <= length(sc.buf) && return sc
    end
    window = 1 << sc.cc.params.window_log
    d = ((sc.pend - 1 - window) ÷ sc.gran) * sc.gran
    if d > 0
        rebase!(sc, d)
    end
    sc.len + n > length(sc.buf) && resize!(sc.buf, sc.len + n)
    return sc
end

function stream_block_size(sc::StreamCompressor, pending::Int)
    GC.@preserve sc begin
        return next_block_size(sc.cc, pointer(sc.buf, sc.pend), pending, sc.bsize)
    end
end

function emit_block!(sc::StreamCompressor, bn::Int, last::Bool)
    out_reserve!(sc, bn + 64)
    GC.@preserve sc begin
        base = pointer(sc.buf)
        sc.olen = compress_block!(sc.cc, sc.out, sc.olen + 1, base, base + sc.pend - 1,
                                  base + sc.pend - 1 + bn, last) - 1
    end
    sc.pend += bn
    return sc
end

"""
    stream_write!(sc, data::AbstractVector{UInt8})

Feed input. Full blocks are compressed as soon as more input follows them.
"""
function stream_write!(sc::StreamCompressor, data::AbstractVector{UInt8})
    sc.finished && error("stream already finished")
    sc.started || stream_begin!(sc)
    if sc.pledged >= 0 && sc.total + length(data) > sc.pledged
        throw(ArgumentError("writing $(length(data)) more bytes exceeds the pledged content size " *
                            "of $(sc.pledged) bytes ($(sc.total) written)"))
    end
    sc.total += length(data)
    i = firstindex(data)
    stop = lastindex(data)
    while i <= stop
        k = min(stop - i + 1, BLOCK_SIZE_MAX)
        make_input_room!(sc, k)
        copyto!(sc.buf, sc.len + 1, data, i, k)
        sc.len += k
        i += k
        # keep the last (possibly full) block pending so it can be marked last
        while sc.len - sc.pend + 1 > sc.bsize
            emit_block!(sc, stream_block_size(sc, sc.len - sc.pend + 1), false)
        end
    end
    sc.checksum && checksum_update!(sc.xxh, data)
    return sc
end

"""Compress all pending input into a non-final block, so that it can be decoded."""
function stream_flush!(sc::StreamCompressor)
    sc.started || stream_begin!(sc)
    sc.finished && return sc
    while (n = sc.len - sc.pend + 1) > 0
        emit_block!(sc, stream_block_size(sc, n), false)
    end
    return sc
end

"""Finish the frame: compress remaining input as the last block and append the checksum."""
function stream_finish!(sc::StreamCompressor)
    sc.finished && return sc
    sc.started || stream_begin!(sc)
    if sc.pledged >= 0 && sc.total != sc.pledged
        throw(ArgumentError("frame finished after $(sc.total) bytes, but $(sc.pledged) were pledged"))
    end
    n = sc.len - sc.pend + 1
    if n > 0
        while n > 0
            bn = stream_block_size(sc, n)
            emit_block!(sc, bn, bn == n)
            n -= bn
        end
    else
        out_reserve!(sc, 3)
        sc.olen = write_block_header!(sc.out, sc.olen + 1, true, 0, 0) - 1
    end
    if sc.checksum
        out_reserve!(sc, 4)
        h = checksum_digest(sc.xxh)
        for k in 0:3
            sc.out[sc.olen + 1 + k] = (h >> (8k)) % UInt8
        end
        sc.olen += 4
    end
    sc.finished = true
    sc.started = false
    sc.pledged = -1          # a pledge applies to one frame
    return sc
end

include("dictbuilder.jl")

end # module
