# Long-distance matching (after libzstd's zstd_ldm.c). Included in module Encoder.
#
# A gear rolling hash selects split points (about one every 2^hash_rate_log
# bytes). The `min_match` bytes ending at each split are hashed with XXH64
# into a bucketed table; matching entries are verified and extended forwards
# and backwards. The resulting long matches are spliced into each block, with
# the regular parser compressing the gaps between them.

const LDM_WINDOW_LOG = 27
const LDM_BUCKET_LOG = 3

# Deterministic gear table (splitmix64).
const GEAR = let x = 0x9E3779B97F4A7C15, t = Vector{UInt64}(undef, 256)
    for i in 1:256
        x += 0x9E3779B97F4A7C15
        z = x
        z = (z ⊻ (z >> 30)) * 0xBF58476D1CE4E5B9
        z = (z ⊻ (z >> 27)) * 0x94D049BB133111EB
        t[i] = z ⊻ (z >> 31)
    end
    t
end

mutable struct LdmCursor
    starts::Vector{Int}     # 1-based match start positions (relative to base)
    mls::Vector{Int}
    offs::Vector{Int}
    idx::Int
end

"""
Long-distance matching state, kept across calls so input can be scanned as it
arrives (streaming): the bucketed table, the rolling hash and where it stands,
and the long matches found so far (`cur`, consumed by `parse_block_ldm!`).
Positions are 1-based offsets from the buffer base.
"""
mutable struct LdmState
    eoff::Vector{Int32}
    echk::Vector{UInt32}
    bnext::Vector{UInt8}
    nbuckets::Int
    stopmask::UInt64
    window::Int
    min_match::Int
    h::UInt64
    q::Int           # next position to roll into the hash
    hist::Int        # lowest position that may be indexed
    anchor::Int      # end of the last long match (no overlapping matches)
    ipos::Int        # matches start at or after this
    cur::LdmCursor
end

function LdmState(window::Int, min_match::Int, hash_log::Int, hist::Int, from::Int)
    nbuckets = 1 << (hash_log - LDM_BUCKET_LOG)
    hrlog = LDM_WINDOW_LOG - hash_log
    maxbits = min(min_match, 64)
    stopmask = hrlog <= maxbits ? ((UInt64(1) << hrlog) - 1) << (maxbits - hrlog) : (UInt64(1) << hrlog) - 1
    return LdmState(zeros(Int32, 1 << hash_log), zeros(UInt32, 1 << hash_log), zeros(UInt8, nbuckets),
                    nbuckets, stopmask, window, min_match, UInt64(0), hist, hist, from, from,
                    LdmCursor(Int[], Int[], Int[], 1))
end

"""
Scan positions up to `upto` (the last byte available, 1-based) for long
matches, appending them to `st.cur`. Matches are extended forwards over all
available bytes. Positions before `st.ipos` (a dictionary or prefix) are only
indexed.
"""
function ldm_scan!(st::LdmState, base::Ptr{UInt8}, upto::Int)
    bsize = 1 << LDM_BUCKET_LOG
    eoff = st.eoff; echk = st.echk; bnext = st.bnext
    nbuckets = st.nbuckets; stopmask = st.stopmask; window = st.window; min_match = st.min_match
    starts = st.cur.starts; mls = st.cur.mls; offs = st.cur.offs
    h = st.h; anchor = st.anchor; ipos = st.ipos; hist = st.hist
    iend = base + upto             # one past the last byte
    q = st.q
    @inbounds while q <= upto - HASH_READ_SIZE
        h = (h << 1) + GEAR[Int(unsafe_load(base, q)) + 1]
        qq = q; q += 1
        (h & stopmask) != 0 && continue
        ws = qq - min_match + 1
        ws < hist && continue
        xx = xxh64(base + ws - 1, min_match)   # internal hash: always the native XXH64
        bucket = Int(xx & UInt64(nbuckets - 1))
        chk = (xx >> 32) % UInt32
        slot0 = bucket * bsize
        if ws >= ipos
            best = 0; best_o = 0; best_f = 0; best_b = 0
            for e in 1:bsize
                o = Int(eoff[slot0 + e])
                (o == 0 || echk[slot0 + e] != chk || ws - o > window) && continue
                f = zcount(ptr_of(ws, base), ptr_of(o, base), iend)
                f < min_match && continue
                b = 0
                while ws - b > anchor && o - b > 1 && unsafe_load(base, ws - b - 1) == unsafe_load(base, o - b - 1)
                    b += 1
                end
                if f + b > best
                    best = f + b; best_o = o; best_f = f; best_b = b
                end
            end
            if best > 0
                push!(starts, ws - best_b); push!(mls, best); push!(offs, ws - best_o)
                anchor = ws + best_f
                ipos = anchor
            end
        end
        # insert (round robin within the bucket)
        e = Int(bnext[bucket + 1])
        eoff[slot0 + e + 1] = ws % Int32
        echk[slot0 + e + 1] = chk
        bnext[bucket + 1] = UInt8((e + 1) & (bsize - 1))
    end
    st.h = h; st.q = q; st.anchor = anchor; st.ipos = ipos
    return st
end

"""Shift the state down by `d` positions (the stream buffer was compacted)."""
function ldm_rebase!(st::LdmState, d::Int)
    @inbounds for i in eachindex(st.eoff)
        v = Int(st.eoff[i]) - d
        st.eoff[i] = v < 1 ? Int32(0) : v % Int32
    end
    c = st.cur
    # drop consumed matches, shift the rest
    deleteat!(c.starts, 1:c.idx-1); deleteat!(c.mls, 1:c.idx-1); deleteat!(c.offs, 1:c.idx-1)
    c.idx = 1
    c.starts .-= d
    st.q -= d; st.anchor -= d; st.ipos -= d; st.hist = max(1, st.hist - d)
    return st
end

"""
    ldm_sequences(base, from, to, window, min_match, hash_log, hist=from) -> LdmCursor

Find long matches in positions `from:to` of the buffer at `base`
(positions `hist:from-1` are indexed as history only).
"""
function ldm_sequences(base::Ptr{UInt8}, from::Int, to::Int, window::Int, min_match::Int, hash_log::Int,
                       hist::Int=from)
    st = LdmState(window, min_match, hash_log, hist, from)
    ldm_scan!(st, base, to)
    return st.cur
end

# LDM parameters for compression parameters p (as zstd --long)
ldm_min_match(p) = p.strategy >= S_BTULTRA ? 32 : 64
ldm_hash_log(p) = max(6, min(20, p.window_log - 7))

"""Parse a block, splicing in the long matches from `cur`."""
function parse_block_ldm!(cc::CompressionContext, base::Ptr{UInt8}, bstart::Ptr{UInt8}, bend::Ptr{UInt8},
                          cur::LdmCursor)
    ss = cc.ss
    ss.nlit = 0; ss.nseq = 0
    seed_stats_ultra!(cc, base, bstart, bend)
    bs = pos_of(bstart, base)
    be = pos_of(bend, base)
    ip = bs
    first = true
    while cur.idx <= length(cur.starts)
        i = cur.idx
        s = cur.starts[i]; ml = cur.mls[i]; off = cur.offs[i]
        s >= be && break
        if s + ml <= ip
            cur.idx += 1
            continue
        end
        if s < ip
            ml -= ip - s; s = ip
        end
        mend = min(s + ml, be)
        mlb = mend - s
        if mlb < 8
            # too short to be worth a sequence here; let the regular parser have it
            if s + ml <= be
                cur.idx += 1
                continue
            end
            break
        end
        nlit0 = ss.nlit; nseq0 = ss.nseq
        parse_range!(cc, base, ptr_of(ip, base), ptr_of(s, base), first)
        first = false
        t = ss.nlit - nlit0
        @inbounds for k in nseq0+1:ss.nseq
            t -= Int(ss.ll[k])
        end
        n = ss.nseq + 1
        @inbounds ss.ll[n] = t % UInt32; ss.ml[n] = mlb % UInt32; ss.off[n] = off % UInt32
        ss.nseq = n
        ip = mend
        # positions inside the long match need not enter the tree/chain
        cc.next_to_update = max(cc.next_to_update, ip)
        if mend < s + ml
            cur.starts[i] = mend; cur.mls[i] = s + ml - mend
            break
        end
        cur.idx += 1
    end
    parse_range!(cc, base, ptr_of(ip, base), bend, first)
    return
end
