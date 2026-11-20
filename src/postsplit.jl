# Block post-splitting for btopt and stronger (libzstd's
# ZSTD_compressBlock_splitBlock / ZSTD_deriveBlockSplits): after parsing a
# block, recursively halve its sequences while encoding the halves separately
# is cheaper than encoding them together, then emit each part as its own block.
# Costs are measured by trial encodes from the block's starting entropy state.
# Sequences hold raw match distances, so any split is valid as is. Included in
# module Encoder.

const MIN_SEQUENCES_BLOCK_SPLITTING = 300
const MAX_NB_BLOCK_SPLITS = 196

mutable struct SplitState
    sub::SeqStore                 # one partition's sequences
    scratch::Vector{UInt8}        # trial encodes
    ll::FSECTable; ml::FSECTable; of::FSECTable; huf::HufCTable   # saved "previous" tables
    splits::Vector{Int}
    litstart::Vector{Int}         # literal offset before sequence i (i = 1..nseq+1)
    srcstart::Vector{Int}         # source offset before sequence i
end
SplitState() = SplitState(SeqStore(), zeros(UInt8, 2 * BLOCK_SIZE_MAX + 1024),
                          FSECTable(), FSECTable(), FSECTable(), HufCTable(), Int[], Int[], Int[])

function copy_huf!(dst::HufCTable, src::HufCTable)
    dst.maxsym = src.maxsym; dst.tl = src.tl
    copyto!(dst.nbits, src.nbits); copyto!(dst.code, src.code)
    return dst
end

"""Copy sequences [a, b) of `ss` (with their literals; the block's trailing literals if `tail`) into `sub`."""
function sub_seqstore!(sub::SeqStore, ss::SeqStore, st::SplitState, a::Int, b::Int, tail::Bool)
    k = b - a
    copyto!(sub.ll, 1, ss.ll, a, k); copyto!(sub.ml, 1, ss.ml, a, k); copyto!(sub.off, 1, ss.off, a, k)
    sub.nseq = k
    l0 = st.litstart[a]
    l1 = tail ? ss.nlit : st.litstart[b]
    copyto!(sub.lit, 1, ss.lit, l0 + 1, l1 - l0)
    sub.nlit = l1 - l0
    return sub
end

"""Encoded size of sequences [a, b) from the current entropy state, which is left unchanged."""
function trial_cost(cc, st::SplitState, a::Int, b::Int, tail::Bool)
    ss = cc.ss
    sub = sub_seqstore!(st.sub, ss, st, a, b, tail)
    # save the entropy state (encoders swap and overwrite tables)
    rep = cc.rep
    ll_t, ll_p, ml_t, ml_p, of_t, of_p, h, hp = cc.ll_t, cc.ll_prev, cc.ml_t, cc.ml_prev, cc.of_t, cc.of_prev, cc.huf, cc.huf_prev
    oks = (cc.ll_prev_ok, cc.ml_prev_ok, cc.of_prev_ok, cc.huf_prev_ok)
    oks[1] && copy_ctable!(st.ll, ll_p); oks[2] && copy_ctable!(st.ml, ml_p)
    oks[3] && copy_ctable!(st.of, of_p); oks[4] && copy_huf!(st.huf, hp)
    cc.ss = sub
    q = encode_literals!(cc, st.scratch, 1, sub.lit, sub.nlit)
    q = encode_sequences!(cc, st.scratch, q)
    cc.ss = ss
    cc.rep = rep
    cc.ll_t, cc.ll_prev, cc.ml_t, cc.ml_prev, cc.of_t, cc.of_prev, cc.huf, cc.huf_prev = ll_t, ll_p, ml_t, ml_p, of_t, of_p, h, hp
    cc.ll_prev_ok, cc.ml_prev_ok, cc.of_prev_ok, cc.huf_prev_ok = oks
    oks[1] && copy_ctable!(ll_p, st.ll); oks[2] && copy_ctable!(ml_p, st.ml)
    oks[3] && copy_ctable!(of_p, st.of); oks[4] && copy_huf!(hp, st.huf)
    return q - 1 + 3
end

function derive_splits!(cc, st::SplitState, a::Int, b::Int, nseq::Int)
    (b - a < MIN_SEQUENCES_BLOCK_SPLITTING || length(st.splits) >= MAX_NB_BLOCK_SPLITS) && return
    mid = (a + b) ÷ 2
    whole = trial_cost(cc, st, a, b, b == nseq + 1)
    first = trial_cost(cc, st, a, mid, false)
    second = trial_cost(cc, st, mid, b, b == nseq + 1)
    if first + second < whole
        derive_splits!(cc, st, a, mid, nseq)
        push!(st.splits, mid)
        derive_splits!(cc, st, mid, b, nseq)
    end
    return
end

"""
Split the parsed block (cc.ss, source [bstart, bstart+n)) if that pays, and
emit its parts. Returns the new output position, or 0 when not split.
"""
function emit_split_block!(cc, out::Vector{UInt8}, pos::Int,
                           bstart::Ptr{UInt8}, n::Int, last::Bool)
    ss = cc.ss
    nseq = ss.nseq
    nseq < MIN_SEQUENCES_BLOCK_SPLITTING && return 0
    st = cc.split
    resize!(st.litstart, nseq + 1); resize!(st.srcstart, nseq + 1)
    l = 0; s = 0
    @inbounds for i in 1:nseq
        st.litstart[i] = l; st.srcstart[i] = s
        l += Int(ss.ll[i]); s += Int(ss.ll[i]) + Int(ss.ml[i])
    end
    st.litstart[nseq + 1] = l; st.srcstart[nseq + 1] = s
    empty!(st.splits)
    derive_splits!(cc, st, 1, nseq + 1, nseq)
    isempty(st.splits) && return 0
    push!(st.splits, nseq + 1)
    full = ss
    a = 1
    for (k, b) in enumerate(st.splits)
        tail = k == length(st.splits)
        sub = sub_seqstore!(st.sub, full, st, a, b, tail)
        src0 = st.srcstart[a]
        src1 = tail ? n : st.srcstart[b]
        cc.ss = sub
        try
            pos = emit_parsed_block!(cc, out, pos, bstart + src0, src1 - src0, last && tail)
        finally
            cc.ss = full
        end
        a = b
    end
    return pos
end

"""
Split the parsed block so each part encodes to about `target` bytes (libzstd's
ZSTD_c_targetCBlockSize, without its super-block encoding): parts of equal
input size, as many as the block's trial cost needs. Returns the new output
position, or 0 when the block already fits.
"""
function emit_target_blocks!(cc, out::Vector{UInt8}, pos::Int, bstart::Ptr{UInt8}, n::Int,
                             last::Bool, target::Int)
    ss = cc.ss
    nseq = ss.nseq
    nseq < 2 && return 0
    cc.split === nothing && (cc.split = SplitState())
    st = cc.split
    resize!(st.litstart, nseq + 1); resize!(st.srcstart, nseq + 1)
    l = 0; s = 0
    @inbounds for i in 1:nseq
        st.litstart[i] = l; st.srcstart[i] = s
        l += Int(ss.ll[i]); s += Int(ss.ll[i]) + Int(ss.ml[i])
    end
    st.litstart[nseq + 1] = l; st.srcstart[nseq + 1] = s
    whole = trial_cost(cc, st, 1, nseq + 1, true)
    whole <= target && return 0
    k = min(cld(whole, target), nseq)
    empty!(st.splits)
    i = 1
    for part in 1:k-1
        goal = n * part ÷ k
        while i <= nseq && st.srcstart[i] < goal; i += 1; end
        (i > 1 && (isempty(st.splits) || i > st.splits[end]) && i <= nseq) && push!(st.splits, i)
    end
    isempty(st.splits) && return 0
    push!(st.splits, nseq + 1)
    full = ss
    a = 1
    for (j, b) in enumerate(st.splits)
        tail = j == length(st.splits)
        sub = sub_seqstore!(st.sub, full, st, a, b, tail)
        src0 = st.srcstart[a]
        src1 = tail ? n : st.srcstart[b]
        cc.ss = sub
        try
            pos = emit_parsed_block!(cc, out, pos, bstart + src0, src1 - src0, last && tail)
        finally
            cc.ss = full
        end
        a = b
    end
    return pos
end
