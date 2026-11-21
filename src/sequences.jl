# Sequence-level API (libzstd's ZSTD_generateSequences / ZSTD_compressSequences):
# get the matches the compressor finds, or encode matches found elsewhere.
# Included in module Zstandard.

"""
    ZstandardSequence(offset, literal_length, match_length)

One Zstandard sequence: `literal_length` literal bytes, then `match_length`
bytes copied from `offset` bytes back (as libzstd's `ZSTD_Sequence`, with
`offset` the actual distance, not a repeat-offset code). A sequence with
`offset == 0` and `match_length == 0` is a block delimiter: its literals end
the block.

!!! warning "Experimental"
    The sequence API mirrors an experimental libzstd feature
    (`ZSTD_generateSequences`, `ZSTD_compressSequences` and `ZSTD_Sequence`,
    available only with `ZSTD_STATIC_LINKING_ONLY`). It may change in a minor
    release of Zstandard.jl, for example to follow changes in libzstd.
"""
struct ZstandardSequence
    offset::Int
    literal_length::Int
    match_length::Int
end
Base.show(io::IO, s::ZstandardSequence) =
    print(io, "ZstandardSequence(", s.offset, ", ", s.literal_length, ", ", s.match_length, ")")

is_delimiter(s::ZstandardSequence) = s.offset == 0 && s.match_length == 0

"""
    generate_sequences(data; level=3, window_log, ...) -> Vector{ZstandardSequence}

The sequences the compressor finds for `data` at `level` (as libzstd's
`ZSTD_generateSequences`), block by block, each block ending with a
delimiter carrying its trailing literals. `compress_sequences(data, seqs)`
turns them back into a frame. Parameter keywords are those of
[`compress`](@ref).

!!! warning "Experimental"
    The sequence API mirrors an experimental libzstd feature
    (`ZSTD_generateSequences`, `ZSTD_compressSequences` and `ZSTD_Sequence`,
    available only with `ZSTD_STATIC_LINKING_ONLY`). It may change in a minor
    release of Zstandard.jl, for example to follow changes in libzstd.
"""
function generate_sequences(data::Union{AbstractVector{UInt8},AbstractString}; level::Integer=3,
                            window_log=nothing, hash_log=nothing, chain_log=nothing, search_log=nothing,
                            min_match=nothing, target_length=nothing, strategy=nothing)
    src = Vector{UInt8}(_bytes(data))
    n = length(src)
    ov = Encoder.parameter_overrides(; window_log, hash_log, chain_log, search_log, min_match, target_length, strategy)
    p = Encoder.compression_parameters(Int(level), n, ov)
    cc = CompressionContext()
    Encoder.reset_context!(cc, p, Int(level))
    seqs = ZstandardSequence[]
    bmax = Encoder.block_size(p)
    scratch = Vector{UInt8}(undef, 2 * bmax + 1024)
    GC.@preserve src begin
        base = pointer(src)
        off = 0
        while off < n
            # compress the block for real (into scratch), so block splitting
            # and repeat offsets evolve exactly as in `compress`
            bn = Encoder.next_block_size(cc, base + off, n - off, bmax)
            Encoder.compress_block!(cc, scratch, 1, base, base + off, base + off + bn, off + bn == n)
            ss = cc.ss
            used = 0
            @inbounds for i in 1:ss.nseq
                ll = Int(ss.ll[i]); ml = Int(ss.ml[i])
                push!(seqs, ZstandardSequence(Int(ss.off[i]), ll, ml))
                used += ll + ml
            end
            push!(seqs, ZstandardSequence(0, bn - used, 0))
            off += bn
        end
    end
    return seqs
end

# Group sequences into blocks of at most `bmax` content bytes. Returns
# (list of (offset, literal_length, match_length), trailing literals) per
# block. With explicit delimiters the blocks are those given; otherwise
# sequences are split at block boundaries and bytes after the last sequence
# are trailing literals (libzstd's ZSTD_sf_noBlockDelimiters).
function _sequence_blocks(seqs::AbstractVector{ZstandardSequence}, n::Int, bmax::Int, explicit::Bool)
    blocks = Tuple{Vector{NTuple{3,Int}},Int}[]
    cur = NTuple{3,Int}[]
    fill = 0                     # content bytes in the current block
    lits = 0                     # pending literals (before the next match)
    total = 0
    finish!() = (push!(blocks, (cur, lits)); cur = NTuple{3,Int}[]; fill = 0; lits = 0)
    function add_literals!(ll)
        while ll > 0
            k = min(ll, bmax - fill)
            lits += k; fill += k; ll -= k
            ll > 0 && finish!()
        end
    end
    for (i, s) in enumerate(seqs)
        (s.literal_length < 0 || s.match_length < 0 || s.offset < 0) &&
            throw(ArgumentError("sequence $i has a negative field"))
        ll = s.literal_length; ml = s.match_length; off = s.offset
        # Reject as soon as the sequences cover more than the data: this bounds
        # every later sum by n (no wrapping) and the splitting work below.
        (ll > n - total || ml > n - total - ll) &&
            throw(ArgumentError("the sequences up to sequence $i cover more than the $n bytes of data"))
        if is_delimiter(s)
            explicit || throw(ArgumentError("sequence $i: unexpected block delimiter"))
            fill + ll > bmax && throw(ArgumentError("block ending at sequence $i exceeds $bmax bytes"))
            lits += ll; total += ll
            finish!()
            continue
        end
        (ml < 3 || off == 0) && throw(ArgumentError("sequence $i: a match needs offset >= 1 and match_length >= 3"))
        total += ll + ml
        if explicit
            fill + ll + ml > bmax && throw(ArgumentError("block containing sequence $i exceeds $bmax bytes"))
            push!(cur, (off, ll, ml)); fill += ll + ml
            continue
        end
        add_literals!(ll)
        while ml > 0
            room = bmax - fill
            if ml <= room
                push!(cur, (off, lits, ml)); fill += ml; lits = 0; ml = 0
            elseif room >= 3 && ml - room >= 3
                push!(cur, (off, lits, room)); lits = 0; ml -= room; finish!()
            elseif room >= 6
                push!(cur, (off, lits, room - 3)); lits = 0; ml -= room - 3; finish!()
            else
                finish!()            # too little room: the match starts the next block
            end
        end
    end
    if explicit
        (!isempty(cur) || lits > 0) && throw(ArgumentError("the last block has no delimiter"))
        total == n || throw(ArgumentError("the sequences cover $total bytes, the data has $n"))
    else
        total > n && throw(ArgumentError("the sequences cover $total bytes, the data has $n"))
        add_literals!(n - total)
        finish!()
    end
    isempty(blocks) && push!(blocks, (NTuple{3,Int}[], 0))
    return blocks
end

"""
    compress_sequences(data, seqs::AbstractVector{ZstandardSequence}; level=3, checksum=false,
                       validate=true) -> Vector{UInt8}

Encode `data`, described by the sequences `seqs` (as libzstd's
`ZSTD_compressSequences`), into a Zstandard frame: the literals come from
`data`, matches from the sequences. If `seqs` contains block delimiters
(see [`ZstandardSequence`](@ref)), they set the blocks (each at most 128 KiB) and
must cover `data` exactly; otherwise blocks of 128 KiB are formed, splitting
sequences as needed, and bytes after the last sequence are literals (as
libzstd's `ZSTD_sf_explicitBlockDelimiters` and `ZSTD_sf_noBlockDelimiters`).
With `validate=true` every match is also
checked against `data` (otherwise a wrong match silently changes what the
frame decodes to). `level` selects the entropy coding effort.

!!! warning "Experimental"
    The sequence API mirrors an experimental libzstd feature
    (`ZSTD_generateSequences`, `ZSTD_compressSequences` and `ZSTD_Sequence`,
    available only with `ZSTD_STATIC_LINKING_ONLY`). It may change in a minor
    release of Zstandard.jl, for example to follow changes in libzstd.
"""
function compress_sequences(data::Union{AbstractVector{UInt8},AbstractString}, seqs::AbstractVector{ZstandardSequence};
                            level::Integer=3, checksum::Bool=false, validate::Bool=true)
    src = Vector{UInt8}(_bytes(data))
    n = length(src)
    maxoff = maximum((s.offset for s in seqs); init=0)
    # the window must reach the farthest match; blocks need not be smaller than 128 KiB
    wlog = max(10, 64 - leading_zeros(UInt64(max(maxoff, 1) - 1)), min(17, 64 - leading_zeros(UInt64(max(n, 2) - 1))))
    wlog <= 31 || throw(ArgumentError("offsets too large"))
    p0 = Encoder.compression_parameters(Int(level), n)
    p = Encoder.CParams(wlog, p0.chain_log, p0.hash_log, p0.search_log, p0.min_match, p0.target_length, p0.strategy)
    bmax = Encoder.block_size(p)
    explicit = any(is_delimiter, seqs)
    blocks = _sequence_blocks(seqs, n, bmax, explicit)
    cc = CompressionContext()
    Encoder.reset_context!(cc, p, Int(level))
    out = Vector{UInt8}(undef, n + (n >> 7) + 64 + 3 * (length(blocks) + 1))
    pos = Encoder.write_frame_header!(out, 1, n, wlog, checksum)
    GC.@preserve src begin
        base = pointer(src)
        at = 0                                      # 0-based position in src
        for (b, (lst, trail)) in enumerate(blocks)
            bstart = at
            ss = cc.ss
            ss.nlit = 0; ss.nseq = 0
            ss.wlimit = C_NULL
            for (o, ll, ml) in lst
                o > at + ll && throw(ArgumentError("a match at byte $(at + ll + 1) reaches before the data (offset $o)"))
                if validate
                    for t in 0:ml-1
                        src[at + ll + t + 1] == src[at + ll + t + 1 - o] ||
                            throw(ArgumentError("the match at byte $(at + ll + 1) (offset $o, length $ml) does not match the data"))
                    end
                end
                Encoder.store_seq!(ss, base + at, ll, o, ml)
                at += ll + ml
            end
            Encoder.store_last_literals!(ss, base + at, trail)
            at += trail
            bn = at - bstart
            length(out) < pos + bn + 16 && resize!(out, pos + bn + 1024)
            b0 = bn > 3 ? src[bstart + 1] : 0x00
            if bn == 0
                pos = Encoder.write_block_header!(out, pos, b == length(blocks), 0, 0)
            elseif bn > 3 && all(==(b0), view(src, bstart+1:bstart+bn))
                # one repeated byte: an RLE block (the decoder's state is unchanged)
                pos = Encoder.write_block_header!(out, pos, b == length(blocks), 1, bn)
                out[pos] = b0; pos += 1
            else
                newpos = Encoder.emit_parsed_block!(cc, out, pos, base + bstart, bn, b == length(blocks))
                pos = newpos
            end
        end
    end
    if checksum
        h = content_checksum(src)
        length(out) < pos + 4 && resize!(out, pos + 4)
        for k in 0:3
            out[pos + k] = (h >> (8k)) % UInt8
        end
        pos += 4
    end
    return resize!(out, pos - 1)
end
