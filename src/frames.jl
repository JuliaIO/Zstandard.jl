module Frames

export FrameHeader, read_frame_header, BlockHeader, read_block_header

struct FrameHeader
    frame_content_size_flag::Int
    single_segment_flag::Int
    content_checksum_flag::Int
    dictionary_id_flag::Int
    window_size::Int
    dict_id::UInt32
    frame_content_size::UInt64
end

function read_frame_header(io::IO)
    fd = read(io, UInt8)
    frame_content_size_flag = (fd >> 6) & 0x03
    single_segment_flag = (fd >> 5) & 0x01
    unused_bit = (fd >> 4) & 0x01
    reserved_bit = (fd >> 3) & 0x01
    content_checksum_flag = (fd >> 2) & 0x01
    dictionary_id_flag = fd & 0x03
    
    if reserved_bit != 0
        error("Reserved bit must be 0")
    end
    
    window_size = 0
    if single_segment_flag == 0
        wd = read(io, UInt8)
        exponent = wd >> 3
        mantissa = wd & 0x07
        window_size = (1 << exponent) + ((mantissa * (1 << exponent)) ÷ 8)
    end
    
    dict_id = 0
    if dictionary_id_flag == 1
        dict_id = read(io, UInt8)
    elseif dictionary_id_flag == 2
        dict_id = read(io, UInt16)
    elseif dictionary_id_flag == 3
        dict_id = read(io, UInt32)
    end
    
    frame_content_size = 0
    if frame_content_size_flag == 0
        if single_segment_flag == 1
            frame_content_size = read(io, UInt8)
        end
    elseif frame_content_size_flag == 1
        frame_content_size = UInt64(read(io, UInt16)) + 256
    elseif frame_content_size_flag == 2
        frame_content_size = read(io, UInt32)
    elseif frame_content_size_flag == 3
        frame_content_size = read(io, UInt64)
    end
    
    return FrameHeader(
        frame_content_size_flag,
        single_segment_flag,
        content_checksum_flag,
        dictionary_id_flag,
        Int(window_size),
        UInt32(dict_id),
        UInt64(frame_content_size)
    )
end

struct BlockHeader
    last_block::Bool
    block_type::Int
    block_size::Int
end

function read_block_header(io::IO)
    b1 = read(io, UInt8)
    b2 = read(io, UInt8)
    b3 = read(io, UInt8)
    
    header = UInt32(b1) | (UInt32(b2) << 8) | (UInt32(b3) << 16)
    last_block = (header & 0x01) != 0
    block_type = Int((header >> 1) & 0x03)
    block_size = Int(header >> 3)
    
    return BlockHeader(last_block, block_type, block_size)
end

end # module
