module EncodeSequences

import ..MatchFinder: Sequence
import ..WriteBitstream: BackwardBitWriter, ForwardBitWriter, write_bits, take_bits
import ..FSE: FSETable, get_default_ll_table, get_default_ml_table, get_default_of_table
import ..FSE: LL_DEFAULT_DIST, ML_DEFAULT_DIST, OF_DEFAULT_DIST
import ..EncodeFSE: build_fse_encoding_table, fse_encode_symbol!, write_fse_table

export encode_sequences

const LL_BITS = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
]
const LL_BASE = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536
]
const ML_BITS = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
]
const ML_BASE = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
    19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
    35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539
]

# Build a normalized FSE probability distribution from observed symbol codes.
# Returns a trimmed Vector{Int} summing to table_size, or nothing if unusable.
function build_fse_distribution(codes::Vector{Int}, max_sym::Int, accuracy_log::Int)
    table_size = 1 << accuracy_log
    freqs = zeros(Int, max_sym)
    for c in codes
        if 0 <= c < max_sym; freqs[c + 1] += 1 end
    end
    total = sum(freqs)
    total == 0 && return nothing
    present = findall(>(0), freqs)
    length(present) < 2 && return nothing  # Need ≥2 symbols for FSE; use RLE mode for 1
    length(present) > table_size && return nothing

    # Give each present symbol at least 1; distribute remaining budget proportionally
    probs = zeros(Int, max_sym)
    for i in present; probs[i] = 1 end
    budget = table_size - length(present)
    budget < 0 && return nothing

    ideals   = [freqs[i] * budget / total for i in present]
    floors   = floor.(Int, ideals)
    remainds = ideals .- floors
    for (k, i) in enumerate(present); probs[i] += floors[k] end
    extra = budget - sum(floors)
    for k in sortperm(remainds, rev=true)[1:extra]; probs[present[k]] += 1 end

    # Trim trailing zeros
    last_nz = findlast(>(0), probs)
    last_nz === nothing && return nothing
    probs = probs[1:last_nz]

    # Validate all values are encodable in the VNB scheme
    remaining = table_size
    for prob in probs
        remaining <= 0 && break
        max_value = remaining + 1
        b = 1; while (1 << b) <= max_value; b += 1 end
        lower_bits = b - 1
        threshold  = (1 << b) - max_value - 1
        val = prob + 1
        if lower_bits > 0 && val >= threshold
            # Long code: val must be representable as val_read + extra_bit*(1<<lower_bits)
            # where count = val_read + extra_bit*(1<<lower_bits), then if count >= (1<<lower_bits): count -= threshold
            # So val must be in [threshold, (1<<lower_bits)) (extra_bit=0) or [(1<<lower_bits), (1<<lower_bits) + (1<<lower_bits) - threshold - 1] (extra_bit=1)
            ok = val < (1 << lower_bits) || (val >= (1 << lower_bits) && val - (1 << lower_bits) + threshold < (1 << lower_bits))
            !ok && return nothing
        end
        remaining -= (prob == -1) ? 1 : prob
    end
    return probs
end

function get_code(val::UInt32, base_table::Vector{Int})
    for i in length(base_table):-1:1
        if val >= base_table[i]
            return UInt32(i - 1)
        end
    end
    return UInt32(0)
end

function encode_sequences(io::IO, sequences::Vector{Sequence}, history_len::Int)
    # Filter out zero-match-length sequences (trailing literals; not valid FSE sequences)
    sequences = filter(s -> s.match_length > 0, sequences)
    num_sequences = length(sequences)
    if num_sequences == 0
        write(io, UInt8(0))
        return
    end
    
    if num_sequences < 128
        write(io, UInt8(num_sequences))
    elseif num_sequences < 0x7F00 + 128
        write(io, UInt8((num_sequences >> 8) | 0x80))
        write(io, UInt8(num_sequences & 0xFF))
    else
        write(io, UInt8(255))
        write(io, UInt16(num_sequences - 0x7F00))
    end
    
    seq_codes = []
    for s in sequences
        ll_code = get_code(s.literal_length, LL_BASE)
        ll_extra = s.literal_length - LL_BASE[ll_code + 1]
        ml_code = get_code(s.match_length, ML_BASE)
        ml_extra = s.match_length - ML_BASE[ml_code + 1]
        of_val = s.offset + 3
        of_code = UInt32(floor(Int, log2(of_val)))
        of_extra = of_val - (UInt32(1) << of_code)
        push!(seq_codes, (ll_code, ll_extra, ml_code, ml_extra, of_code, of_extra))
    end

    # Determine compression mode for each table:
    # Mode 0 = Predefined, Mode 1 = RLE (single symbol), Mode 2 = FSE_Compressed
    ll_codes = Int[Int(c[1]) for c in seq_codes]
    of_codes = Int[Int(c[5]) for c in seq_codes]
    ml_codes = Int[Int(c[3]) for c in seq_codes]

    ll_unique = unique(ll_codes); of_unique = unique(of_codes); ml_unique = unique(ml_codes)
    ll_probs = of_probs = ml_probs = nothing

    if num_sequences >= 8
        ll_probs = length(ll_unique) >= 2 ? build_fse_distribution(ll_codes, 36, 6) : nothing
        of_probs = length(of_unique) >= 2 ? build_fse_distribution(of_codes, 29, 5) : nothing
        ml_probs = length(ml_unique) >= 2 ? build_fse_distribution(ml_codes, 53, 6) : nothing
    end

    ll_mode = ll_probs !== nothing ? 2 : length(ll_unique) == 1 ? 1 : 0
    of_mode = of_probs !== nothing ? 2 : length(of_unique) == 1 ? 1 : 0
    ml_mode = ml_probs !== nothing ? 2 : length(ml_unique) == 1 ? 1 : 0
    write(io, UInt8((ll_mode << 6) | (of_mode << 4) | (ml_mode << 2)))

    # Write table descriptions: RLE = 1 byte (the symbol), FSE = forward bitstream
    ll_mode == 1 && write(io, UInt8(ll_unique[1]))
    of_mode == 1 && write(io, UInt8(of_unique[1]))
    ml_mode == 1 && write(io, UInt8(ml_unique[1]))

    if ll_mode == 2 || of_mode == 2 || ml_mode == 2
        fw_io = IOBuffer()
        fw = ForwardBitWriter(fw_io)
        ll_mode == 2 && write_fse_table(fw, ll_probs, 6)
        of_mode == 2 && write_fse_table(fw, of_probs, 5)
        ml_mode == 2 && write_fse_table(fw, ml_probs, 6)
        write(io, take!(fw_io))
    end

    ll_al = ll_mode == 2 ? 6 : ll_mode == 0 ? 6 : 0
    of_al = of_mode == 2 ? 5 : of_mode == 0 ? 5 : 0
    ml_al = ml_mode == 2 ? 6 : ml_mode == 0 ? 6 : 0

    ll_enc = ll_mode == 2 ? build_fse_encoding_table(ll_probs, 6) : ll_mode == 0 ? build_fse_encoding_table(LL_DEFAULT_DIST, 6) : nothing
    of_enc = of_mode == 2 ? build_fse_encoding_table(of_probs, 5) : of_mode == 0 ? build_fse_encoding_table(OF_DEFAULT_DIST, 5) : nothing
    ml_enc = ml_mode == 2 ? build_fse_encoding_table(ml_probs, 6) : ml_mode == 0 ? build_fse_encoding_table(ML_DEFAULT_DIST, 6) : nothing

    bw = BackwardBitWriter()
    ll_state = Ref{UInt32}(typemax(UInt32))
    ml_state = Ref{UInt32}(typemax(UInt32))
    of_state = Ref{UInt32}(typemax(UInt32))

    # Process ALL sequences backwards
    for i in num_sequences:-1:1
        c = seq_codes[i]

        # State Update (FSE) - written in reverse read order (OF, ML, LL)
        # so decoder (reading backward bitstream end-first) sees LL, ML, OF
        # RLE mode (mode=1): no state transitions, no bits written
        of_enc !== nothing && fse_encode_symbol!(bw, of_state, Int(c[5]), of_enc)
        ml_enc !== nothing && fse_encode_symbol!(bw, ml_state, Int(c[3]), ml_enc)
        ll_enc !== nothing && fse_encode_symbol!(bw, ll_state, Int(c[1]), ll_enc)

        # Extra Bits
        if LL_BITS[c[1] + 1] > 0
            write_bits(bw, UInt64(c[2]), LL_BITS[c[1] + 1])
        end
        if ML_BITS[c[3] + 1] > 0
            write_bits(bw, UInt64(c[4]), ML_BITS[c[3] + 1])
        end
        if c[5] > 0
            write_bits(bw, UInt64(c[6]), Int(c[5]))
        end
    end

    # Final states — write accuracy_log bits for each (0 bits for RLE mode)
    ml_al > 0 && write_bits(bw, UInt64(ml_state[]), ml_al)
    of_al > 0 && write_bits(bw, UInt64(of_state[]), of_al)
    ll_al > 0 && write_bits(bw, UInt64(ll_state[]), ll_al)

    write(io, take_bits(bw))
end

end # module
