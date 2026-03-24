module Compress

import ..Zstandard: MAGIC_NUMBER
import ..Frames: FrameHeader
import ..MatchFinder: find_sequences, Sequence
import ..EncodeSequences: encode_sequences
using XXHashNative

export compress

function write_frame_header(io::IO, data_len::Int)
    # Magic Number
    write(io, MAGIC_NUMBER)

    # Frame Header Descriptor (FD)
    # 0b00000000:
    # Frame_Content_Size_flag (bit 6-7): 0 (when size == 0) or 1/2/3 depending on size.
    # Single_Segment_flag (bit 5): 1 (we'll use single segment for raw blocks to simplify)
    # Unused_bit (bit 4): 0
    # Reserved_bit (bit 3): 0
    # Content_Checksum_flag (bit 2): 1 (enable checksum)
    # Dictionary_ID_flag (bit 0-1): 0 (no dictionary)
    
    # Let's support up to 2^32 size for now with Single_Segment_flag = 1
    # Actually, Single_Segment_flag = 1 means Window_Descriptor is absent,
    # and Frame_Content_Size is the Window_Size.
    
    fcs_flag = 0
    if data_len <= 255
        fcs_flag = 0
    elseif data_len <= 65535 + 256
        fcs_flag = 1
    elseif data_len <= 0xFFFFFFFF
        fcs_flag = 2
    else
        fcs_flag = 3
    end

    fd = UInt8((fcs_flag << 6) | (1 << 5) | (1 << 2))
    write(io, fd)

    # Frame Content Size
    if fcs_flag == 0
        write(io, UInt8(data_len))
    elseif fcs_flag == 1
        write(io, UInt16(data_len - 256))
    elseif fcs_flag == 2
        write(io, UInt32(data_len))
    elseif fcs_flag == 3
        write(io, UInt64(data_len))
    end
end

function compress(data::AbstractVector{UInt8}; level::Int=3)
    io = IOBuffer()
    write_frame_header(io, length(data))

    # Level 0 is alias for default (3)
    eff_level = (level == 0) ? 3 : level

    if eff_level < -100 # Arbitrary limit
        return write_raw_blocks(io, data)
    end

    # Match finder configuration based on level
    hash_log = 14
    search_depth = 64
    step = 1
    
    if eff_level == 1
        search_depth = 4
    elseif eff_level == 2
        search_depth = 16
    elseif eff_level >= 3
        search_depth = 64
    elseif eff_level < 0
        search_depth = 1
        step = 1 - eff_level # e.g. level -1 -> step 2
    end

    # Phase 2: Find matches
    sequences = find_sequences(data, hash_log=hash_log, search_depth=search_depth, step=step)
    
    if length(sequences) == 1 && sequences[1].match_length == 0
        # No matches found, write as raw block
        return write_raw_blocks(io, data)
    end

    # TODO: Full Compressed_Block implementation
    # Fallback to Raw for now until FSE encoder is ready
    return write_raw_blocks(io, data)
end

function write_raw_blocks(io::IO, data::AbstractVector{UInt8})
    block_type = 0
    MAX_BLOCK_SIZE = 128 * 1024
    
    pos = 1
    while pos <= length(data)
        chunk_size = min(MAX_BLOCK_SIZE, length(data) - pos + 1)
        is_last = (pos + chunk_size > length(data)) ? 1 : 0
        
        block_header = UInt32(is_last | (block_type << 1) | (chunk_size << 3))
        write(io, UInt8(block_header & 0xFF))
        write(io, UInt8((block_header >> 8) & 0xFF))
        write(io, UInt8((block_header >> 16) & 0xFF))
        
        write(io, view(data, pos:pos+chunk_size-1))
        pos += chunk_size
    end
    
    if isempty(data)
        block_header = UInt32(1 | (0 << 1) | (0 << 3))
        write(io, UInt8(block_header & 0xFF))
        write(io, UInt8((block_header >> 8) & 0xFF))
        write(io, UInt8((block_header >> 16) & 0xFF))
    end

    # Checksum
    state = XXH64State()
    update!(state, data)
    hash_val = digest!(state)
    write(io, UInt32(hash_val & 0xFFFFFFFF))
    
    return take!(io)
end

compress(data::AbstractString; level::Int=3) = compress(codeunits(data), level=level)

end # module
