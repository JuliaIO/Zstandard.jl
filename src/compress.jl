module Compress

import ..Zstandard: MAGIC_NUMBER
import ..Frames: FrameHeader
import ..MatchFinder: find_sequences, Sequence, MatchContext
import ..EncodeSequences: encode_sequences
import ..EncodeHuffman: build_huffman_encoder, encode_huffman_literals
using XXHashNative

export compress

"""
Compute the smallest window descriptor byte where the decoded window_size >= n.
"""
function window_descriptor(n::Int)
    n <= 1024 && return UInt8(0)  # min window = 1KB (exponent=10)
    # Window_Size = (1 << exponent) + (mantissa * (1 << exponent)) ÷ 8
    # where exponent = wd >> 3, mantissa = wd & 0x07
    for exp in 10:41
        base = 1 << exp
        base >= n && return UInt8((exp - 10) << 3)
        for m in 1:7
            ws = base + (m * base) ÷ 8
            ws >= n && return UInt8(((exp - 10) << 3) | m)
        end
    end
    return UInt8(0xFF)  # max
end

function write_frame_header(io::IO, data_len::Int; checksum::Bool=false)
    write(io, UInt32(MAGIC_NUMBER))
    checksum_bit = checksum ? (1 << 2) : 0
    if data_len <= 255
        # Small data: single-segment with 1-byte FCS (most compact)
        fd = UInt8((0 << 6) | (1 << 5) | checksum_bit)
        write(io, fd)
        write(io, UInt8(data_len))
    else
        # Larger data: window descriptor, no FCS (matches libzstd default)
        fd = UInt8((0 << 6) | (0 << 5) | checksum_bit)
        write(io, fd)
        write(io, window_descriptor(data_len))
    end
end

const MAX_BLOCK_SIZE = 128 * 1024

# Cached MatchContext to avoid per-call allocation (~192KB).
# Not thread-safe; pass explicit `ctx` for concurrent use.
const _DEFAULT_CTX = Ref{Union{Nothing,MatchContext}}(nothing)

function _get_default_ctx(hash_log::Int)
    ctx = _DEFAULT_CTX[]
    if ctx !== nothing && ctx.hash_log == hash_log
        return ctx
    end
    ctx = MatchContext(hash_log=hash_log, max_block_size=MAX_BLOCK_SIZE)
    _DEFAULT_CTX[] = ctx
    return ctx
end

function compress(data::AbstractVector{UInt8}; level::Int=3, ctx::Union{Nothing,MatchContext}=nothing, checksum::Bool=false)
    io = IOBuffer(sizehint=length(data))
    write_frame_header(io, length(data); checksum=checksum)
    eff_level = (level == 0) ? 3 : level
    hash_log = 14
    search_depth = (eff_level == 1) ? 4 : (eff_level == 2) ? 16 : 64
    step = (eff_level < 0) ? (1 - eff_level) : 1

    if isempty(data)
        write_block_header(io, true, 0, 0)
    else
        mctx = if ctx !== nothing && ctx.hash_log == hash_log
            ctx
        else
            _get_default_ctx(hash_log)
        end

        # Run match finder on full data, then split sequences into blocks
        all_sequences = find_sequences(data, hash_log=hash_log, search_depth=search_depth, step=step, ctx=mctx)
        block_sequences = split_sequences_into_blocks(all_sequences, length(data), MAX_BLOCK_SIZE)

        rep_offsets = [1, 4, 8]
        data_pos = 1
        for (blk_idx, blk_seqs) in enumerate(block_sequences)
            chunk_end = min(data_pos + MAX_BLOCK_SIZE - 1, length(data))
            is_last = (chunk_end == length(data))
            chunk = view(data, data_pos:chunk_end)

            has_seqs = !isempty(blk_seqs) && !(length(blk_seqs) == 1 && blk_seqs[1].match_length == 0)

            if has_seqs
                saved_rep = copy(rep_offsets)
                block_io = IOBuffer()
                write_compressed_block_body(block_io, chunk, blk_seqs, rep_offsets=rep_offsets)
                block_bytes = take!(block_io)
                if length(block_bytes) < length(chunk)
                    write_block_header(io, is_last, 2, length(block_bytes))
                    write(io, block_bytes)
                else
                    rep_offsets .= saved_rep
                    write_block_header(io, is_last, 0, length(chunk))
                    write(io, chunk)
                end
            else
                write_block_header(io, is_last, 0, length(chunk))
                write(io, chunk)
            end
            data_pos = chunk_end + 1
        end
    end

    if checksum
        state = XXH64State()
        update!(state, data)
        write(io, UInt32(digest!(state) & 0xFFFFFFFF))
    end
    return take!(io)
end

compress(data::AbstractString; level::Int=3, checksum::Bool=false) = compress(codeunits(data), level=level, checksum=checksum)

function write_raw_blocks_content(io::IO, data::AbstractVector{UInt8})
    if isempty(data)
        write_block_header(io, true, 0, 0)
    else
        pos = 1
        while pos <= length(data)
            chunk_size = min(MAX_BLOCK_SIZE, length(data) - pos + 1)
            is_last = (pos + chunk_size > length(data))
            write_block_header(io, is_last, 0, chunk_size)
            write(io, view(data, pos:pos+chunk_size-1)); pos += chunk_size
        end
    end
end

function write_compressed_block_body(io::IO, data::AbstractVector{UInt8}, sequences::Vector{Sequence}; rep_offsets::Vector{Int}=[1, 4, 8])
    literals = gather_literals(data, sequences)
    write_literals_section(io, literals)
    encode_sequences(io, sequences, length(data), rep_offsets=rep_offsets)
end

function write_compressed_block_content(io::IO, is_last::Bool, data::AbstractVector{UInt8}, sequences::Vector{Sequence})
    block_io = IOBuffer()
    write_compressed_block_body(block_io, data, sequences)
    block_data = take!(block_io)
    write_block_header(io, is_last, 2, length(block_data))
    write(io, block_data)
end

function write_block_header(io::IO, last::Bool, type::Int, size::Int)
    header = UInt32(Int(last) | (type << 1) | (size << 3))
    write(io, UInt8(header & 0xFF)); write(io, UInt8((header >> 8) & 0xFF)); write(io, UInt8((header >> 16) & 0xFF))
end

"""
Split global sequences (from full-data match finding) into per-block sequences.
Each block covers up to `max_block` decompressed bytes.
Long matches spanning boundaries are split with a 1-byte literal at continuation
blocks to enable repeat offset encoding.
"""
function split_sequences_into_blocks(sequences::Vector{Sequence}, data_len::Int, max_block::Int)
    blocks = Vector{Sequence}[]
    current_block = Sequence[]
    block_used = 0  # bytes consumed in current block

    for seq in sequences
        ll = Int(seq.literal_length)
        ml = Int(seq.match_length)
        off = Int(seq.offset)
        seq_total = ll + ml

        if block_used + seq_total <= max_block
            # Sequence fits entirely in current block
            push!(current_block, seq)
            block_used += seq_total
        elseif block_used + ll <= max_block && ml > 0
            # Literals fit, match needs splitting
            remaining_space = max_block - block_used - ll
            if remaining_space >= 3
                # Split: put partial match in current block, rest in next
                push!(current_block, Sequence(UInt32(ll), UInt32(remaining_space), UInt32(off)))
                block_used += ll + remaining_space
                push!(blocks, current_block)
                current_block = Sequence[]
                block_used = 0

                leftover = ml - remaining_space
                # Split remaining bytes into max_block-sized chunks.
                # Each chunk: 1 literal byte (for repeat offset) + match bytes.
                # The 1 literal byte counts toward the chunk's output.
                while leftover > 0
                    chunk_total = min(leftover, max_block)
                    if chunk_total >= 4
                        # 1 literal + (chunk_total-1) match
                        push!(current_block, Sequence(UInt32(1), UInt32(chunk_total - 1), UInt32(off)))
                    else
                        # Too small for a match; emit as pure literals
                        push!(current_block, Sequence(UInt32(chunk_total), 0, 0))
                    end
                    block_used = chunk_total
                    leftover -= chunk_total
                    if leftover > 0
                        push!(blocks, current_block)
                        current_block = Sequence[]
                        block_used = 0
                    end
                end
            else
                # Not enough space for a valid match split; end block, put whole seq in next
                if !isempty(current_block)
                    # Pad remaining bytes as trailing literals
                    remaining = max_block - block_used
                    if remaining > 0
                        # Steal from this sequence's literals
                        steal = min(remaining, ll)
                        if steal > 0
                            push!(current_block, Sequence(UInt32(steal), 0, 0))
                            ll -= steal
                        end
                    end
                    push!(blocks, current_block)
                    current_block = Sequence[]
                    block_used = 0
                end
                # Put (possibly shortened) sequence in next block
                push!(current_block, Sequence(UInt32(ll), UInt32(ml), UInt32(off)))
                block_used = ll + ml
            end
        else
            # Even literals don't fit — split literals across blocks
            remaining_ll = ll
            while remaining_ll > 0
                space = max_block - block_used
                if remaining_ll <= space
                    # All remaining literals + match will be handled next iteration
                    break
                end
                take = min(remaining_ll, space)
                push!(current_block, Sequence(UInt32(take), 0, 0))
                remaining_ll -= take
                push!(blocks, current_block)
                current_block = Sequence[]
                block_used = 0
            end
            # Now remaining_ll + ml fits or we start fresh
            push!(current_block, Sequence(UInt32(remaining_ll), UInt32(ml), UInt32(off)))
            block_used += remaining_ll + ml
        end

        # Flush if block is exactly full
        if block_used == max_block
            push!(blocks, current_block)
            current_block = Sequence[]
            block_used = 0
        end
    end

    # Flush last block
    if !isempty(current_block)
        push!(blocks, current_block)
    end

    return blocks
end

function gather_literals(data::AbstractVector{UInt8}, sequences::Vector{Sequence})
    total_ll = sum(Int(s.literal_length) for s in sequences)
    literals = Vector{UInt8}(undef, total_ll)
    pos = 1; out = 1
    for seq in sequences
        ll = Int(seq.literal_length)
        if ll > 0
            copyto!(literals, out, data, pos, ll)
            out += ll
        end
        pos += ll + Int(seq.match_length)
    end
    return literals
end

function write_literals_section(io::IO, literals::AbstractVector{UInt8})
    if isempty(literals)
        write_raw_literals_section(io, literals)
        return
    end
    if all(==(literals[1]), literals)
        write_rle_literals_section(io, literals)
        return
    end
    enc = build_huffman_encoder(literals)
    if enc !== nothing
        huff_io = IOBuffer()
        ok = encode_huffman_literals(huff_io, literals, enc)
        if ok
            huff_bytes = take!(huff_io)
            if length(huff_bytes) < length(literals)
                write(io, huff_bytes)
                return
            end
        end
    end
    write_raw_literals_section(io, literals)
end

function write_rle_literals_section(io::IO, literals::AbstractVector{UInt8})
    ll = length(literals)
    if ll < 32
        write(io, UInt8(0x01 | (0x00 << 2) | (ll << 3)))
    elseif ll < 4096
        write(io, UInt8(0x01 | (0x01 << 2) | ((ll & 0x0F) << 4)))
        write(io, UInt8(ll >> 4))
    else
        write(io, UInt8(0x01 | (0x03 << 2) | ((ll & 0x0F) << 4)))
        write(io, UInt8((ll >> 4) & 0xFF))
        write(io, UInt8(ll >> 12))
    end
    write(io, literals[1])
end

function write_raw_literals_section(io::IO, literals::AbstractVector{UInt8})
    ll = length(literals)
    if ll < 32; write(io, UInt8((0 << 0) | (0 << 2) | (ll << 3)))
    elseif ll < 4096; write(io, UInt8((0 << 0) | (1 << 2) | ((ll & 0x0F) << 4))); write(io, UInt8(ll >> 4))
    else; write(io, UInt8((0 << 0) | (3 << 2) | ((ll & 0x0F) << 4))); write(io, UInt8((ll >> 4) & 0xFF)); write(io, UInt8(ll >> 12)) end
    write(io, literals)
end

end # module
