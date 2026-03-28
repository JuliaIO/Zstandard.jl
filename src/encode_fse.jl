module EncodeFSE

import ..WriteBitstream: BackwardBitWriter, ForwardBitWriter, write_bits, flush_bits

export FSEEncodingTable, build_fse_encoding_table, fse_encode_symbol!, write_fse_table

struct FSEEncodingTable
    accuracy_log::Int
    state_table::Vector{UInt16}
    deltaNbBits::Vector{UInt32}
    deltaFindState::Vector{Int32}
    symbol_probs::Vector{Int}
end

function build_fse_encoding_table(probabilities::Vector{Int}, accuracy_log::Int)
    table_size = 1 << accuracy_log
    num_symbols = length(probabilities)
    pos = 0; step = (table_size >> 1) + (table_size >> 3) + 3; mask = table_size - 1
    spread = fill(-1, table_size); high_threshold = table_size
    for (sym, p) in enumerate(probabilities)
        if p == -1; high_threshold -= 1; spread[high_threshold + 1] = sym - 1 end
    end
    pos = 0
    for (sym, p) in enumerate(probabilities)
        if p > 0
            for i in 1:p
                spread[pos + 1] = sym - 1
                pos = (pos + step) & mask
                while pos >= high_threshold; pos = (pos + step) & mask end
            end
        end
    end
    symbol_states = [UInt16[] for _ in 1:num_symbols]
    for i in 1:table_size
        sym_val = spread[i]
        if sym_val >= 0; push!(symbol_states[sym_val + 1], UInt16(i - 1)) end
    end
    deltaNbBits = zeros(UInt32, num_symbols); deltaFindState = zeros(Int32, num_symbols)
    state_table = UInt16[]; cumulative_states = 0
    for (sym, p) in enumerate(probabilities)
        freq = p == -1 ? 1 : p
        if freq == 0; continue end
        k_s = accuracy_log - (8 * sizeof(freq) - leading_zeros(freq) - 1); deltaNbBits[sym] = (UInt32(k_s) << 16) - (UInt32(freq) << k_s)
        deltaFindState[sym] = Int32(cumulative_states - freq)
        append!(state_table, symbol_states[sym])
        cumulative_states += freq
    end
    return FSEEncodingTable(accuracy_log, state_table, deltaNbBits, deltaFindState, probabilities)
end

function fse_encode_symbol!(bw::BackwardBitWriter, state::Ref{UInt32}, sym::Int, table::FSEEncodingTable)
    sym_idx = sym + 1
    if state[] == typemax(UInt32)
        # Initialization: set initial state for the last sequence, write no bits.
        # Valid states are in [0, table_size-1], so typemax(UInt32) is a safe sentinel.
        freq = table.symbol_probs[sym_idx] == -1 ? 1 : table.symbol_probs[sym_idx]
        state[] = UInt32(table.state_table[table.deltaFindState[sym_idx] + freq + 1])
        return
    end
    table_size = 1 << table.accuracy_log
    X_plus = state[] + table_size
    nbBitsOut = (X_plus + table.deltaNbBits[sym_idx]) >> 16
    if nbBitsOut > 0; write_bits(bw, UInt64(state[] & ((UInt32(1) << nbBitsOut) - 1)), Int(nbBitsOut)) end
    state[] = UInt32(table.state_table[(X_plus >> nbBitsOut) + table.deltaFindState[sym_idx] + 1])
end

# Inverse of FSE.read_fse_table. Writes a byte-aligned FSE table description to fw.
# probabilities must not contain trailing zeros; all interior zeros must be encodable.
function write_fse_table(fw::ForwardBitWriter, probabilities::Vector{Int}, accuracy_log::Int)
    write_bits(fw, UInt32(accuracy_log - 5), 4)
    remaining = 1 << accuracy_log
    i = 1
    while remaining > 0 && i <= length(probabilities)
        prob = probabilities[i]
        max_value = remaining + 1

        bits_to_read = 1
        while (1 << bits_to_read) <= max_value; bits_to_read += 1 end
        if max_value == 1; bits_to_read = 1 end
        lower_bits = bits_to_read - 1
        threshold = (1 << bits_to_read) - max_value - 1

        val = prob + 1  # prob=-1 → val=0; prob=k → val=k+1

        if lower_bits == 0
            write_bits(fw, UInt32(val), 1)
        elseif val < threshold
            write_bits(fw, UInt32(val), lower_bits)
        elseif val < (1 << lower_bits)
            # Long code, extra_bit=0: val_read = val
            write_bits(fw, UInt32(val), lower_bits)
            write_bits(fw, UInt32(0), 1)
        else
            # Long code, extra_bit=1: val_read = val - (1<<lower_bits) + threshold
            val_read = val - (1 << lower_bits) + threshold
            write_bits(fw, UInt32(val_read), lower_bits)
            write_bits(fw, UInt32(1), 1)
        end

        remaining -= (prob == -1) ? 1 : prob

        if prob == 0
            # Count additional consecutive zeros to encode as run-length
            j = i + 1
            extra_zeros = 0
            while j <= length(probabilities) && probabilities[j] == 0
                extra_zeros += 1; j += 1
            end
            # Write 2-bit chunks (repeat_flag); value 3 means "continue reading"
            written = 0
            while true
                chunk = min(extra_zeros - written, 3)
                write_bits(fw, UInt32(chunk), 2)
                written += chunk
                chunk < 3 && break
            end
            i = j
        else
            i += 1
        end
    end
    flush_bits(fw)  # byte-align
end

end # module
