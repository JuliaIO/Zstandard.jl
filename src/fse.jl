module FSE

import ..Bitstream: ForwardBitReader, read_bits, align_to_byte

export read_fse_table, build_fse_table, FSETable

struct FSETable
    accuracy_log::Int
    table::Vector{Tuple{Int, Int, Int}} # (symbol, num_bits, baseline)
end

function read_fse_table(br::ForwardBitReader, max_symbols::Int)
    accuracy_log = read_bits(br, 4) + 5
    
    remaining_probabilities = 1 << accuracy_log
    probabilities = Int[]
    
    sym = 0
    while remaining_probabilities > 0 && sym < max_symbols
        max_value = remaining_probabilities + 1
        bits_to_read = 0
        while (1 << bits_to_read) <= max_value
            bits_to_read += 1
        end
        if max_value == 1
            bits_to_read = 1
        end
        
        lower_bits = bits_to_read - 1
        threshold = (1 << bits_to_read) - max_value - 1
        
        val_read = read_bits(br, lower_bits)
        if val_read < threshold
            val = val_read
        else
            extra_bit = read_bits(br, 1)
            count = val_read + (extra_bit << lower_bits)
            if count >= (1 << lower_bits)
                count -= threshold
            end
            val = count
        end
        
        prob = val - 1
        push!(probabilities, prob)
        sym += 1
        
        if prob != -1
            remaining_probabilities -= prob
        else
            remaining_probabilities -= 1
        end
        
        if prob == 0
            repeat_flag = read_bits(br, 2)
            while true
                for _ in 1:repeat_flag
                    push!(probabilities, 0)
                    sym += 1
                end
                if repeat_flag == 3
                    repeat_flag = read_bits(br, 2)
                else
                    break
                end
            end
        end
    end
    
    if remaining_probabilities != 0
        error("FSE table probabilities do not sum to 1 << accuracy_log")
    end
    
    align_to_byte(br)
    
    return probabilities, accuracy_log
end

function build_fse_table(probabilities::Vector{Int}, accuracy_log::Int)
    table_size = 1 << accuracy_log
    table = fill((0, 0, 0), table_size)
    
    # 1. Attribute "less than 1" probabilities (-1)
    pos = table_size
    for (sym, prob) in enumerate(probabilities)
        if prob == -1
            pos -= 1
            table[pos + 1] = (sym - 1, 0, 0)
        end
    end
    high_threshold = pos
    
    # 2. Spread the rest
    step = (table_size >> 1) + (table_size >> 3) + 3
    mask = table_size - 1
    pos = 0
    for (sym, prob) in enumerate(probabilities)
        if prob > 0
            for i in 1:prob
                table[pos + 1] = (sym - 1, 0, 0)
                pos = (pos + step) & mask
                while pos >= high_threshold
                    pos = (pos + step) & mask
                end
            end
        end
    end
    
    # 3. Baseline assignments
    # Each symbol occurrence k (from 0 to prob-1) gets state V = prob + k
    # state symbols are in order they were placed
    symbol_counters = zeros(Int, length(probabilities))
    for i in 1:table_size
        sym_val, _, _ = table[i]
        if i > high_threshold # This is a "less than 1" probability symbol
            table[i] = (sym_val, accuracy_log, 0)
            continue
        end
        
        # Standard symbol
        sym_idx = sym_val + 1
        prob = probabilities[sym_idx]
        k = symbol_counters[sym_idx]
        symbol_counters[sym_idx] += 1
        
        V = prob + k
        num_bits = accuracy_log - floor(Int, log2(V))
        baseline = (V << num_bits) - table_size
        
        table[i] = (sym_val, num_bits, baseline)
    end
    
    return FSETable(accuracy_log, table)
end

const LL_DEFAULT_DIST = [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1,-1,-1,-1
]

const ML_DEFAULT_DIST = [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,-1,-1,
    -1,-1,-1,-1,-1
]

const OF_DEFAULT_DIST = [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,-1,-1,-1,-1,-1
]

const LL_DEFAULT_TABLE = build_fse_table(LL_DEFAULT_DIST, 6)
const ML_DEFAULT_TABLE = build_fse_table(ML_DEFAULT_DIST, 6)
const OF_DEFAULT_TABLE = build_fse_table(OF_DEFAULT_DIST, 5)

function get_default_ll_table() return LL_DEFAULT_TABLE end
function get_default_ml_table() return ML_DEFAULT_TABLE end
function get_default_of_table() return OF_DEFAULT_TABLE end

end # module
