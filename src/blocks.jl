module Blocks

import ..Zstandard: FrameContext
import ..Huffman: decode_huffman_tree, decode_huffman_stream, decode_huffman_streams
import ..Sequences: decode_sequences

export decompress_compressed_block, decode_literals

function decompress_compressed_block(data::Vector{UInt8}, ctx::FrameContext, history::Vector{UInt8})
    io = IOBuffer(data)
    
    # 1. Literals Section
    literals = decode_literals(io, ctx)
    
    # 2. Sequences Section
    # Position is now exactly after the literals content
    sequences_data = read(io)
    
    if isempty(sequences_data)
        return literals
    end
    
    return decode_sequences(sequences_data, literals, ctx, history)
end

function decode_literals(io::IO, ctx::FrameContext)
    b1 = read(io, UInt8)
    literals_block_type = b1 & 0x03
    size_format = (b1 >> 2) & 0x03
    
    regenerated_size = 0
    compressed_size = 0
    
    if literals_block_type == 0 || literals_block_type == 1 # Raw or RLE
        if size_format == 0 || size_format == 2
            regenerated_size = b1 >> 3
        elseif size_format == 1
            b2 = read(io, UInt8)
            regenerated_size = (UInt32(b1) >> 4) | (UInt32(b2) << 4)
        elseif size_format == 3
            b2 = read(io, UInt8)
            b3 = read(io, UInt8)
            regenerated_size = (UInt32(b1) >> 4) | (UInt32(b2) << 4) | (UInt32(b3) << 12)
        end
        
        if literals_block_type == 0 # Raw
            return read(io, Int(regenerated_size))
        elseif literals_block_type == 1 # RLE
            rle_byte = read(io, UInt8)
            return fill(rle_byte, Int(regenerated_size))
        end
    elseif literals_block_type == 2 || literals_block_type == 3 # Compressed or Treeless
        if size_format == 0
            b2 = read(io, UInt8)
            b3 = read(io, UInt8)
            regenerated_size = (UInt32(b1) >> 4) | ((UInt32(b2) & 0x3f) << 4)
            compressed_size = (UInt32(b2) >> 6) | (UInt32(b3) << 2)
        elseif size_format == 1
            b2 = read(io, UInt8)
            b3 = read(io, UInt8)
            regenerated_size = (UInt32(b1) >> 4) | ((UInt32(b2) & 0x3f) << 4)
            compressed_size = (UInt32(b2) >> 6) | (UInt32(b3) << 2)
        elseif size_format == 2
            b2 = read(io, UInt8)
            b3 = read(io, UInt8)
            b4 = read(io, UInt8)
            regenerated_size = (UInt32(b1) >> 4) | (UInt32(b2) << 4) | ((UInt32(b3) & 0x03) << 12)
            compressed_size = (UInt32(b3) >> 2) | (UInt32(b4) << 6)
        elseif size_format == 3
            b2 = read(io, UInt8)
            b3 = read(io, UInt8)
            b4 = read(io, UInt8)
            b5 = read(io, UInt8)
            regenerated_size = (UInt32(b1) >> 4) | (UInt32(b2) << 4) | ((UInt32(b3) & 0x3f) << 12)
            compressed_size = (UInt32(b3) >> 6) | (UInt32(b4) << 2) | (UInt32(b5) << 10)
        end
        
        num_streams = (size_format == 0) ? 1 : 4
        
        huffman_tree_start = position(io)
        if literals_block_type == 2 # Compressed
            ctx.huffman_table = decode_huffman_tree(io)
        end
        
        if ctx.huffman_table === nothing
            error("Treeless literals block but no previous Huffman table")
        end
        
        huffman_tree_size = position(io) - huffman_tree_start
        actual_stream_size = compressed_size - huffman_tree_size
        
        stream_data = read(io, Int(actual_stream_size))
        if num_streams == 1
            return decode_huffman_stream(stream_data, ctx.huffman_table, Int(regenerated_size))
        else
            return decode_huffman_streams(stream_data, ctx.huffman_table, Int(regenerated_size))
        end
    end
end

end # module
