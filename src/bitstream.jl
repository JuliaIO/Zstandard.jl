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
    # Load bits in bulk from current position.
    # Bits are stored in "stream order": first-read bit at index 0.
    # Within each byte, we read from bit_pos down to 0.

    # First: finish the partial byte at current position
    while br.container_bits <= 56 && br.pos > 0 && br.bit_pos < 7
        bit = (br.data[br.pos] >> br.bit_pos) & 0x01
        br.bit_container |= (UInt64(bit) << br.container_bits)
        br.container_bits += 1
        br.bit_pos -= 1
        if br.bit_pos < 0
            br.pos -= 1
            br.bit_pos = 7
        end
    end

    # Now bit_pos == 7 (aligned to byte start), load full bytes in bulk
    while br.container_bits <= 56 && br.pos > 0
        # Load byte with bits reversed (bit 7 first, bit 0 last)
        byte = br.data[br.pos]
        reversed = UInt64(0)
        reversed |= (UInt64((byte >> 7) & 1)) | (UInt64((byte >> 6) & 1) << 1) |
                    (UInt64((byte >> 5) & 1) << 2) | (UInt64((byte >> 4) & 1) << 3) |
                    (UInt64((byte >> 3) & 1) << 4) | (UInt64((byte >> 2) & 1) << 5) |
                    (UInt64((byte >> 1) & 1) << 6) | (UInt64(byte & 1) << 7)
        br.bit_container |= reversed << br.container_bits
        br.container_bits += 8
        br.pos -= 1
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
    # Container stores bits in stream order: bit at index 0 was read first (MSB of result).
    # Reverse the n lowest bits to get the value.
    raw = br.bit_container & ((UInt64(1) << n) - 1)
    val = UInt64(0)
    r = raw
    for i in 0:n-1
        val = (val << 1) | (r & 1)
        r >>= 1
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
