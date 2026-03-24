module Dictionary

using ..Huffman: HuffmanTable, decode_huffman_tree
using ..FSE: FSETable, read_fse_table, build_fse_table
using ..Bitstream: ForwardBitReader

export ZstdDictionary, parse_dictionary

struct ZstdDictionary
    id::UInt32
    huffman_table::Union{Nothing, HuffmanTable}
    of_table::Union{Nothing, FSETable}
    ml_table::Union{Nothing, FSETable}
    ll_table::Union{Nothing, FSETable}
    rep_offsets::Vector{Int}
    content::Vector{UInt8}
end

const DICT_MAGIC = 0xEC30A437

"""
    parse_dictionary(data::Vector{UInt8})

Parse a Zstandard dictionary from a byte vector. Supports both raw content and formatted dictionaries.
"""
function parse_dictionary(data::Vector{UInt8})
    io = IOBuffer(data)
    if length(data) >= 4
        magic = read(io, UInt32)
        if magic == DICT_MAGIC
            # Formatted dictionary
            id = read(io, UInt32)
            
            # Huffman table for literals
            huffman_table = decode_huffman_tree(io)
            
            # FSE tables: Offsets, Match Lengths, Literals Lengths
            fbr = ForwardBitReader(io)
            
            # 1. Offsets FSE table (max 31 symbols)
            probs_of, acc_of = read_fse_table(fbr, 32)
            of_table = build_fse_table(probs_of, acc_of)
            
            # 2. Match Lengths FSE table (max 53 symbols)
            probs_ml, acc_ml = read_fse_table(fbr, 53)
            ml_table = build_fse_table(probs_ml, acc_ml)
            
            # 3. Literals Lengths FSE table (max 36 symbols)
            probs_ll, acc_ll = read_fse_table(fbr, 36)
            ll_table = build_fse_table(probs_ll, acc_ll)
            
            # Repeat offsets: 3 x 4 bytes
            rep_offsets = Int[read(io, UInt32), read(io, UInt32), read(io, UInt32)]
            
            # Content
            content = read(io)
            
            return ZstdDictionary(id, huffman_table, of_table, ml_table, ll_table, rep_offsets, content)
        end
    end
    
    # Raw dictionary
    return ZstdDictionary(0, nothing, nothing, nothing, nothing, [1, 4, 8], data)
end

end # module
