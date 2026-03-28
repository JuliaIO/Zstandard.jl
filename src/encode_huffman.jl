module EncodeHuffman

import ..WriteBitstream: BackwardBitWriter, write_bits, take_bits

export HuffmanEncoder, build_huffman_encoder, encode_huffman_literals

struct HuffmanEncoder
    weights::Vector{Int}
    max_bits::Int
    codes::Vector{UInt32}
    bits::Vector{Int}
end

function build_huffman_tree(freqs::Vector{Int}, max_bits_limit::Int=11)
    num_symbols = length(freqs)

    # Collect active symbols
    active = Int[]
    for i in 1:num_symbols
        if freqs[i] > 0
            push!(active, i)
        end
    end

    if isempty(active)
        return Int[], 0
    end
    if length(active) == 1
        weights = zeros(Int, num_symbols)
        weights[active[1]] = 1
        return weights, 1
    end

    # Build Huffman tree using flat arrays instead of recursive Any[] tuples.
    # Each node has: freq, left child index (-1 if leaf), right child index, symbol (if leaf).
    n_active = length(active)
    max_nodes = 2 * n_active - 1
    node_freq  = Vector{Int}(undef, max_nodes)
    node_left  = Vector{Int}(undef, max_nodes)  # -1 for leaf
    node_right = Vector{Int}(undef, max_nodes)
    node_sym   = Vector{Int}(undef, max_nodes)  # 1-indexed symbol, only valid for leaves

    # Initialize leaf nodes
    for i in 1:n_active
        node_freq[i]  = freqs[active[i]]
        node_left[i]  = -1
        node_right[i] = -1
        node_sym[i]   = active[i]
    end
    num_nodes = n_active

    # Simple priority queue: maintain a sorted list of active node indices by freq.
    # Use a flat array sorted descending so pop! gives the minimum.
    pq = collect(1:n_active)
    sort!(pq, by=i -> node_freq[i], rev=true)

    while length(pq) > 1
        # Pop two smallest (from end, since sorted descending)
        n1 = pop!(pq)
        n2 = pop!(pq)

        # Create internal node
        num_nodes += 1
        node_freq[num_nodes]  = node_freq[n1] + node_freq[n2]
        node_left[num_nodes]  = n1
        node_right[num_nodes] = n2
        node_sym[num_nodes]   = 0

        # Insert new node in sorted position (descending by freq)
        new_f = node_freq[num_nodes]
        idx = searchsortedlast(pq, num_nodes, by=i -> -node_freq[i])
        insert!(pq, idx + 1, num_nodes)
    end

    root = pq[1]

    # Walk tree to assign bit lengths (iterative to avoid stack overflow)
    lengths = zeros(Int, num_symbols)
    stack = [(root, 0)]
    while !isempty(stack)
        nd, d = pop!(stack)
        if node_left[nd] == -1  # leaf
            lengths[node_sym[nd]] = d
        else
            push!(stack, (node_left[nd], d + 1))
            push!(stack, (node_right[nd], d + 1))
        end
    end

    limit_bit_lengths!(lengths, max_bits_limit)

    actual_max_bits = maximum(l for l in lengths if l > 0)

    weights = zeros(Int, num_symbols)
    for i in 1:num_symbols
        if lengths[i] > 0
            weights[i] = actual_max_bits + 1 - lengths[i]
        end
    end

    return weights, actual_max_bits
end

function limit_bit_lengths!(lengths::Vector{Int}, max_bits::Int)
    any(l > max_bits for l in lengths) || return

    for i in eachindex(lengths)
        if lengths[i] > max_bits
            lengths[i] = max_bits
        end
    end

    # Rebalance: compute code units used vs available
    available = 1 << max_bits
    used = sum(lengths[i] > 0 ? (1 << (max_bits - lengths[i])) : 0 for i in eachindex(lengths))

    # Increment shortest codes to free up code space
    while used > available
        best_idx = -1
        best_len = max_bits
        for i in eachindex(lengths)
            if 0 < lengths[i] < best_len
                best_len = lengths[i]
                best_idx = i
            end
        end
        best_idx == -1 && break
        used -= (1 << (max_bits - lengths[best_idx]))
        lengths[best_idx] += 1
        used += (1 << (max_bits - lengths[best_idx]))
    end
end

function build_huffman_encoder(literals::AbstractVector{UInt8})
    freqs = zeros(Int, 256)
    for b in literals
        freqs[Int(b) + 1] += 1
    end

    num_unique = count(f -> f > 0, freqs)
    if num_unique <= 1
        return nothing
    end

    weights, max_bits = build_huffman_tree(freqs)
    if max_bits == 0
        return nothing
    end

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

function encode_huffman_tree_description(io::IO, encoder::HuffmanEncoder)
    weights = encoder.weights
    # Find highest-index symbol with nonzero weight (0-indexed = last_sym)
    last_sym = 0
    for i in 256:-1:1
        if weights[i] > 0
            last_sym = i - 1  # 0-indexed
            break
        end
    end
    # Direct encoding only supports last_sym <= 128 (header byte = num_stored + 127 <= 255)
    last_sym > 128 && error("direct encoding requires last_sym <= 128")
    # Store weights for symbols 0..last_sym-1; decoder derives weight for last_sym
    num_stored = last_sym
    write(io, UInt8(num_stored + 127))
    # Pack 2 weights per byte: high nibble first
    i = 1  # 1-indexed into weights[1..num_stored]
    while i <= num_stored
        w1 = weights[i]
        w2 = (i + 1 <= num_stored) ? weights[i + 1] : 0
        write(io, UInt8((w1 << 4) | (w2 & 0x0F)))
        i += 2
    end
end

function encode_huffman_bitstream(literals::AbstractVector{UInt8}, encoder::HuffmanEncoder)
    bw = BackwardBitWriter()
    for i in length(literals):-1:1
        sym = Int(literals[i])
        n = encoder.bits[sym + 1]
        if n > 0
            write_bits(bw, UInt64(encoder.codes[sym + 1]), n)
        end
    end
    return take_bits(bw)
end

function write_compressed_literals_header(io::IO, regen_size::Int, compressed_size::Int, size_format::Int)
    type = 2  # Compressed_Literals_Block
    if size_format == 0 || size_format == 1
        b1 = UInt8(type | (size_format << 2) | ((regen_size & 0x0F) << 4))
        b2 = UInt8(((regen_size >> 4) & 0x3F) | ((compressed_size & 0x03) << 6))
        b3 = UInt8((compressed_size >> 2) & 0xFF)
        write(io, b1, b2, b3)
    elseif size_format == 2
        b1 = UInt8(type | (2 << 2) | ((regen_size & 0x0F) << 4))
        b2 = UInt8((regen_size >> 4) & 0xFF)
        b3 = UInt8(((regen_size >> 12) & 0x03) | ((compressed_size & 0x3F) << 2))
        b4 = UInt8((compressed_size >> 6) & 0xFF)
        write(io, b1, b2, b3, b4)
    elseif size_format == 3
        b1 = UInt8(type | (3 << 2) | ((regen_size & 0x0F) << 4))
        b2 = UInt8((regen_size >> 4) & 0xFF)
        b3 = UInt8(((regen_size >> 12) & 0x3F) | ((compressed_size & 0x03) << 6))
        b4 = UInt8((compressed_size >> 2) & 0xFF)
        b5 = UInt8((compressed_size >> 10) & 0xFF)
        write(io, b1, b2, b3, b4, b5)
    end
end

function encode_huffman_literals(io::IO, literals::AbstractVector{UInt8}, encoder::HuffmanEncoder)::Bool
    regen_size = length(literals)

    # Check direct-encoding feasibility: highest symbol must be <= 128
    weights = encoder.weights
    last_sym = 0
    for i in 256:-1:1
        if weights[i] > 0; last_sym = i - 1; break; end
    end
    last_sym > 128 && return false

    # Encode tree description
    tree_io = IOBuffer()
    encode_huffman_tree_description(tree_io, encoder)
    tree_bytes = take!(tree_io)

    if regen_size > 1023
        # 4-stream encoding (required for size_format >= 2)
        chunk_size = (regen_size + 3) ÷ 4
        s1 = encode_huffman_bitstream(view(literals, 1:chunk_size), encoder)
        s2 = encode_huffman_bitstream(view(literals, chunk_size+1:2*chunk_size), encoder)
        s3 = encode_huffman_bitstream(view(literals, 2*chunk_size+1:3*chunk_size), encoder)
        s4 = encode_huffman_bitstream(view(literals, 3*chunk_size+1:regen_size), encoder)

        jump = UInt8[]
        for sz in (length(s1), length(s2), length(s3))
            push!(jump, UInt8(sz & 0xFF), UInt8((sz >> 8) & 0xFF))
        end
        stream_bytes = vcat(jump, s1, s2, s3, s4)
        compressed_size = length(tree_bytes) + length(stream_bytes)

        size_format = max(regen_size, compressed_size) <= 16383 ? 2 : 3
        write_compressed_literals_header(io, regen_size, compressed_size, size_format)
    else
        # Single stream
        stream_bytes = encode_huffman_bitstream(literals, encoder)
        compressed_size = length(tree_bytes) + length(stream_bytes)
        # For single stream: compressed_size < regen_size <= 1023, so fits in 10 bits
        write_compressed_literals_header(io, regen_size, compressed_size, 0)
    end

    write(io, tree_bytes)
    write(io, stream_bytes)
    return true
end

end # module
