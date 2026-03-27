module Zstandard

export decompress, compress, ZstdDecompressorStream, ZstdDictionary, parse_dictionary

const MAGIC_NUMBER = 0xFD2FB528
const SKIPPABLE_MAGIC_START = 0x184D2A50
const SKIPPABLE_MAGIC_END   = 0x184D2A5F

include("bitstream.jl")
using .Bitstream: ForwardBitReader, BackwardBitReader, read_bits, peek_bits, consume_bits, align_to_byte, bits_left

include("fse.jl")
using .FSE: build_fse_table, read_fse_table, FSETable, get_default_ll_table, get_default_ml_table, get_default_of_table

include("huffman.jl")
using .Huffman: decode_huffman_tree, decode_huffman_stream, decode_huffman_streams, HuffmanTable

include("dictionary.jl")
using .Dictionary: ZstdDictionary, parse_dictionary

mutable struct FrameContext
    window_size::Int
    rep_offsets::Vector{Int}
    huffman_table::Union{Nothing, HuffmanTable}
    ll_table::Union{Nothing, FSETable}
    ml_table::Union{Nothing, FSETable}
    of_table::Union{Nothing, FSETable}
    dict::Union{Nothing, ZstdDictionary}
end

function FrameContext(window_size::Int, dict::Union{Nothing, ZstdDictionary}=nothing)
    rep_offsets = (dict !== nothing) ? copy(dict.rep_offsets) : [1, 4, 8]
    huffman_table = (dict !== nothing) ? dict.huffman_table : nothing
    ll_table = (dict !== nothing) ? dict.ll_table : nothing
    ml_table = (dict !== nothing) ? dict.ml_table : nothing
    of_table = (dict !== nothing) ? dict.of_table : nothing
    return FrameContext(window_size, rep_offsets, huffman_table, ll_table, ml_table, of_table, dict)
end

include("sequences.jl")
using .Sequences: decode_sequences

include("blocks.jl")
using .Blocks: decompress_compressed_block, decode_literals

include("frames.jl")
using .Frames: FrameHeader, read_frame_header, BlockHeader, read_block_header

include("streaming.jl")
using .Streaming: ZstdDecompressor, ZstdDecompressorStream

include("matchfinder.jl")
using .MatchFinder: find_sequences

include("write_bitstream.jl")
include("encode_fse.jl")
include("encode_huffman.jl")
include("encode_sequences.jl")

include("compress.jl")
using .Compress: compress

"""
    decompress(data::Vector{UInt8}, dict::Union{Nothing, ZstdDictionary}=nothing)

Decompress Zstandard compressed data. Optionally, a `ZstdDictionary` can be provided.
"""
function decompress(data::Vector{UInt8}, dict::Union{Nothing, ZstdDictionary}=nothing)
    io = IOBuffer(data)
    stream = ZstdDecompressorStream(io, dict)
    return read(stream)
end

end # module
