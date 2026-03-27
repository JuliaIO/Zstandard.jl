module EncodeFSE

import ..WriteBitstream: BackwardBitWriter, write_bits

export FSEEncodingTable, build_fse_encoding_table, fse_encode_symbol!

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
        k_s = accuracy_log - floor(Int, log2(freq)); deltaNbBits[sym] = (UInt32(k_s) << 16) - (UInt32(freq) << k_s)
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

end # module
