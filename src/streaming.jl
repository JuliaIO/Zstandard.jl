# Streaming decompressor for Zstandard

module Streaming

import ..Zstandard: FrameContext, MAGIC_NUMBER, SKIPPABLE_MAGIC_START, SKIPPABLE_MAGIC_END, ZstdDictionary
import ..Blocks: decompress_compressed_block, decode_literals
import ..Bitstream: BackwardBitReader, read_bits, peek_bits, consume_bits, bits_left
import ..Frames: FrameHeader, read_frame_header, BlockHeader, read_block_header
using XXHashNative

export ZstdDecompressor, ZstdDecompressorStream

@enum DecompressorStage begin
    Stage_GetMagic
    Stage_DecodeFrameHeader
    Stage_DecodeBlockHeader
    Stage_DecompressBlock
    Stage_CheckChecksum
    Stage_DecodeSkippableHeader
    Stage_SkipFrame
end

mutable struct ZstdDecompressor
    stage::DecompressorStage
    ctx::Union{Nothing, FrameContext}
    fh::Union{Nothing, FrameHeader}
    
    out_buffer::Vector{UInt8}
    out_pos::Int
    
    history::Vector{UInt8} # All previously decoded data in current frame
    
    # For current block
    bh::Union{Nothing, BlockHeader}
    
    # For skippable frames
    skip_size::UInt32
    
    # Checksum state
    xxh_state::Union{Nothing, XXH64State}
    
    # Dictionary
    dict::Union{Nothing, ZstdDictionary}
end

function ZstdDecompressor(dict::Union{Nothing, ZstdDictionary}=nothing)
    return ZstdDecompressor(
        Stage_GetMagic,
        nothing,
        nothing,
        UInt8[],
        1,
        UInt8[],
        nothing,
        0,
        nothing,
        dict
    )
end

"""
    ZstdDecompressorStream(io::IO, dict::Union{Nothing, ZstdDictionary}=nothing)

A streaming Zstandard decompressor that implements the `IO` interface.
"""
mutable struct ZstdDecompressorStream <: IO
    io::IO
    d::ZstdDecompressor
end

function ZstdDecompressorStream(io::IO, dict::Union{Nothing, ZstdDictionary}=nothing)
    return ZstdDecompressorStream(io, ZstdDecompressor(dict))
end

Base.eof(s::ZstdDecompressorStream) = (s.d.out_pos > length(s.d.out_buffer)) && eof(s.io)

function Base.read(s::ZstdDecompressorStream, ::Type{UInt8})
    while s.d.out_pos > length(s.d.out_buffer)
        if eof(s.io)
            throw(EOFError())
        end
        fill_out_buffer!(s)
    end
    val = s.d.out_buffer[s.d.out_pos]
    s.d.out_pos += 1
    return val
end

function Base.read(s::ZstdDecompressorStream)
    chunks = Vector{UInt8}[]
    total = 0
    while !eof(s)
        fill_out_buffer!(s)
        d = s.d
        avail = length(d.out_buffer) - d.out_pos + 1
        if avail > 0
            push!(chunks, d.out_buffer[d.out_pos:d.out_pos+avail-1])  # copy needed; buffer is reused
            d.out_pos += avail
            total += avail
        end
    end
    out = Vector{UInt8}(undef, total)
    pos = 1
    for chunk in chunks
        copyto!(out, pos, chunk, 1, length(chunk))
        pos += length(chunk)
    end
    return out
end

function Base.read(s::ZstdDecompressorStream, nb::Integer)
    b = Vector{UInt8}(undef, nb)
    n = readbytes!(s, b, nb)
    resize!(b, n)
    return b
end

function Base.readbytes!(s::ZstdDecompressorStream, b::AbstractVector{UInt8}, nb=length(b))
    out_idx = 1
    while out_idx <= nb
        if s.d.out_pos > length(s.d.out_buffer)
            if eof(s.io)
                return out_idx - 1
            end
            fill_out_buffer!(s)
            if s.d.out_pos > length(s.d.out_buffer)
                return out_idx - 1
            end
        end
        
        take = min(nb - out_idx + 1, length(s.d.out_buffer) - s.d.out_pos + 1)
        copyto!(b, out_idx, s.d.out_buffer, s.d.out_pos, take)
        s.d.out_pos += take
        out_idx += take
    end
    return out_idx - 1
end

function fill_out_buffer!(s::ZstdDecompressorStream)
    d = s.d
    if d.stage == Stage_GetMagic
        if eof(s.io); return; end
        magic = read(s.io, UInt32)
        if magic == MAGIC_NUMBER
            d.stage = Stage_DecodeFrameHeader
        elseif magic >= SKIPPABLE_MAGIC_START && magic <= SKIPPABLE_MAGIC_END
            d.stage = Stage_DecodeSkippableHeader
        else
            error("Invalid magic number: $(repr(magic))")
        end
    end
    
    if d.stage == Stage_DecodeFrameHeader
        d.fh = read_frame_header(s.io)
        
        # Dictionary verification
        if d.fh.dict_id != 0
            if d.dict === nothing
                error("Frame requires dictionary ID $(d.fh.dict_id) but none provided")
            end
            if d.dict.id != 0 && d.dict.id != d.fh.dict_id
                error("Dictionary ID mismatch: frame requires $(d.fh.dict_id), provided $(d.dict.id)")
            end
        end
        
        d.ctx = FrameContext(d.fh.window_size, d.dict)
        d.history = (d.dict !== nothing) ? copy(d.dict.content) : UInt8[]
        
        if d.fh.content_checksum_flag == 1
            d.xxh_state = XXH64State()
        else
            d.xxh_state = nothing
        end
        d.stage = Stage_DecodeBlockHeader
    end
    
    if d.stage == Stage_DecodeBlockHeader
        d.bh = read_block_header(s.io)
        d.stage = Stage_DecompressBlock
    end
    
    if d.stage == Stage_DecompressBlock
        bh = d.bh
        block_data = UInt8[]
        if bh.block_type == 0 # Raw
            block_data = read(s.io, bh.block_size)
        elseif bh.block_type == 1 # RLE
            rle_byte = read(s.io, UInt8)
            block_data = fill(rle_byte, bh.block_size)
        elseif bh.block_type == 2 # Compressed
            compressed_data = read(s.io, bh.block_size)
            block_data = decompress_compressed_block(compressed_data, d.ctx, d.history)
        elseif bh.block_type == 3 # Reserved
            error("Reserved block type")
        end
        
        if d.xxh_state !== nothing
            update!(d.xxh_state, block_data)
        end
        
        append!(d.history, block_data)
        d.out_buffer = block_data
        d.out_pos = 1
        
        # Manage history size: keep only window_size history
        if length(d.history) > d.fh.window_size * 2
            d.history = d.history[end-d.fh.window_size+1:end]
        end
        
        if bh.last_block
            if d.fh.content_checksum_flag == 1
                d.stage = Stage_CheckChecksum
            else
                d.stage = Stage_GetMagic
            end
        else
            d.stage = Stage_DecodeBlockHeader
        end
    end
    
    if d.stage == Stage_CheckChecksum
        expected_checksum = read(s.io, UInt32)
        actual_checksum = UInt32(digest!(d.xxh_state) & 0xFFFFFFFF)
        if expected_checksum != actual_checksum
            error("Checksum mismatch: expected $(repr(expected_checksum)), got $(repr(actual_checksum))")
        end
        d.stage = Stage_GetMagic
    end
    
    if d.stage == Stage_DecodeSkippableHeader
        d.skip_size = read(s.io, UInt32)
        d.stage = Stage_SkipFrame
    end
    
    if d.stage == Stage_SkipFrame
        skip(s.io, d.skip_size)
        d.stage = Stage_GetMagic
    end
end

end # module
