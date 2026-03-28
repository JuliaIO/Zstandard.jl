module Compress

import ..Zstandard: MAGIC_NUMBER
import ..Frames: FrameHeader
import ..MatchFinder: find_sequences, Sequence
import ..EncodeSequences: encode_sequences
import ..EncodeHuffman: build_huffman_encoder, encode_huffman_literals
using XXHashNative

export compress

function write_frame_header(io::IO, data_len::Int)
    write(io, UInt32(MAGIC_NUMBER))
    fcs_flag = (data_len == 0) ? 0 : (data_len <= 255) ? 0 : (data_len <= 65535 + 256) ? 1 : (data_len <= 0xFFFFFFFF) ? 2 : 3
    fd = UInt8((fcs_flag << 6) | (1 << 5) | (1 << 2))
    write(io, fd)
    if fcs_flag == 0; write(io, UInt8(data_len))
    elseif fcs_flag == 1; write(io, UInt16(data_len - 256))
    elseif fcs_flag == 2; write(io, UInt32(data_len))
    elseif fcs_flag == 3; write(io, UInt64(data_len)) end
end

const MAX_BLOCK_SIZE = 128 * 1024

function compress(data::AbstractVector{UInt8}; level::Int=3)
    io = IOBuffer()
    write_frame_header(io, length(data))
    eff_level = (level == 0) ? 3 : level
    hash_log = 14
    search_depth = (eff_level == 1) ? 4 : (eff_level == 2) ? 16 : 64
    step = (eff_level < 0) ? (1 - eff_level) : 1

    if isempty(data)
        write_block_header(io, true, 0, 0)
    else
        pos = 1
        rep_offsets = [1, 4, 8]  # Persist across blocks within a frame
        while pos <= length(data)
            chunk_end = min(pos + MAX_BLOCK_SIZE - 1, length(data))
            is_last = (chunk_end == length(data))
            chunk = view(data, pos:chunk_end)

            sequences = find_sequences(chunk, hash_log=hash_log, search_depth=search_depth, step=step)
            has_seqs = !isempty(sequences) && !(length(sequences) == 1 && sequences[1].match_length == 0)

            if has_seqs
                saved_rep = copy(rep_offsets)
                block_io = IOBuffer()
                write_compressed_block_body(block_io, chunk, sequences, rep_offsets=rep_offsets)
                block_bytes = take!(block_io)
                if length(block_bytes) < length(chunk)
                    write_block_header(io, is_last, 2, length(block_bytes))
                    write(io, block_bytes)
                else
                    # Compressed was larger; fall back to raw and restore rep_offsets
                    rep_offsets .= saved_rep
                    write_block_header(io, is_last, 0, length(chunk))
                    write(io, chunk)
                end
            else
                write_block_header(io, is_last, 0, length(chunk))
                write(io, chunk)
            end
            pos = chunk_end + 1
        end
    end

    state = XXH64State()
    update!(state, data)
    write(io, UInt32(digest!(state) & 0xFFFFFFFF))
    return take!(io)
end

compress(data::AbstractString; level::Int=3) = compress(codeunits(data), level=level)

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
