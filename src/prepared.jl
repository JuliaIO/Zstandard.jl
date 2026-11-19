# Prepared (digested) dictionaries, after libzstd's ZSTD_CDict. Included in
# module Encoder.
#
# Compressing with a plain ZstdDictionary hashes the whole dictionary content
# into the match-finder tables and rebuilds its entropy tables on every call,
# which dominates the cost for small inputs. A PreparedDictionary does that
# once for a given level; each compression then only copies the tables.

"""Input size a prepared dictionary's tables are sized for (dictionary plus
this many bytes), like libzstd's CDicts, which are sized for small inputs.
Inputs for which dictionary + input exceed the prepared window get parameters
sized to the input and load the dictionary content afresh instead."""
const PREPARED_DICT_SRC_HINT = 16 << 10

"""
    PreparedDictionary

A dictionary digested for compression at one level: match-finder tables with
the dictionary content inserted, and its entropy tables, ready to be copied
into a compression context. Create with [`prepare_dictionary`](@ref).
Read-only after creation, so it can be shared between tasks.
"""
struct PreparedDictionary
    dict::ZstdDictionary
    level::Int
    overrides::ParameterOverrides
    params::CParams
    htab::Vector{Int32}
    ctab::Vector{Int32}
    next_to_update::Int
    ll::FSECTable; ml::FSECTable; of::FSECTable
    huf::HufCTable
    has_entropy::Bool
end

Base.show(io::IO, pd::PreparedDictionary) =
    print(io, "PreparedDictionary(id=", pd.dict.id, ", ", length(pd.dict.content),
          " bytes of content, level ", pd.level, ")")

"""
    prepare_dictionary(dict::ZstdDictionary; level=3, params...) -> PreparedDictionary

Digest `dict` for compression at `level`. Pass the result as `dict` to
`compress`, `ZstdCompressorStream` or `ZstandardCompressor`; it compresses
small inputs much faster than the plain dictionary (the output is still
decoded with the plain `ZstdDictionary`). The level is fixed: compressing with
a different `level` throws an `ArgumentError`. Explicit compression parameters
(`window_log`, `hash_log`, ...; see [`parameter_overrides`](@ref)) are fixed
at preparation as well.
"""
function prepare_dictionary(dict::ZstdDictionary; level::Integer=3, kwargs...)
    level = Int(level)
    ov = parameter_overrides(; kwargs...)
    dlen = length(dict.content)
    p = compression_parameters(level, dlen + PREPARED_DICT_SRC_HINT, ov)
    if S_GREEDY <= p.strategy <= S_LAZY2
        # The tables are copied on every use, so keep them tight: a chain of
        # 2^window_log entries already covers every dictionary + input position.
        p = CParams(p.window_log,
                    ov.chain_log >= 0 ? p.chain_log : min(p.chain_log, p.window_log),
                    ov.hash_log >= 0 ? p.hash_log : min(p.hash_log, p.window_log),
                    p.search_log, p.min_match, p.target_length, p.strategy)
    end
    cc = CompressionContext()
    reset_context!(cc, p, level)
    apply_dict_entropy!(cc, dict)
    src = dict.content
    GC.@preserve src begin
        base = pointer(src)
        load_dict!(cc, base, dlen)           # fast / dfast tables
        # Hash-chain and binary-tree strategies insert positions lazily; do it
        # now for every position whose 8-byte read stays inside the content.
        last = dlen - HASH_READ_SIZE
        if last >= 1 && S_GREEDY <= p.strategy <= S_LAZY2
            mls = clamp(p.min_match, 4, 6)
            GC.@preserve cc begin
                rl = row_log(p)
                row_insert!(pointer(cc.htab), Ptr{UInt8}(pointer(cc.ctab)), p.hash_log - rl, rl, mls,
                            base, 1, last + 1)
            end
            cc.next_to_update = last + 1
        elseif last >= 1 && p.strategy >= S_BTLAZY2
            mls = p.strategy == S_BTLAZY2 ? clamp(p.min_match, 4, 6) : clamp(p.min_match, 3, 4)
            next = 1
            GC.@preserve cc begin
                while next <= last
                    next += bt_insert1!(pointer(cc.htab), pointer(cc.ctab), p.hash_log, p.chain_log - 1,
                                        mls, 1 << p.search_log, base, ptr_of(next, base), base + dlen, 1)
                end
            end
            cc.next_to_update = min(next, last + 1)
        end
    end
    tables = (FSECTable(), FSECTable(), FSECTable())
    copy_ctable!(tables[1], cc.ll_prev); copy_ctable!(tables[2], cc.ml_prev); copy_ctable!(tables[3], cc.of_prev)
    huf = HufCTable(cc.huf_prev.maxsym, cc.huf_prev.tl, copy(cc.huf_prev.nbits), copy(cc.huf_prev.code),
                    zeros(Int, 16), zeros(Int, 16))
    return PreparedDictionary(dict, level, ov, p, copy(cc.htab), copy(cc.ctab), cc.next_to_update,
                              tables..., huf, cc.huf_prev_ok)
end

"""Set up `cc` from a prepared dictionary (instead of reset_context! + loading the content)."""
function use_prepared!(cc::CompressionContext, pd::PreparedDictionary)
    p = pd.params
    reset_context!(cc, p, pd.level; clear=false)
    copyto!(cc.htab, pd.htab)
    if !isempty(pd.ctab)
        length(cc.ctab) != length(pd.ctab) && resize!(cc.ctab, length(pd.ctab))
        copyto!(cc.ctab, pd.ctab)
    end
    cc.next_to_update = pd.next_to_update
    d = pd.dict
    cc.rep = d.rep_offsets
    cc.prep1, cc.prep2 = d.rep_offsets[1], d.rep_offsets[2]
    if pd.has_entropy
        copy_ctable!(cc.ll_prev, pd.ll); copy_ctable!(cc.ml_prev, pd.ml); copy_ctable!(cc.of_prev, pd.of)
        cc.ll_prev_ok = cc.ml_prev_ok = cc.of_prev_ok = true
        h = cc.huf_prev
        h.maxsym = pd.huf.maxsym; h.tl = pd.huf.tl
        copyto!(h.nbits, pd.huf.nbits); copyto!(h.code, pd.huf.code)
        cc.huf_prev_ok = true
    end
    return cc
end

"""Whether `pd`'s tables should be used for an input of `n` bytes at `level`
(dictionary + input fit the prepared window); otherwise its dictionary is loaded normally."""
function use_prepared(pd::PreparedDictionary, n::Integer, level, ov::ParameterOverrides=NO_OVERRIDES)
    level === nothing || level == pd.level ||
        throw(ArgumentError("dictionary was prepared for level $(pd.level), not level $level"))
    ov === NO_OVERRIDES || ov == pd.overrides ||
        throw(ArgumentError("compression parameters are fixed by the prepared dictionary"))
    return 0 <= n && n + length(pd.dict.content) <= 1 << pd.params.window_log
end
