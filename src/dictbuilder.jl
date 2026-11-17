# Dictionary training (after libzstd's ZDICT: fastCover + entropy finalization).
# Included in module Encoder.

const DICT_MAGIC_W = 0xEC30A437

@inline fc_hash(p::Ptr{UInt8}, f::Int, d::Int) =
    d == 6 ? Int(((load64(p) << 16) * PRIME6) >> (64 - f)) : Int((load64(p) * PRIME8) >> (64 - f))

"""
Build dictionary content from `buf` (training samples concatenated; at least 8
bytes of padding after `ntrain`) with the fastCover algorithm. Returns the
content (most useful segments last).
"""
function fastcover_content(buf::Vector{UInt8}, ntrain::Int, capacity::Int, k::Int, d::Int, f::Int)
    nbdmers = ntrain - max(d, 8) + 1
    nbdmers < 1 && return UInt8[]
    freqs = zeros(UInt32, 1 << f)
    segfreqs = zeros(UInt16, 1 << f)
    dict = Vector{UInt8}(undef, capacity)
    tail = capacity
    GC.@preserve buf begin
        p = pointer(buf)
        @inbounds for i in 0:nbdmers-1
            freqs[fc_hash(p + i, f, d) + 1] += 1
        end
        # epochs (FASTCOVER_computeEpochs)
        num = max(1, capacity ÷ k)
        esize = nbdmers ÷ num
        min_epoch = k * 10
        if esize < min_epoch
            esize = min(min_epoch, nbdmers)
            num = max(1, nbdmers ÷ esize)
        end
        dmers_in_k = k - d + 1
        zero_run = 0
        epoch = 0
        @inbounds while tail > 0
            ebegin = epoch * esize
            eend = ebegin + esize
            epoch = (epoch + 1) % num
            # select the best segment of the epoch (FASTCOVER_selectSegment)
            best_b = 0; best_e = 0; best_s = UInt64(0)
            ab = ebegin; ae = ebegin; as = UInt64(0)
            while ae < eend
                idx = fc_hash(p + ae, f, d) + 1
                segfreqs[idx] == 0 && (as += freqs[idx])
                ae += 1
                segfreqs[idx] += 1
                if ae - ab == dmers_in_k + 1
                    di = fc_hash(p + ab, f, d) + 1
                    segfreqs[di] -= 1
                    segfreqs[di] == 0 && (as -= freqs[di])
                    ab += 1
                end
                if as > best_s
                    best_b = ab; best_e = ae; best_s = as
                end
            end
            while ab < eend
                segfreqs[fc_hash(p + ab, f, d) + 1] -= 1
                ab += 1
            end
            for q in best_b:best_e-1
                freqs[fc_hash(p + q, f, d) + 1] = 0
            end
            if best_s == 0
                zero_run += 1
                zero_run >= 10 && break
                continue
            end
            zero_run = 0
            seg = min(best_e - best_b + d - 1, tail)
            seg < d && break
            tail -= seg
            unsafe_copyto!(pointer(dict, tail + 1), p + best_b, seg)
        end
    end
    return dict[tail+1:end]
end

"""Parse `sample` with `content` as history and accumulate sequence statistics."""
function accumulate_stats!(cc::CompressionContext, content::Vector{UInt8}, sample::AbstractVector{UInt8},
                           level::Int, lit::Vector{Int}, llc::Vector{Int}, mlc::Vector{Int}, ofc::Vector{Int})
    dlen = length(content)
    n = length(sample)
    n == 0 && return
    src = Vector{UInt8}(undef, dlen + n)
    copyto!(src, 1, content, 1, dlen)
    copyto!(src, dlen + 1, sample, firstindex(sample), n)
    p = compression_parameters(level, n + dlen)
    reset_context!(cc, p, level)
    GC.@preserve src begin
        base = pointer(src)
        load_dict!(cc, base, dlen)
        off = dlen
        r1, r2, r3 = 1, 4, 8
        while off < dlen + n
            bn = min(BLOCK_SIZE_MAX, dlen + n - off)
            parse_block!(cc, base, base + off, base + off + bn)
            ss = cc.ss
            @inbounds for i in 1:ss.nlit
                lit[Int(ss.lit[i]) + 1] += 1
            end
            @inbounds for i in 1:ss.nseq
                ll = Int(ss.ll[i]); d = Int(ss.off[i]); ml = Int(ss.ml[i])
                ob = offbase_of(d, r1, r2, r3, ll == 0)
                r1, r2, r3 = rep_after(d, ob, ll == 0, r1, r2, r3)
                llc[ll_code(ll) + 1] += 1
                mlc[ml_code(ml - MIN_MATCH) + 1] += 1
                c = highbit(ob)
                c < length(ofc) && (ofc[c + 1] += 1)
            end
            cc.rep = (r1, r2, r3)
            off += bn
        end
    end
    return
end

"""
    finalize_dictionary(content, samples; level=3, dict_size=nothing, dict_id=nothing) -> Vector{UInt8}

Turn raw dictionary `content` into a formatted Zstandard dictionary: entropy
tables are built from statistics of compressing `samples` with the content
(as `ZDICT_finalizeDictionary`). The result is at most `dict_size` bytes
(content is trimmed from the front if needed).
"""
function finalize_dictionary(content::AbstractVector{UInt8}, samples::AbstractVector{<:AbstractVector{UInt8}};
                             level::Integer=3, dict_size::Union{Nothing,Integer}=nothing,
                             dict_id::Union{Nothing,Integer}=nothing)
    content = Vector{UInt8}(content)
    cap = dict_size === nothing ? length(content) + 1024 : Int(dict_size)
    offcode_max = highbit(cap + (128 << 10))
    lit = ones(Int, 256); llc = ones(Int, 36); mlc = ones(Int, 53); ofc = ones(Int, offcode_max + 1)
    cc = CompressionContext()
    for smp in samples
        accumulate_stats!(cc, content, smp, Int(level), lit, llc, mlc, ofc)
    end
    # entropy header
    hdr = zeros(UInt8, 2048)
    pos = 1
    for k in 0:3
        hdr[pos + k] = (DICT_MAGIC_W >> (8k)) % UInt8
    end
    pos += 8                                   # ID written below
    tl = huf_lengths!(cc.lens, lit, 255, HUF_MAX_BITS, cc.hsyms, cc.hfreq, cc.hparent)
    huf_codes!(cc.huf, cc.lens, 255, tl)
    pos = write_huf_tree!(cc, hdr, pos, cc.huf)
    pos == 0 && error("could not encode the dictionary Huffman table")
    norm = zeros(Int16, 256)
    for (counts, maxsym, al) in ((ofc, offcode_max, OF_MAX_AL), (mlc, 52, ML_MAX_AL), (llc, 35, LL_MAX_AL))
        normalize_counts!(norm, counts, sum(counts), maxsym, al)
        pos = write_fse_header!(hdr, pos, norm, maxsym, al)
    end
    for r in (1, 4, 8)
        for k in 0:3
            hdr[pos + k] = (UInt32(r) >> (8k)) % UInt8
        end
        pos += 4
    end
    hsize = pos - 1
    room = cap - hsize
    room < 8 && throw(ArgumentError("dict_size too small for the dictionary header"))
    length(content) > room && (content = content[end-room+1:end])
    length(content) < 8 && throw(ArgumentError("dictionary content must be at least 8 bytes"))
    id = dict_id === nothing ? UInt32(xxh64(content) % UInt64((1 << 31) - 32768) + 32768) : UInt32(dict_id)
    for k in 0:3
        hdr[5 + k] = (id >> (8k)) % UInt8
    end
    return vcat(hdr[1:hsize], content)
end

"""
    train_dictionary(samples; dict_size=112640, level=3, k=nothing, d=8) -> Vector{UInt8}

Train a formatted Zstandard dictionary from `samples` (a vector of byte
vectors) with the fastCover algorithm and entropy finalization, as
`zstd --train`. When `k` (segment size) is not given, several values are
tried and scored by compressing a held-out quarter of the samples.
Use the result with `parse_dictionary`.
"""
function train_dictionary(samples::AbstractVector{<:AbstractVector{UInt8}}; dict_size::Integer=112640,
                          level::Integer=3, k::Union{Nothing,Integer}=nothing, d::Integer=8, f::Integer=20)
    d in (6, 8) || throw(ArgumentError("d must be 6 or 8"))
    ns = length(samples)
    ns == 0 && throw(ArgumentError("no samples"))
    total = sum(length, samples)
    total < 64 && throw(ArgumentError("not enough sample data to train a dictionary"))
    ntrain_s = ns >= 4 ? max(1, (3ns) ÷ 4) : ns
    train = samples[1:ntrain_s]
    test = ns >= 4 ? samples[ntrain_s+1:end] : samples
    ntrain = sum(length, train)
    buf = Vector{UInt8}(undef, ntrain + 8)
    pos = 1
    for smp in train
        copyto!(buf, pos, smp, firstindex(smp), length(smp)); pos += length(smp)
    end
    fill!(view(buf, ntrain+1:ntrain+8), 0x00)
    cap = Int(dict_size)
    ks = k === nothing ? (50, 537, 1024, 1511, 1998) : (Int(k),)
    best = UInt8[]
    best_size = typemax(Int)
    cc = CompressionContext()
    for kk in ks
        kk > cap && continue
        content = fastcover_content(buf, ntrain, cap, kk, Int(d), Int(f))
        length(content) < 8 && continue
        if length(ks) == 1
            best = content; break
        end
        rd = ZstdDictionary(content)
        sz = 0
        for smp in test
            sz += length(compress_frame!(cc, smp, level; dict=rd))
        end
        if sz < best_size
            best_size = sz; best = content
        end
    end
    isempty(best) && throw(ArgumentError("could not build a dictionary from these samples"))
    return finalize_dictionary(best, samples; level, dict_size=cap)
end
