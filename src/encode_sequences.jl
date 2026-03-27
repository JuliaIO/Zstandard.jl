module EncodeSequences

import ..MatchFinder: Sequence
import ..WriteBitstream: BackwardBitWriter, write_bits, take_bits
import ..FSE: FSETable, get_default_ll_table, get_default_ml_table, get_default_of_table
import ..FSE: LL_DEFAULT_DIST, ML_DEFAULT_DIST, OF_DEFAULT_DIST
import ..EncodeFSE: build_fse_encoding_table, fse_encode_symbol!

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
    
    write(io, UInt8(0))
    
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
    
    ll_enc = build_fse_encoding_table(LL_DEFAULT_DIST, 6)
    of_enc = build_fse_encoding_table(OF_DEFAULT_DIST, 5)
    ml_enc = build_fse_encoding_table(ML_DEFAULT_DIST, 6)
    
    bw = BackwardBitWriter()
    ll_state = Ref{UInt32}(typemax(UInt32))
    ml_state = Ref{UInt32}(typemax(UInt32))
    of_state = Ref{UInt32}(typemax(UInt32))
    
    # Process ALL sequences backwards
    for i in num_sequences:-1:1
        c = seq_codes[i]
        
        # State Update (FSE) - written in reverse read order (OF, ML, LL)
        # so decoder (reading backward bitstream end-first) sees LL, ML, OF
        fse_encode_symbol!(bw, of_state, Int(c[5]), of_enc)
        fse_encode_symbol!(bw, ml_state, Int(c[3]), ml_enc)
        fse_encode_symbol!(bw, ll_state, Int(c[1]), ll_enc)
        
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
    
    # Final states
    # states are in [0, table_size - 1]; decoder reads Accuracy_Log bits directly.
    write_bits(bw, UInt64(ml_state[]), 6)
    write_bits(bw, UInt64(of_state[]), 5)
    write_bits(bw, UInt64(ll_state[]), 6)
    
    write(io, take_bits(bw))
end

end # module
