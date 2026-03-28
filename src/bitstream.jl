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

mutable struct BackwardBitReader{V<:AbstractVector{UInt8}}
    data::V
    pos::Int # Current byte index (1-indexed)
    bit_pos::Int # Bit position in current byte (0-7, 0 is LSB)
    total_bits::Int # Total bits in the stream

    # We maintain bits in a container such that we can easily peek N bits.
    # The next bit to be read is at the LSB of bit_container.
    bit_container::UInt64
    container_bits::Int
end

BackwardBitReader(data::V, pos, bit_pos, total_bits, bit_container, container_bits) where {V<:AbstractVector{UInt8}} =
    BackwardBitReader{V}(data, pos, bit_pos, total_bits, bit_container, container_bits)

function BackwardBitReader(data::AbstractVector{UInt8})
    Base.require_one_based_indexing(data)
    if isempty(data)
        return BackwardBitReader(data, 0, 0, 0, 0, 0)
    end
    pos = lastindex(data)
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
    br = BackwardBitReader(data, pos, bit_idx - 1, (pos - firstindex(data)) * 8 + bit_idx, 0, 0)
    if br.bit_pos < 0
        br.pos -= 1
        br.bit_pos = 7
    end
    
    refill!(br)
    return br
end

function refill!(br::BackwardBitReader)
    # Container convention: next-to-read bits are at the TOP (MSB side).
    # bit_container has container_bits valid bits in the high positions.
    # Bits are loaded in natural zstd backward order: MSB of each byte first.

    # First: finish the partial byte at current position
    while br.container_bits <= 56 && br.pos >= firstindex(br.data) && br.bit_pos < 7
        bit = UInt64((br.data[br.pos] >> br.bit_pos) & 0x01)
        br.container_bits += 1
        br.bit_container |= bit << (64 - br.container_bits)
        br.bit_pos -= 1
        if br.bit_pos < 0
            br.pos -= 1
            br.bit_pos = 7
        end
    end

    # Now bit_pos == 7 (aligned to byte start), load full bytes in bulk
    while br.container_bits <= 56 && br.pos >= firstindex(br.data)
        # Load byte naturally: bit 7 is first-read, goes into highest available position
        byte = UInt64(br.data[br.pos])
        br.bit_container |= byte << (56 - br.container_bits)
        br.container_bits += 8
        br.pos -= 1
    end
end

@inline function read_bits(br::BackwardBitReader, n::Int)
    if n == 0; return UInt64(0); end
    val = peek_bits(br, n)
    consume_bits(br, n)
    return val
end

@inline function peek_bits(br::BackwardBitReader, n::Int)
    while br.container_bits < n && br.pos >= firstindex(br.data)
        refill!(br)
    end
    # Top n bits of container hold the value in natural order — just shift down
    return br.bit_container >>> (64 - n)
end

@inline function consume_bits(br::BackwardBitReader, n::Int)
    br.bit_container <<= n
    br.container_bits -= n
end

function bits_left(br::BackwardBitReader)
    base = firstindex(br.data)
    return br.container_bits + (br.pos >= base ? (br.pos - base) * 8 + br.bit_pos + 1 : 0)
end

end # module
