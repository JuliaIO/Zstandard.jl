# Bitstream readers for Zstandard

module Bitstream

export ForwardBitReader, BackwardBitReader, read_bits, peek_bits, consume_bits, align_to_byte, bits_left

mutable struct ForwardBitReader
    io::IO
    current_byte::UInt8
    bits_left::Int
end

function ForwardBitReader(io::IO)
    return ForwardBitReader(io, 0x00, 0)
end

function read_bits(br::ForwardBitReader, n::Int)
    val = UInt32(0)
    bits_read = 0
    while bits_read < n
        if br.bits_left == 0
            if eof(br.io)
                error("Unexpected end of stream")
            end
            br.current_byte = read(br.io, UInt8)
            br.bits_left = 8
        end
        bits_to_read = min(n - bits_read, br.bits_left)
        mask = (UInt32(1) << bits_to_read) - 1
        val |= (UInt32((br.current_byte & mask)) << bits_read)
        br.current_byte >>= bits_to_read
        br.bits_left -= bits_to_read
        bits_read += bits_to_read
    end
    return val
end

function align_to_byte(br::ForwardBitReader)
    br.bits_left = 0
end

mutable struct BackwardBitReader
    data::Vector{UInt8}
    pos::Int # Current byte index (1-indexed)
    bit_pos::Int # Bit position in current byte (0-7, 0 is LSB)
    total_bits::Int # Total bits in the stream
    
    # We maintain bits in a container such that we can easily peek N bits.
    # The next bit to be read is at the LSB of bit_container.
    bit_container::UInt64
    container_bits::Int
end

function BackwardBitReader(data::Vector{UInt8})
    if isempty(data)
        return BackwardBitReader(data, 0, 0, 0, 0, 0)
    end
    pos = length(data)
    last_byte = data[pos]
    if last_byte == 0
        error("Invalid bitstream: last byte is 0")
    end
    # Find sentinel bit
    bit_idx = 7
    while (last_byte & (1 << bit_idx)) == 0
        bit_idx -= 1
    end
    
    # The sentinel bit is NOT part of the data.
    # Bits are read from bit_idx-1 down to 0, then from data[pos-1] (7 down to 0), etc.
    br = BackwardBitReader(data, pos, bit_idx - 1, (pos - 1) * 8 + bit_idx, 0, 0)
    if br.bit_pos < 0
        br.pos -= 1
        br.bit_pos = 7
    end
    
    refill!(br)
    return br
end

function refill!(br::BackwardBitReader)
    # We want to fill bit_container from the LSB side? 
    # No, if we want to read N bits and have the first bit be MSB, 
    # then the first bit read should go to position N-1.
    
    # Actually, let's keep it simple: 
    # Read bits from the stream and push them into the LSB of the container.
    # When we want to read N bits, the first bit read is the MSB of the result.
    
    while br.container_bits <= 56 && br.pos > 0
        # Read the bit at br.pos, br.bit_pos
        bit = (br.data[br.pos] >> br.bit_pos) & 0x01
        
        # This bit was read "first" in time, so it should be the most significant in the final N-bit value.
        # This is hard to do if we don't know N yet.
        
        # Let's instead maintain the container such that the bits are in "stream order".
        # The first bit read from the stream is at index 0, the second at index 1...
        br.bit_container |= (UInt64(bit) << br.container_bits)
        br.container_bits += 1
        
        br.bit_pos -= 1
        if br.bit_pos < 0
            br.pos -= 1
            br.bit_pos = 7
        end
    end
end

function read_bits(br::BackwardBitReader, n::Int)
    if n == 0; return UInt64(0); end
    val = peek_bits(br, n)
    consume_bits(br, n)
    return val
end

function peek_bits(br::BackwardBitReader, n::Int)
    while br.container_bits < n && br.pos > 0
        refill!(br)
    end
    
    # We have bits at 0, 1, 2, ... n-1 in the container.
    # The bit at index 0 is the FIRST bit read from the stream.
    # According to Zstd, the FIRST bit read is the MSB of the value.
    
    val = UInt64(0)
    # n=3: bit0 -> MSB, bit1 -> middle, bit2 -> LSB
    for i in 0:n-1
        bit = (br.bit_container >> i) & 0x01
        # If i=0, bit is the first bit, goes to position n-1
        # If i=n-1, bit is the nth bit, goes to position 0
        val |= (bit << (n - 1 - i))
    end
    return val
end

function consume_bits(br::BackwardBitReader, n::Int)
    br.bit_container >>= n
    br.container_bits -= n
end

function bits_left(br::BackwardBitReader)
    return br.container_bits + (br.pos > 0 ? (br.pos - 1) * 8 + br.bit_pos + 1 : 0)
end

end # module
