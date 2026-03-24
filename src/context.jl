module Context

import ..Huffman: HuffmanTable

export FrameContext

mutable struct FrameContext
    window_size::Int
    rep_offsets::Vector{Int}
    huffman_table::Union{Nothing, HuffmanTable}
end

function FrameContext(window_size::Int)
    return FrameContext(window_size, [1, 4, 8], nothing)
end

end # module
