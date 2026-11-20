# Block pre-splitting (libzstd 1.5.7's ZSTD_optimalBlockSize / ZSTD_splitBlock,
# zstd_preSplit.c): before compressing a full 128 KiB block, look for a point
# where the data changes character (by fingerprints of byte pairs) and end the
# block there, so each part gets its own entropy tables. Included in module
# Encoder.

const SPLIT_CHUNK = 8 << 10
const SPLIT_PENALTY_RATE = 16
const SPLIT_THRESHOLD_BASE = SPLIT_PENALTY_RATE - 2
const SPLIT_PENALTY = 3
const SPLIT_SEGMENT = 512
# split level per strategy (fast .. btultra2)
const SPLIT_LEVELS = (0, 1, 2, 2, 3, 3, 4, 4, 4)
# sampling rate and hash log per by-chunks level (1-4)
const SPLIT_RATES = (43, 11, 5, 1)
const SPLIT_HLOGS = (8, 9, 10, 10)

@inline function split_hash2(p::Ptr{UInt8}, hlog::Int)
    hlog == 8 && return Int(unsafe_load(p))
    return Int((UInt32(ltoh(unsafe_load(Ptr{UInt16}(p)))) * 0x9e3779b9) >> (32 - hlog))
end

# Fingerprint of n bytes at p: counts of hashed byte pairs, every `rate` bytes.
function record_fingerprint!(ev::Vector{Int}, p::Ptr{UInt8}, n::Int, rate::Int, hlog::Int)
    fill!(view(ev, 1:1 << hlog), 0)
    limit = n - 1
    i = 0
    @inbounds while i < limit
        ev[split_hash2(p + i, hlog) + 1] += 1
        i += rate
    end
    return limit ÷ rate
end

function fp_distance(a::Vector{Int}, na::Int, b::Vector{Int}, nb::Int, hlog::Int)
    d = 0
    @inbounds for i in 1:1 << hlog
        d += abs(a[i] * nb - b[i] * na)
    end
    return d
end

@inline fp_differ(a, na, b, nb, penalty, hlog) =
    fp_distance(a, na, b, nb, hlog) >= (na * nb) * (SPLIT_THRESHOLD_BASE + penalty) ÷ SPLIT_PENALTY_RATE

function split_by_chunks(cc, p::Ptr{UInt8}, bsize::Int, level::Int)
    rate = SPLIT_RATES[level]; hlog = SPLIT_HLOGS[level]
    past = cc.fp_past; new = cc.fp_new
    npast = record_fingerprint!(past, p, SPLIT_CHUNK, rate, hlog)
    penalty = SPLIT_PENALTY
    pos = SPLIT_CHUNK
    while pos <= bsize - SPLIT_CHUNK
        nnew = record_fingerprint!(new, p + pos, SPLIT_CHUNK, rate, hlog)
        fp_differ(past, npast, new, nnew, penalty, hlog) && return pos
        @inbounds for i in 1:1 << hlog
            past[i] += new[i]
        end
        npast += nnew
        penalty > 0 && (penalty -= 1)
        pos += SPLIT_CHUNK
    end
    return bsize
end

function split_from_borders(cc, p::Ptr{UInt8}, bsize::Int)
    a = cc.fp_past; b = cc.fp_new; m = cc.fp_mid
    fill!(view(a, 1:256), 0); fill!(view(b, 1:256), 0); fill!(m, 0)
    @inbounds for i in 0:SPLIT_SEGMENT-1
        a[Int(unsafe_load(p + i)) + 1] += 1
        b[Int(unsafe_load(p + bsize - SPLIT_SEGMENT + i)) + 1] += 1
    end
    fp_differ(a, SPLIT_SEGMENT, b, SPLIT_SEGMENT, 0, 8) || return bsize
    @inbounds for i in 0:SPLIT_SEGMENT-1
        m[Int(unsafe_load(p + bsize ÷ 2 - SPLIT_SEGMENT ÷ 2 + i)) + 1] += 1
    end
    dbegin = fp_distance(a, SPLIT_SEGMENT, m, SPLIT_SEGMENT, 8)
    dend = fp_distance(b, SPLIT_SEGMENT, m, SPLIT_SEGMENT, 8)
    abs(dbegin - dend) < SPLIT_SEGMENT * SPLIT_SEGMENT ÷ 3 && return 64 << 10
    return dbegin > dend ? 32 << 10 : 96 << 10
end

"""
Size of the next block starting at p (`remaining` bytes left, blocks at most
`bmax`): full 128 KiB blocks are split where the data changes, once the
frame has saved at least 3 bytes so far (never for incompressible data).
"""
function next_block_size(cc, p::Ptr{UInt8}, remaining::Int, bmax::Int)
    (remaining < BLOCK_SIZE_MAX || bmax < BLOCK_SIZE_MAX) && return min(remaining, bmax)
    cc.savings < 3 && return BLOCK_SIZE_MAX
    level = SPLIT_LEVELS[Int(cc.params.strategy) + 1]
    return level == 0 ? split_from_borders(cc, p, BLOCK_SIZE_MAX) :
                        split_by_chunks(cc, p, BLOCK_SIZE_MAX, level)
end
