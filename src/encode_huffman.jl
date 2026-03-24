module EncodeHuffman

export HuffmanEncoder, build_huffman_encoder, encode_huffman_literals

struct HuffmanEncoder
    weights::Vector{Int}
    max_bits::Int
    codes::Vector{UInt32}
    bits::Vector{Int}
end

function build_huffman_tree(freqs::Vector{Int}, max_bits::Int=11)
    num_symbols = length(freqs)
    # 1. Basic Huffman tree construction using a heap or simple sorting
    # To keep it simple and pure Julia, let's use a simple node structure
    nodes = [(f, i-1) for (i, f) in enumerate(freqs) if f > 0]
    if isempty(nodes)
        return Int[], 0
    end
    if length(nodes) == 1
        # Special case: only one symbol
        weights = zeros(Int, num_symbols)
        weights[nodes[1][2] + 1] = 1
        return weights, 1
    end

    # Simple tree building
    tree = Any[]
    for n in nodes
        push!(tree, n)
    end
    
    while length(tree) > 1
        sort!(tree, by=x->x[1])
        n1 = popfirst!(tree)
        n2 = popfirst!(tree)
        push!(tree, (n1[1] + n2[1], (n1, n2)))
    end
    
    root = tree[1]
    
    # Calculate bit lengths
    lengths = zeros(Int, num_symbols)
    function walk(node, d)
        if node[2] isa Int
            lengths[node[2] + 1] = d
        else
            walk(node[2][1], d + 1)
            walk(node[2][2], d + 1)
        end
    end
    walk(root, 0)
    
    # TODO: Limit bit lengths to max_bits (11) if needed.
    # For small literal sections, this is usually not an issue.
    
    actual_max_bits = maximum(lengths)
    
    # Calculate Zstd Weights
    # Weight = max_bits + 1 - Length (for Length > 0)
    weights = zeros(Int, num_symbols)
    for i in 1:num_symbols
        if lengths[i] > 0
            weights[i] = actual_max_bits + 1 - lengths[i]
        end
    end
    
    return weights, actual_max_bits
end

function build_huffman_encoder(literals::AbstractVector{UInt8})
    freqs = zeros(Int, 256)
    for b in literals
        freqs[Int(b) + 1] += 1
    end
    
    weights, max_bits = build_huffman_tree(freqs)
    if max_bits == 0
        return nothing
    end
    
    # Generate canonical codes
    # We must match the decoder's canonical logic
    num_symbols = 256
    bits_per_symbol = zeros(Int, num_symbols)
    for i in 1:num_symbols
        if weights[i] > 0
            bits_per_symbol[i] = max_bits + 1 - weights[i]
        end
    end
    
    codes = zeros(UInt32, num_symbols)
    current_code = UInt32(0)
    for b in max_bits:-1:1
        for s in 1:num_symbols
            if bits_per_symbol[s] == b
                codes[s] = current_code
                current_code += 1
            end
        end
        current_code >>= 1
    end
    
    return HuffmanEncoder(weights, max_bits, codes, bits_per_symbol)
end

function encode_huffman_literals(io::IO, literals::AbstractVector{UInt8}, encoder::HuffmanEncoder)
    # This will implement writing the Huffman Tree Description and the coded streams.
    # For now, let's just return a placeholder to avoid breaking the build.
    error("Huffman literal encoding not yet fully implemented")
end

end # module
