module Sequences

import ..Bitstream: ForwardBitReader, BackwardBitReader, read_bits, align_to_byte
import ..FSE: FSETable, get_default_ll_table, get_default_ml_table, get_default_of_table, read_fse_table, build_fse_table
import ..FSE: LL_DEFAULT_DIST, ML_DEFAULT_DIST, OF_DEFAULT_DIST

export decode_sequences

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

function decode_sequences(sequences_data::Vector{UInt8}, literals::Vector{UInt8}, ctx, history::Vector{UInt8})
    if isempty(sequences_data)
        return literals
    end
    
    io = IOBuffer(sequences_data)
    byte0 = read(io, UInt8)
    if byte0 == 0
        return literals
    end
    
    num_sequences = 0
    if byte0 < 128
        num_sequences = Int(byte0)
    elseif byte0 < 255
        byte1 = read(io, UInt8)
        num_sequences = (Int(byte0 - 128) << 8) + Int(byte1)
    else
        byte1 = read(io, UInt8)
        byte2 = read(io, UInt8)
        num_sequences = Int(byte1) + (Int(byte2) << 8) + 0x7F00
    end
    
    symbol_compression_modes = read(io, UInt8)
    ll_mode = (symbol_compression_modes >> 6) & 0x03
    of_mode = (symbol_compression_modes >> 4) & 0x03
    ml_mode = (symbol_compression_modes >> 2) & 0x03
    
    fbr = ForwardBitReader(io)
    
    # 1. Literals Length table
    if ll_mode == 0 # Predefined
        ctx.ll_table = get_default_ll_table()
    elseif ll_mode == 1 # RLE
        rle_val = read(io, UInt8)
        ctx.ll_table = FSETable(0, [(Int(rle_val), 0, 0)])
    elseif ll_mode == 2 # FSE Compressed
        probs, acc = read_fse_table(fbr, 36)
        ctx.ll_table = build_fse_table(probs, acc)
    elseif ll_mode == 3 # Repeat
        if ctx.ll_table === nothing
            error("LL table Repeat Mode but no previous table")
        end
    end
    
    # 2. Offset table
    if of_mode == 0 # Predefined
        ctx.of_table = get_default_of_table()
    elseif of_mode == 1 # RLE
        rle_val = read(io, UInt8)
        ctx.of_table = FSETable(0, [(Int(rle_val), 0, 0)])
    elseif of_mode == 2 # FSE Compressed
        probs, acc = read_fse_table(fbr, 32)
        ctx.of_table = build_fse_table(probs, acc)
    elseif of_mode == 3 # Repeat
        if ctx.of_table === nothing
            error("Offset table Repeat Mode but no previous table")
        end
    end
    
    # 3. Match Length table
    if ml_mode == 0 # Predefined
        ctx.ml_table = get_default_ml_table()
    elseif ml_mode == 1 # RLE
        rle_val = read(io, UInt8)
        ctx.ml_table = FSETable(0, [(Int(rle_val), 0, 0)])
    elseif ml_mode == 2 # FSE Compressed
        probs, acc = read_fse_table(fbr, 53)
        ctx.ml_table = build_fse_table(probs, acc)
    elseif ml_mode == 3 # Repeat
        if ctx.ml_table === nothing
            error("ML table Repeat Mode but no previous table")
        end
    end
    
    pos = position(io)
    remaining_data = @view sequences_data[pos+1:end]
    
    bbr = BackwardBitReader(remaining_data)
    
    ll_table = ctx.ll_table
    of_table = ctx.of_table
    ml_table = ctx.ml_table
    
    # Initialize states
    ll_state = (ll_table.accuracy_log > 0) ? Int(read_bits(bbr, ll_table.accuracy_log)) : 0
    of_state = (of_table.accuracy_log > 0) ? Int(read_bits(bbr, of_table.accuracy_log)) : 0
    ml_state = (ml_table.accuracy_log > 0) ? Int(read_bits(bbr, ml_table.accuracy_log)) : 0
    
    # Pre-estimate output size: literals + rough match estimate
    hist_len = length(history)
    output = Vector{UInt8}(undef, length(literals) * 2 + 1024)
    out_pos = 0
    lit_pos = 1

    for i in 1:num_sequences
        of_code = of_table.table[of_state + 1][1]
        ml_code = ml_table.table[ml_state + 1][1]
        ll_code = ll_table.table[ll_state + 1][1]

        of_bits = Int(of_code)
        offset_val = (Int(1) << of_bits) + Int(read_bits(bbr, of_bits))

        ml_val = ML_BASE[ml_code + 1] + Int(read_bits(bbr, ML_BITS[ml_code + 1]))
        ll_val = LL_BASE[ll_code + 1] + Int(read_bits(bbr, LL_BITS[ll_code + 1]))

        # Ensure capacity for literals + match
        needed = out_pos + ll_val + ml_val
        if needed > length(output)
            resize!(output, max(needed, length(output) * 2))
        end

        # Copy literals
        if ll_val > 0
            copyto!(output, out_pos + 1, literals, lit_pos, ll_val)
            out_pos += ll_val
            lit_pos += ll_val
        end

        # Determine actual offset
        offset = 0
        if offset_val > 3
            offset = offset_val - 3
            ctx.rep_offsets[3] = ctx.rep_offsets[2]
            ctx.rep_offsets[2] = ctx.rep_offsets[1]
            ctx.rep_offsets[1] = offset
        else
            rep_idx = offset_val
            if ll_val == 0
                rep_idx += 1
            end

            if rep_idx == 1
                offset = ctx.rep_offsets[1]
            elseif rep_idx == 2
                offset = ctx.rep_offsets[2]
                ctx.rep_offsets[2] = ctx.rep_offsets[1]
                ctx.rep_offsets[1] = offset
            elseif rep_idx == 3
                offset = ctx.rep_offsets[3]
                ctx.rep_offsets[3] = ctx.rep_offsets[2]
                ctx.rep_offsets[2] = ctx.rep_offsets[1]
                ctx.rep_offsets[1] = offset
            elseif rep_idx == 4
                offset = ctx.rep_offsets[1] - 1
                ctx.rep_offsets[3] = ctx.rep_offsets[2]
                ctx.rep_offsets[2] = ctx.rep_offsets[1]
                ctx.rep_offsets[1] = offset
            end
        end

        # Copy match from history and/or output
        match_start = (hist_len + out_pos) - offset + 1
        if match_start > hist_len && offset >= ml_val
            # Entirely within output, non-overlapping — bulk copy
            copyto!(output, out_pos + 1, output, match_start - hist_len, ml_val)
            out_pos += ml_val
        else
            # Byte-by-byte: either from history, or overlapping copy
            for m in 1:ml_val
                target_idx = (hist_len + out_pos) - offset + 1
                out_pos += 1
                if target_idx <= hist_len
                    output[out_pos] = history[target_idx]
                else
                    output[out_pos] = output[target_idx - hist_len]
                end
            end
        end

        if i < num_sequences
            ll_state = (ll_table.accuracy_log > 0) ? (Int(read_bits(bbr, ll_table.table[ll_state + 1][2])) + ll_table.table[ll_state + 1][3]) : 0
            ml_state = (ml_table.accuracy_log > 0) ? (Int(read_bits(bbr, ml_table.table[ml_state + 1][2])) + ml_table.table[ml_state + 1][3]) : 0
            of_state = (of_table.accuracy_log > 0) ? (Int(read_bits(bbr, of_table.table[of_state + 1][2])) + of_table.table[of_state + 1][3]) : 0
        end
    end

    # Remaining literals
    remaining_lits = length(literals) - lit_pos + 1
    if remaining_lits > 0
        needed = out_pos + remaining_lits
        if needed > length(output)
            resize!(output, needed)
        end
        copyto!(output, out_pos + 1, literals, lit_pos, remaining_lits)
        out_pos += remaining_lits
    end

    resize!(output, out_pos)
    return output
end

end # module
