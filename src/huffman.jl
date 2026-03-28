module Huffman

import ..FSE: build_fse_table, read_fse_table, FSETable
import ..Bitstream: ForwardBitReader, BackwardBitReader, read_bits, peek_bits, consume_bits, bits_left

export decode_huffman_tree, decode_huffman_stream, decode_huffman_streams, HuffmanTable

struct HuffmanTable
    max_bits::Int
    table::Vector{Tuple{Int, Int}} # (bits, symbol)
end

function decode_huffman_stream(data::AbstractVector{UInt8}, table::HuffmanTable, decompressed_size::Int)
    Base.require_one_based_indexing(data)
    bbr = BackwardBitReader(data)
    output = Vector{UInt8}(undef, decompressed_size)
    @inbounds for i in 1:decompressed_size
        val = peek_bits(bbr, table.max_bits)
        bits, sym = table.table[val + 1]
        output[i] = UInt8(sym)
        consume_bits(bbr, bits)
    end
    return output
end

function decode_huffman_streams(data::Vector{UInt8}, table::HuffmanTable, regenerated_size::Int)
    if length(data) < 6
        error("Bitstream too short for 4-stream Huffman decoding")
    end
    
    s1_size = UInt16(data[1]) | (UInt16(data[2]) << 8)
    s2_size = UInt16(data[3]) | (UInt16(data[4]) << 8)
    s3_size = UInt16(data[5]) | (UInt16(data[6]) << 8)
    s4_size = length(data) - 6 - s1_size - s2_size - s3_size
    
    if s4_size < 0
        error("Invalid jump table sizes")
    end
    
    off1 = 7
    off2 = off1 + s1_size
    off3 = off2 + s2_size
    off4 = off3 + s3_size
    s1_data = @view data[off1:off1+s1_size-1]
    s2_data = @view data[off2:off2+s2_size-1]
    s3_data = @view data[off3:off3+s3_size-1]
    s4_data = @view data[off4:end]

    chunk_size = (regenerated_size + 3) ÷ 4
    s4_out_size = regenerated_size - 3 * chunk_size

    out1 = decode_huffman_stream(s1_data, table, chunk_size)
    out2 = decode_huffman_stream(s2_data, table, chunk_size)
    out3 = decode_huffman_stream(s3_data, table, chunk_size)
    out4 = decode_huffman_stream(s4_data, table, s4_out_size)

    output = Vector{UInt8}(undef, regenerated_size)
    copyto!(output, 1, out1, 1, chunk_size)
    copyto!(output, chunk_size + 1, out2, 1, chunk_size)
    copyto!(output, 2 * chunk_size + 1, out3, 1, chunk_size)
    copyto!(output, 3 * chunk_size + 1, out4, 1, s4_out_size)
    return output
end

function decode_huffman_tree(io::IO)
    header = read(io, UInt8)
    weights = Int[]
    
    if header >= 128
        num_symbols = header - 127
        for i in 1:ceil(Int, num_symbols / 2)
            b = read(io, UInt8)
            push!(weights, b >> 4)
            if length(weights) < num_symbols
                push!(weights, b & 0x0f)
            end
        end
    else
        fse_compressed_size = header
        fse_data = read(io, fse_compressed_size)
        weights = decode_fse_weights(fse_data)
    end
    
    weight_sum = 0
    for w in weights
        if w > 0
            weight_sum += (1 << (w - 1))
        end
    end
    
    if weight_sum == 0
        error("Empty Huffman tree weights")
    end
    
    max_bits = ceil(Int, log2(weight_sum + 1))
    next_p2 = 1 << max_bits
    last_weight_val = next_p2 - weight_sum
    if last_weight_val > 0
        # The last weight is nonzero
        push!(weights, Int(log2(last_weight_val)) + 1)
    end
    
    return build_huffman_table(weights, max_bits)
end

function decode_fse_weights(data::Vector{UInt8})
    fbr = ForwardBitReader(IOBuffer(data))
    probs, accuracy_log = read_fse_table(fbr, 12)
    fse_table = build_fse_table(probs, accuracy_log)
    
    remaining_data = read(fbr.io)
    bbr = BackwardBitReader(remaining_data)
    
    state1 = Int(read_bits(bbr, fse_table.accuracy_log))
    state2 = Int(read_bits(bbr, fse_table.accuracy_log))
    
    weights_even = Int[]
    weights_odd = Int[]
    
    while true
        sym1, nb1, base1 = fse_table.table[state1 + 1]
        sym2, nb2, base2 = fse_table.table[state2 + 1]
        
        if bits_left(bbr) < nb1
            push!(weights_even, sym1)
            push!(weights_odd, sym2)
            break
        end
        push!(weights_even, sym1)
        state1 = Int(read_bits(bbr, nb1)) + base1
        
        if bits_left(bbr) < nb2
            push!(weights_odd, sym2)
            push!(weights_even, fse_table.table[state1 + 1][1])
            break
        end
        push!(weights_odd, sym2)
        state2 = Int(read_bits(bbr, nb2)) + base2
    end
    
    weights = Int[]
    for i in 1:length(weights_even)
        push!(weights, weights_even[i])
        if i <= length(weights_odd)
            push!(weights, weights_odd[i])
        end
    end
    
    return weights
end

function build_huffman_table(weights, max_bits)
    num_symbols = length(weights)
    bits_per_symbol = zeros(Int, num_symbols)
    for i in 1:num_symbols
        if weights[i] > 0
            bits_per_symbol[i] = max_bits + 1 - weights[i]
        end
    end
    
    table_size = 1 << max_bits
    table = fill((0, -1), table_size)
    
    current_code = 0
    # Codes are assigned from longest (highest bits) to shortest (lowest bits)
    # RFC: "starting from the lowest Weight (longest codes) to the highest weight (shortest codes)"
    # Wait, my weight-to-bits formula was L = max_bits + 1 - W.
    # Lowest Weight (W=1) -> Longest Code (L=max_bits).
    # Highest Weight (W=max_bits) -> Shortest Code (L=1).
    
    for b in max_bits:-1:1
        for s in 1:num_symbols
            if bits_per_symbol[s] == b
                shift = max_bits - b
                for i in 0:(1 << shift)-1
                    idx = (current_code << shift) + i
                    table[idx + 1] = (b, s - 1)
                end
                current_code += 1
            end
        end
        # Move to next length (shorter).
        # Actually, for shorter codes, we need to halve the current_code value? 
        # Canonical Huffman: codes of length L+1 are (codes of length L + count) << 1.
        # But we are going from LONG to SHORT.
        # Length L codes are (starting code of length L+1) >> 1.
        
        if current_code % 2 != 0 && b > 1
             # This should not happen if weights are correct
        end
        current_code >>= 1
    end
    
    return HuffmanTable(max_bits, table)
end

end # module
