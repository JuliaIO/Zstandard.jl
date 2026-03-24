module EncodeSequences

import ..MatchFinder: Sequence
import ..WriteBitstream: BackwardBitWriter, write_bits, take_bits
import ..FSE: FSETable, get_default_ll_table, get_default_ml_table, get_default_of_table

export encode_sequences

struct FSEEncodingTable
    accuracy_log::Int
    symbol_next_state::Vector{Vector{Int}} # symbol -> list of states in order
    symbol_counters::Vector{Int}
end

function build_encoding_table(dt::FSETable, num_symbols::Int)
    # We need to know where each symbol is in the decoding table
    symbol_states = [Int[] for _ in 1:num_symbols]
    for (state, cell) in enumerate(dt.table)
        sym = cell[1]
        if sym >= 0 && sym < num_symbols
            push!(symbol_states[sym + 1], state - 1)
        end
    end
    return FSEEncodingTable(dt.accuracy_log, symbol_states, zeros(Int, num_symbols))
end

# Re-use BITS and BASE from Sequences or define them here
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

function get_code(val::UInt32, base_table::Vector{Int})
    # Binary search or simple loop for code
    # For now, simple loop
    for i in length(base_table):-1:1
        if val >= base_table[i]
            return UInt32(i - 1)
        end
    end
    return UInt32(0)
end

function encode_sequences(io::IO, sequences::Vector{Sequence}, history_len::Int)
    num_sequences = length(sequences)
    if num_sequences == 0
        write(io, UInt8(0))
        return
    end
    
    # 1. Number_of_Sequences
    if num_sequences < 128
        write(io, UInt8(num_sequences))
    elseif num_sequences < 0x7F00 + 128
        write(io, UInt8((num_sequences >> 8) | 0x80))
        write(io, UInt8(num_sequences & 0xFF))
    else
        write(io, UInt8(255))
        write(io, UInt16(num_sequences - 0x7F00))
    end
    
    # 2. Symbol_Compression_Modes
    # 0 for Predefined_Mode (all 3 tables)
    write(io, UInt8(0))
    
    # Tables
    ll_dt = get_default_ll_table()
    of_dt = get_default_of_table()
    ml_dt = get_default_ml_table()
    
    # Pre-calculate codes and extra bits
    seq_codes = []
    for s in sequences
        ll_code = get_code(s.literal_length, LL_BASE)
        ll_extra = s.literal_length - LL_BASE[ll_code + 1]
        
        ml_code = get_code(s.match_length, ML_BASE)
        ml_extra = s.match_length - ML_BASE[ml_code + 1]
        
        # Offset encoding: offset_code = floor(log2(offset))
        # and offset_val = (1 << code) + extra. 
        # But wait, Zstd Offset_Value = Offset + 3.
        # So Offset = Offset_Value - 3.
        # The match finder found "distance", which IS the offset.
        # So Offset_Value = distance + 3.
        of_val = s.offset + 3
        of_code = UInt32(floor(Int, log2(of_val)))
        of_extra = of_val - (UInt32(1) << of_code)
        
        push!(seq_codes, (ll_code, ll_extra, ml_code, ml_extra, of_code, of_extra))
    end
    
    # 3. Bitstream (Backward)
    bw = BackwardBitWriter()
    
    # FSE states
    # To encode, we need to know the next state.
    # This is non-trivial. The simplest "encoding" is actually to 
    # work backwards through the sequences and forwards through the FSE states?
    # No, FSE encoding is done by:
    # State = (State << nbBits) | read_bits(bw, nbBits)
    # Wait, that's decoding.
    # Encoding:
    # nbBits = (State + symbol_prob) >> AccuracyLog (approx)
    # NewState = Table[symbol].States[index++]
    
    # For Phase 2, let's try to implement a minimal functional FSE encoder.
    # Actually, if we use Predefined tables, we must match them.
    
    # Let's skip FSE for one more turn and just output Raw literals for now.
    # Wait, if I want Level 3, I need sequences.
    
    error("FSE encoding logic is still in progress. Fallback to Raw Block.")
end

end # module
