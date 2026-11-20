# Optimal parsing (after libzstd's btopt / btultra), included in module Encoder.
#
# For each chunk, a forward dynamic program finds the cheapest way to encode
# up to OPT_NUM bytes as literals and matches. Prices (in 1/256 bit) come from
# adaptive statistics of literals and of literal-length, match-length and
# offset codes. Every DP state carries the decoder's repeat-offset history, so
# repeat-offset matches are priced exactly as they will be encoded. Match
# candidates come from the repeat offsets plus a binary tree of suffixes, which
# yields every strictly longer match.

const OPT_NUM = 4096
const MAX_PRICE = typemax(Int) >> 2
const BITCOST = 256

const LL_FREQ_BASE = Int[4, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                         1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
const OF_FREQ_BASE = Int[6, 2, 1, 1, 2, 3, 4, 4, 4, 3, 2, 1, 1, 1, 1, 1,
                         1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]

mutable struct OptState
    # DP arrays, index = position + 1
    price::Vector{Int}
    mlen::Vector{Int}
    off::Vector{Int}
    litlen::Vector{Int}
    r1::Vector{Int}
    r2::Vector{Int}
    r3::Vector{Int}
    # match candidates
    mlens::Vector{Int}
    moffs::Vector{Int}
    # statistics and derived prices
    litf::Vector{Int}; llf::Vector{Int}; mlf::Vector{Int}; off_f::Vector{Int}
    litp::Vector{Int}; llp::Vector{Int}; mlp::Vector{Int}; ofp::Vector{Int}
    have_stats::Bool
    # backtracking
    bt_start::Vector{Int}; bt_ml::Vector{Int}; bt_off::Vector{Int}
end

function OptState()
    n = OPT_NUM + 2
    OptState(zeros(Int, n), zeros(Int, n), zeros(Int, n), zeros(Int, n), zeros(Int, n), zeros(Int, n),
             zeros(Int, n), zeros(Int, 1024), zeros(Int, 1024),
             zeros(Int, 256), zeros(Int, 36), zeros(Int, 53), zeros(Int, 32),
             zeros(Int, 256), zeros(Int, 36), zeros(Int, 53), zeros(Int, 32), false,
             zeros(Int, n), zeros(Int, n), zeros(Int, n))
end

function scale_stats!(f::Vector{Int}, target_log::Int)
    s = sum(f)
    factor = s >> target_log
    factor <= 1 && return f
    sh = highbit(factor)
    @inbounds for i in eachindex(f)
        f[i] = 1 + (f[i] >> sh)
    end
    return f
end

function compute_prices!(p::Vector{Int}, f::Vector{Int})
    s = sum(f)
    ls = log2(s)
    @inbounds for i in eachindex(f)
        p[i] = round(Int, BITCOST * (ls - log2(f[i])))
    end
    return p
end

function update_prices!(o::OptState)
    compute_prices!(o.litp, o.litf)
    compute_prices!(o.llp, o.llf)
    compute_prices!(o.mlp, o.mlf)
    compute_prices!(o.ofp, o.off_f)
end

"""Initialize statistics for a block starting at `src` (n bytes)."""
function init_stats!(o::OptState, src::Ptr{UInt8}, n::Int)
    if !o.have_stats
        fill!(o.litf, 0)
        for i in 1:n
            o.litf[Int(unsafe_load(src, i)) + 1] += 1
        end
        @inbounds for i in 1:256
            o.litf[i] = 1 + (o.litf[i] >> 4)
        end
        copyto!(o.llf, LL_FREQ_BASE)
        fill!(o.mlf, 1)
        copyto!(o.off_f, OF_FREQ_BASE)
        o.have_stats = true
    else
        scale_stats!(o.litf, 11)
        scale_stats!(o.llf, 10)
        scale_stats!(o.mlf, 10)
        scale_stats!(o.off_f, 10)
    end
    update_prices!(o)
    return o
end

@inline function ll_price(o::OptState, ll::Int)
    c = ll_code(ll)
    return @inbounds o.llp[c + 1] + Int(LL_BITS[c + 1]) * BITCOST
end

@inline function match_price(o::OptState, offbase::Int, ml::Int, ultra::Bool)
    ofc = highbit(offbase)
    mlc = ml_code(ml - MIN_MATCH)
    pr = @inbounds o.ofp[ofc + 1] + ofc * BITCOST + o.mlp[mlc + 1] + Int(ML_BITS[mlc + 1]) * BITCOST
    # favor decompression speed: handicap very long distances (as btopt does)
    (!ultra && ofc >= 20) && (pr += (ofc - 19) * 2 * BITCOST)
    return pr
end

@inline function offbase_of(dist::Int, r1::Int, r2::Int, r3::Int, ll0::Bool)
    if !ll0
        return dist == r1 ? 1 : dist == r2 ? 2 : dist == r3 ? 3 : dist + 3
    else
        return dist == r2 ? 1 : dist == r3 ? 2 : dist == r1 - 1 ? 3 : dist + 3
    end
end

# Decoder repeat-offset update for a sequence with this offset value.
@inline function rep_after(dist::Int, offbase::Int, ll0::Bool, r1::Int, r2::Int, r3::Int)
    offbase > 3 && return dist, r1, r2
    idx = offbase + ll0
    idx == 1 && return r1, r2, r3
    idx == 2 && return dist, r1, r3
    return dist, r1, r2
end

function record_sequence!(o::OptState, lits::Ptr{UInt8}, ll::Int, offbase::Int, ml::Int)
    @inbounds begin
        for i in 1:ll
            o.litf[Int(unsafe_load(lits, i)) + 1] += 2
        end
        o.llf[ll_code(ll) + 1] += 1
        o.mlf[ml_code(ml - MIN_MATCH) + 1] += 1
        o.off_f[highbit(offbase) + 1] += 1
    end
end

# ---------------------------------------------------------------------------
# Binary-tree match finder (after ZSTD_insertBt1 / ZSTD_insertBtAndGetAllMatches)
# The tree lives in `ctab`: position i owns slots 2*(i & btmask)+1 (smaller
# subtree) and 2*(i & btmask)+2 (larger subtree). Slot 0 means "no slot".
# ---------------------------------------------------------------------------

"""Insert position ip into the tree. Returns how many positions may be skipped."""
@inline function bt_insert1!(ht::Ptr{Int32}, bt::Ptr{Int32}, hlog::Int, btlog::Int, mls::Int,
                             attempts::Int, base::Ptr{UInt8}, ip::Ptr{UInt8}, iend::Ptr{UInt8},
                             lowlimit::Int)
    cur = pos_of(ip, base)
    h = zhash(ip, hlog, mls) + 1
    midx = Int(unsafe_load(ht, h))
    unsafe_store!(ht, cur % Int32, h)
    btmask = (1 << btlog) - 1
    btlow = btmask >= cur ? 0 : cur - btmask
    sm = 2 * (cur & btmask) + 1
    lg = sm + 1
    match_end = cur + 9
    best = 8
    cls = 0; cll = 0
    while attempts > 0 && midx >= lowlimit
        attempts -= 1
        nxt = 2 * (midx & btmask) + 1
        ml = min(cls, cll)
        m = ptr_of(midx, base)
        ml += zcount(ip + ml, m + ml, iend)
        if ml > best
            best = ml
            ml > match_end - midx && (match_end = midx + ml)
        end
        ip + ml == iend && break
        if unsafe_load(m + ml) < unsafe_load(ip + ml)
            unsafe_store!(bt, midx % Int32, sm)
            cls = ml
            if midx <= btlow
                sm = 0; break
            end
            sm = nxt + 1
            midx = Int(unsafe_load(bt, nxt + 1))
        else
            unsafe_store!(bt, midx % Int32, lg)
            cll = ml
            if midx <= btlow
                lg = 0; break
            end
            lg = nxt
            midx = Int(unsafe_load(bt, nxt))
        end
    end
    sm != 0 && unsafe_store!(bt, Int32(0), sm)
    lg != 0 && unsafe_store!(bt, Int32(0), lg)
    skip = best > 384 ? min(192, best - 384) : 0
    return max(skip, match_end - (cur + 8))
end

"""Collect matches at ip with strictly increasing lengths (repeat offsets first)."""
@inline function collect_matches!(o::OptState, ht::Ptr{Int32}, bt::Ptr{Int32}, hlog::Int, clog::Int,
                                  mls::Int, attempts::Int, base::Ptr{UInt8}, ip::Ptr{UInt8},
                                  iend::Ptr{UInt8}, lowlimit::Int, next::Int,
                                  r1::Int, r2::Int, r3::Int, ll0::Bool)
    cur = pos_of(ip, base)
    cur < next && return 0, next            # inside a region skipped by the tree update
    btlog = clog - 1
    # Bring the tree up to date. Long repetitive matches let insertion skip
    # ahead, but the current position is always searched (ZSTD_updateTree).
    while next < cur
        next += bt_insert1!(ht, bt, hlog, btlog, mls, attempts, base, ptr_of(next, base), iend, lowlimit)
    end
    nm = 0
    best = mls - 1
    mlens = o.mlens; moffs = o.moffs
    @inbounds for k in 1:3
        dist = ll0 ? (k == 1 ? r2 : k == 2 ? r3 : r1 - 1) : (k == 1 ? r1 : k == 2 ? r2 : r3)
        (dist < 1 || cur - dist < lowlimit) && continue
        l = zcount(ip, ip - dist, iend)
        if l >= mls && l > best
            nm += 1; mlens[nm] = l; moffs[nm] = dist; best = l
        end
    end
    # insert ip into the tree while collecting longer matches
    h = zhash(ip, hlog, mls) + 1
    midx = Int(unsafe_load(ht, h))
    unsafe_store!(ht, cur % Int32, h)
    btmask = (1 << btlog) - 1
    btlow = btmask >= cur ? 0 : cur - btmask
    sm = 2 * (cur & btmask) + 1
    lg = sm + 1
    match_end = cur + 9
    cls = 0; cll = 0
    @inbounds while attempts > 0 && midx >= lowlimit
        attempts -= 1
        nxt = 2 * (midx & btmask) + 1
        ml = min(cls, cll)
        m = ptr_of(midx, base)
        ml += zcount(ip + ml, m + ml, iend)
        if ml > best
            ml > match_end - midx && (match_end = midx + ml)
            best = ml
            nm += 1; mlens[nm] = ml; moffs[nm] = cur - midx
            (ml > OPT_NUM || nm == length(mlens)) && break
        end
        # Stop at the end of the block whether or not this match is a new best:
        # ordering it by the byte past the end would break the tree (libzstd
        # never gets here, as it returns once a repcode reaches the end).
        ip + ml == iend && break
        if unsafe_load(m + ml) < unsafe_load(ip + ml)
            unsafe_store!(bt, midx % Int32, sm)
            cls = ml
            if midx <= btlow
                sm = 0; break
            end
            sm = nxt + 1
            midx = Int(unsafe_load(bt, nxt + 1))
        else
            unsafe_store!(bt, midx % Int32, lg)
            cll = ml
            if midx <= btlow
                lg = 0; break
            end
            lg = nxt
            midx = Int(unsafe_load(bt, nxt))
        end
    end
    sm != 0 && unsafe_store!(bt, Int32(0), sm)
    lg != 0 && unsafe_store!(bt, Int32(0), lg)
    return nm, match_end - 8
end

@inline function set_state!(o::OptState, i::Int, price::Int, ml::Int, dist::Int, ll::Int,
                            r1::Int, r2::Int, r3::Int)
    @inbounds begin
        o.price[i] = price; o.mlen[i] = ml; o.off[i] = dist; o.litlen[i] = ll
        o.r1[i] = r1; o.r2[i] = r2; o.r3[i] = r3
    end
end

"""
Optimal parse of [istart, iend). `rep` is the decoder's exact repeat-offset
state at the block start. Returns the updated `next_to_update`.
"""
function parse_opt!(ss::SeqStore, o::OptState, htab::Vector{Int32}, hlog::Int, ctab::Vector{Int32},
                    clog::Int, mls::Int, attempts::Int, sufficient::Int, ultra::Bool,
                    base::Ptr{UInt8}, istart::Ptr{UInt8}, iend::Ptr{UInt8}, lowlimit::Int,
                    rep::NTuple{3,Int}, next::Int, first::Bool=true)
    ilimit = iend - HASH_READ_SIZE
    anchor = istart
    ip = istart
    ip == base && (ip += 1)
    r1, r2, r3 = rep
    sufficient = min(sufficient, OPT_NUM - 1)
    (first || !o.have_stats) && init_stats!(o, istart, Int(iend - istart))
    price = o.price; mlen = o.mlen; offv = o.off; litlen = o.litlen
    GC.@preserve htab ctab o begin
        ht = pointer(htab); ch = pointer(ctab)
        while ip < ilimit
            litlen0 = Int(ip - anchor)
            ll0 = litlen0 == 0
            nm, next = collect_matches!(o, ht, ch, hlog, clog, mls, attempts, base, ip, iend,
                                        lowlimit, next, r1, r2, r3, ll0)
            if nm == 0
                ip += 1
                continue
            end
            nb = 0
            last_pos = 0
            forced = false
            fcur = 0; flen = 0; foff = 0
            longest = o.mlens[nm]
            if longest > sufficient
                forced = true; fcur = 0; flen = longest; foff = o.moffs[nm]
            else
                # --- initialize the DP from the matches at ip
                set_state!(o, 1, ll_price(o, litlen0), 0, 0, litlen0, r1, r2, r3)
                @inbounds for q in 1:mls-1
                    price[q + 1] = MAX_PRICE; mlen[q + 1] = 0
                end
                bp = price[1] + ll_price(o, 0)
                q = mls
                @inbounds for k in 1:nm
                    len = o.mlens[k]; dist = o.moffs[k]
                    ob = offbase_of(dist, r1, r2, r3, ll0)
                    n1, n2, n3 = rep_after(dist, ob, ll0, r1, r2, r3)
                    while q <= len
                        set_state!(o, q + 1, bp + match_price(o, ob, q, ultra), q, dist, 0, n1, n2, n3)
                        q += 1
                    end
                end
                last_pos = q - 1
                # --- forward pass
                cur = 1
                @inbounds while cur <= last_pos
                    # literal transition from cur-1
                    ll = litlen[cur] + 1
                    lp = price[cur] + o.litp[Int(unsafe_load(ip, cur)) + 1] +
                         ll_price(o, ll) - ll_price(o, ll - 1)
                    if lp <= price[cur + 1]
                        set_state!(o, cur + 1, lp, 0, 0, ll, o.r1[cur], o.r2[cur], o.r3[cur])
                    end
                    cur == last_pos && break
                    if !ultra && price[cur + 2] <= price[cur + 1] + (BITCOST >> 1)
                        cur += 1
                        continue
                    end
                    inr = ip + cur
                    if inr >= ilimit
                        cur += 1
                        continue
                    end
                    sll0 = mlen[cur + 1] != 0
                    s1 = o.r1[cur + 1]; s2 = o.r2[cur + 1]; s3 = o.r3[cur + 1]
                    nm2, next = collect_matches!(o, ht, ch, hlog, clog, mls, attempts, base, inr,
                                                 iend, lowlimit, next, s1, s2, s3, sll0)
                    if nm2 == 0
                        cur += 1
                        continue
                    end
                    lg = o.mlens[nm2]
                    if lg > sufficient || cur + lg >= OPT_NUM
                        forced = true; fcur = cur; flen = lg; foff = o.moffs[nm2]
                        break
                    end
                    bp2 = price[cur + 1] + ll_price(o, 0)
                    for k in 1:nm2
                        len = o.mlens[k]; dist = o.moffs[k]
                        ob = offbase_of(dist, s1, s2, s3, sll0)
                        n1, n2, n3 = rep_after(dist, ob, sll0, s1, s2, s3)
                        startml = k == 1 ? mls : o.mlens[k - 1] + 1
                        ml = len
                        while ml >= startml
                            p = cur + ml
                            pr = bp2 + match_price(o, ob, ml, ultra)
                            if p > last_pos || pr < price[p + 1]
                                while last_pos < p
                                    last_pos += 1
                                    price[last_pos + 1] = MAX_PRICE; mlen[last_pos + 1] = 0
                                end
                                set_state!(o, p + 1, pr, ml, dist, 0, n1, n2, n3)
                            elseif !ultra
                                break
                            end
                            ml -= 1
                        end
                    end
                    cur += 1
                end
                # --- backtrack the cheapest path
                endpos = forced ? fcur : last_pos
                if !forced
                    while endpos > 0 && mlen[endpos + 1] == 0
                        endpos -= 1
                    end
                end
                p = endpos
                @inbounds while p > 0
                    m = mlen[p + 1]
                    if m == 0
                        p -= 1
                        continue
                    end
                    nb += 1
                    o.bt_start[nb] = p - m; o.bt_ml[nb] = m; o.bt_off[nb] = offv[p + 1]
                    p -= m
                end
            end
            chunk_end = forced ? ip + fcur + flen : ip + last_pos
            # --- emit sequences in order
            nseqs = nb + (forced ? 1 : 0)
            for j in 1:nseqs
                if j <= nb
                    k = nb - j + 1
                    start = ip + o.bt_start[k]; ml = o.bt_ml[k]; dist = o.bt_off[k]
                else
                    start = ip + fcur; ml = flen; dist = foff
                end
                ll = Int(start - anchor)
                ob = offbase_of(dist, r1, r2, r3, ll == 0)
                record_sequence!(o, anchor, ll, ob, ml)
                r1, r2, r3 = rep_after(dist, ob, ll == 0, r1, r2, r3)
                store_seq!(ss, anchor, ll, dist, ml)
                anchor = start + ml
            end
            # Positions up to last_pos were searched (and inserted); literals after
            # the last chosen match stay pending, as in the reference.
            ip = max(anchor, chunk_end)
            update_prices!(o)
        end
    end
    store_last_literals!(ss, anchor, Int(iend - anchor))
    return next
end
