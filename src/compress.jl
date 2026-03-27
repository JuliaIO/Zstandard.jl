module Compress

import ..Zstandard: MAGIC_NUMBER
import ..Frames: FrameHeader
import ..MatchFinder: find_sequences, Sequence
import ..EncodeSequences: encode_sequences
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

function compress(data::AbstractVector{UInt8}; level::Int=3)
    io = IOBuffer()
    write_frame_header(io, length(data))
    eff_level = (level == 0) ? 3 : level
    hash_log = 14
    search_depth = (eff_level == 1) ? 4 : (eff_level == 2) ? 16 : 64
    step = (eff_level < 0) ? (1 - eff_level) : 1
    sequences = find_sequences(data, hash_log=hash_log, search_depth=search_depth, step=step)
    if isempty(sequences) || (length(sequences) == 1 && sequences[1].match_length == 0)
        write_raw_blocks_content(io, data)
    elseif length(data) > 128 * 1024
        write_raw_blocks_content(io, data)
    else
        write_compressed_block_content(io, data, sequences)
    end
    state = XXH64State()
    update!(state, data)
    write(io, UInt32(digest!(state) & 0xFFFFFFFF))
    return take!(io)
end

compress(data::AbstractString; level::Int=3) = compress(codeunits(data), level=level)

function write_raw_blocks_content(io::IO, data::AbstractVector{UInt8})
    MAX_BLOCK_SIZE = 128 * 1024
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

function write_compressed_block_content(io::IO, data::AbstractVector{UInt8}, sequences::Vector{Sequence})
    literals = gather_literals(data, sequences)
    block_io = IOBuffer()
    write_raw_literals_section(block_io, literals)
    encode_sequences(block_io, sequences, length(data))
    block_data = take!(block_io)
    write_block_header(io, true, 2, length(block_data))
    write(io, block_data)
end

function write_block_header(io::IO, last::Bool, type::Int, size::Int)
    header = UInt32(Int(last) | (type << 1) | (size << 3))
    write(io, UInt8(header & 0xFF)); write(io, UInt8((header >> 8) & 0xFF)); write(io, UInt8((header >> 16) & 0xFF))
end

function gather_literals(data::AbstractVector{UInt8}, sequences::Vector{Sequence})
    literals = UInt8[]; pos = 1
    for seq in sequences
        ll = Int(seq.literal_length)
        if ll > 0; append!(literals, data[pos:pos+ll-1]) end
        pos += ll + Int(seq.match_length)
    end
    return literals
end

function write_raw_literals_section(io::IO, literals::AbstractVector{UInt8})
    ll = length(literals)
    if ll < 32; write(io, UInt8((0 << 0) | (0 << 2) | (ll << 3)))
    elseif ll < 4096; write(io, UInt8((0 << 0) | (1 << 2) | ((ll & 0x0F) << 4))); write(io, UInt8(ll >> 4))
    else; write(io, UInt8((0 << 0) | (3 << 2) | ((ll & 0x0F) << 4))); write(io, UInt8((ll >> 4) & 0xFF)); write(io, UInt8(ll >> 12)) end
    write(io, literals)
end

end # module
