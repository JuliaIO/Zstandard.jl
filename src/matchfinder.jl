module MatchFinder

export Sequence, find_sequences

struct Sequence
    literal_length::UInt32
    match_length::UInt32
    offset::UInt32 # This is the RAW offset (distance)
end

function hash4(data::AbstractVector{UInt8}, pos::Int)
    # Simple 4-byte hash
    h = UInt32(data[pos]) | (UInt32(data[pos+1]) << 8) | (UInt32(data[pos+2]) << 16) | (UInt32(data[pos+3]) << 24)
    # Knuth's multiplicative hash
    return (h * 0x9E3779B1)
end

function find_sequences(data::AbstractVector{UInt8}; hash_log::Int=14, search_depth::Int=64, min_match::Int=3, step::Int=1)
    n = length(data)
    sequences = Sequence[]
    
    hash_size = 1 << hash_log
    hash_table = fill(0, hash_size)
    chain_table = fill(0, n)
    
    pos = 1
    anchor = 1
    
    while pos <= n - 8
        h = (hash4(data, pos) >> (32 - hash_log)) + 1
        
        match_pos = hash_table[h]
        hash_table[h] = pos
        chain_table[pos] = match_pos
        
        best_ml = 0
        best_offset = 0
        
        depth = 0
        curr = match_pos
        while curr > 0 && depth < search_depth
            ml = 0
            while pos + ml <= n && curr + ml < pos && data[pos + ml] == data[curr + ml]
                ml += 1
                if ml >= 255
                    break
                end
            end
            
            if ml >= min_match && ml > best_ml
                best_ml = ml
                best_offset = pos - curr
            end
            
            curr = chain_table[curr]
            depth += 1
        end
        
        if best_ml >= min_match
            lit_len = pos - anchor
            push!(sequences, Sequence(UInt32(lit_len), UInt32(best_ml), UInt32(best_offset)))
            
            for i in 1:best_ml
                p = pos + i
                if p <= n - 4
                    h_p = (hash4(data, p) >> (32 - hash_log)) + 1
                    chain_table[p] = hash_table[h_p]
                    hash_table[h_p] = p
                end
            end
            
            pos += best_ml
            anchor = pos
        else
            pos += step
        end
    end
    
    last_lit_len = n - anchor + 1
    if last_lit_len > 0
        push!(sequences, Sequence(UInt32(last_lit_len), 0, 0))
    end
    
    return sequences
end

end # module
