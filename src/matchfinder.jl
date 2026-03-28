module MatchFinder

export Sequence, find_sequences, MatchContext

"""
    SAFE_MODE[]

Set to `true` to use bounds-checked array access instead of `unsafe_load` in the
match finder. Useful for debugging. Toggle with:

    Zstandard.MatchFinder.SAFE_MODE[] = true
"""
const SAFE_MODE = Ref(false)

struct Sequence
    literal_length::UInt32
    match_length::UInt32
    offset::UInt32 # This is the RAW offset (distance)
end

"""
    MatchContext

Pre-allocated tables for the match finder, reusable across blocks.
Create once and pass to `find_sequences` to avoid per-call allocation.
"""
mutable struct MatchContext
    hash_table::Vector{Int32}
    chain_table::Vector{Int32}
    hash_log::Int
end

function MatchContext(; hash_log::Int=14, max_block_size::Int=128*1024)
    hash_size = 1 << hash_log
    MatchContext(Vector{Int32}(undef, hash_size), Vector{Int32}(undef, max_block_size), hash_log)
end

function reset!(ctx::MatchContext, n::Int)
    fill!(ctx.hash_table, Int32(0))  # 16K entries = 64KB, fast memset
    if length(ctx.chain_table) < n
        resize!(ctx.chain_table, n)
    end
    # chain_table doesn't need zeroing: entries are written before read
end

@inline function hash4_safe(data::AbstractVector{UInt8}, pos::Int)
    @inbounds h = UInt32(data[pos]) | (UInt32(data[pos+1]) << 8) | (UInt32(data[pos+2]) << 16) | (UInt32(data[pos+3]) << 24)
    return h * 0x9E3779B1
end

@inline function hash4_unsafe(ptr::Ptr{UInt8}, pos::Int)
    h = unsafe_load(Ptr{UInt32}(ptr + pos - 1))
    return h * 0x9E3779B1
end

@inline function count_match_safe(data::AbstractVector{UInt8}, pos::Int, curr::Int, limit::Int)
    ml = 0
    @inbounds while ml < limit && data[pos + ml] == data[curr + ml]
        ml += 1
    end
    return ml
end

@inline function count_match_unsafe(ptr::Ptr{UInt8}, pos::Int, curr::Int, limit::Int)
    ml = 0
    # Compare 8 bytes at a time
    while ml + 8 <= limit
        v1 = unsafe_load(Ptr{UInt64}(ptr + pos + ml - 1))
        v2 = unsafe_load(Ptr{UInt64}(ptr + curr + ml - 1))
        diff = xor(v1, v2)
        if diff != 0
            return ml + trailing_zeros(diff) >> 3
        end
        ml += 8
    end
    # Remaining bytes
    while ml < limit && unsafe_load(ptr, pos + ml) == unsafe_load(ptr, curr + ml)
        ml += 1
    end
    return ml
end

function find_sequences(data::AbstractVector{UInt8}; hash_log::Int=14, search_depth::Int=64, min_match::Int=3, step::Int=1, ctx::Union{Nothing,MatchContext}=nothing)
    Base.require_one_based_indexing(data)
    if SAFE_MODE[]
        return _find_sequences_safe(data; hash_log, search_depth, min_match, step, ctx)
    else
        return _find_sequences_unsafe(data; hash_log, search_depth, min_match, step, ctx)
    end
end

function _find_sequences_safe(data::AbstractVector{UInt8}; hash_log::Int, search_depth::Int, min_match::Int, step::Int, ctx::Union{Nothing,MatchContext})
    n = length(data)
    sequences = Sequence[]

    if ctx !== nothing && ctx.hash_log == hash_log
        reset!(ctx, n)
        hash_table = ctx.hash_table
        chain_table = ctx.chain_table
    else
        hash_size = 1 << hash_log
        hash_table = zeros(Int32, hash_size)
        chain_table = Vector{Int32}(undef, n)
    end

    pos = 1
    anchor = 1
    accel = 1

    while pos <= n - 8
        h = (hash4_safe(data, pos) >> (32 - hash_log)) + 1

        @inbounds match_pos = Int(hash_table[h])
        @inbounds hash_table[h] = pos
        @inbounds chain_table[pos] = match_pos

        best_ml = 0
        best_offset = 0

        depth = 0
        curr = match_pos
        while curr > 0 && curr < pos && depth < search_depth
            limit = n - pos + 1
            ml = count_match_safe(data, pos, curr, limit)

            if ml >= min_match && ml > best_ml
                best_ml = ml
                best_offset = pos - curr
                ml >= 255 && break  # Early exit for very long matches
            end

            @inbounds curr = Int(chain_table[curr])
            depth += 1
        end

        if best_ml >= min_match
            lit_len = pos - anchor
            push!(sequences, Sequence(UInt32(lit_len), UInt32(best_ml), UInt32(best_offset)))

            step_hash = best_ml > 16 ? 2 : 1
            for i in 1:step_hash:best_ml
                p = pos + i
                if p <= n - 4
                    h_p = (hash4_safe(data, p) >> (32 - hash_log)) + 1
                    @inbounds chain_table[p] = hash_table[h_p]
                    @inbounds hash_table[h_p] = p
                end
            end

            pos += best_ml
            anchor = pos
            accel = 1
        else
            pos += max(step, accel >> 8)
            accel += 1
        end
    end

    last_lit_len = n - anchor + 1
    if last_lit_len > 0
        push!(sequences, Sequence(UInt32(last_lit_len), 0, 0))
    end

    return sequences
end

function _find_sequences_unsafe(data::AbstractVector{UInt8}; hash_log::Int, search_depth::Int, min_match::Int, step::Int, ctx::Union{Nothing,MatchContext})
    n = length(data)
    sequences = Sequence[]

    if ctx !== nothing && ctx.hash_log == hash_log
        reset!(ctx, n)
        hash_table = ctx.hash_table
        chain_table = ctx.chain_table
    else
        hash_size = 1 << hash_log
        hash_table = zeros(Int32, hash_size)
        chain_table = Vector{Int32}(undef, n)
    end

    pos = 1
    anchor = 1
    accel = 1  # Acceleration: increases on consecutive misses, resets on hit

    GC.@preserve data begin
    ptr = pointer(data)

    while pos <= n - 8
        h = (hash4_unsafe(ptr, pos) >> (32 - hash_log)) + 1

        @inbounds match_pos = Int(hash_table[h])
        @inbounds hash_table[h] = pos
        @inbounds chain_table[pos] = match_pos

        best_ml = 0
        best_offset = 0

        depth = 0
        curr = match_pos
        while curr > 0 && curr < pos && depth < search_depth
            limit = n - pos + 1
            ml = count_match_unsafe(ptr, pos, curr, limit)

            if ml >= min_match && ml > best_ml
                best_ml = ml
                best_offset = pos - curr
                ml >= 255 && break  # Early exit for very long matches
            end

            @inbounds curr = Int(chain_table[curr])
            depth += 1
        end

        if best_ml >= min_match
            lit_len = pos - anchor
            push!(sequences, Sequence(UInt32(lit_len), UInt32(best_ml), UInt32(best_offset)))

            step_hash = best_ml > 16 ? 2 : 1
            for i in 1:step_hash:best_ml
                p = pos + i
                if p <= n - 4
                    h_p = (hash4_unsafe(ptr, p) >> (32 - hash_log)) + 1
                    @inbounds chain_table[p] = hash_table[h_p]
                    @inbounds hash_table[h_p] = p
                end
            end

            pos += best_ml
            anchor = pos
            accel = 1  # Reset acceleration after a match
        else
            pos += max(step, accel >> 8)  # Accelerate: skip more after repeated misses
            accel += 1
        end
    end

    end # GC.@preserve

    last_lit_len = n - anchor + 1
    if last_lit_len > 0
        push!(sequences, Sequence(UInt32(last_lit_len), 0, 0))
    end

    return sequences
end

end # module
