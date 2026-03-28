module WriteBitstream

export ForwardBitWriter, BackwardBitWriter, write_bits, flush_bits, take_bits

mutable struct ForwardBitWriter
    io::IO
    current_byte::UInt8
    bits_in_container::Int
end

function ForwardBitWriter(io::IO)
    return ForwardBitWriter(io, 0x00, 0)
end

function write_bits(bw::ForwardBitWriter, val::UInt32, n::Int)
    n == 0 && return
    remaining = UInt32(val & ((UInt32(1) << n) - 1))
    bits_left = n
    while bits_left > 0
        avail = 8 - bw.bits_in_container
        take = min(bits_left, avail)
        bw.current_byte |= UInt8((remaining & ((UInt32(1) << take) - 1)) << bw.bits_in_container)
        bw.bits_in_container += take
        remaining >>= take
        bits_left -= take
        if bw.bits_in_container == 8
            write(bw.io, bw.current_byte)
            bw.current_byte = 0x00
            bw.bits_in_container = 0
        end
    end
end

function flush_bits(bw::ForwardBitWriter)
    if bw.bits_in_container > 0
        write(bw.io, bw.current_byte)
        bw.current_byte = 0x00
        bw.bits_in_container = 0
    end
end

# Correct Zstd Backward Bitstream Writer
# Bits of a value are read from MSB to LSB.
# In the bitstream, they appear from the end towards the beginning.
# The first bit read (MSB) is the one closest to the end (sentinel).

mutable struct BackwardBitWriter
    buffer::Vector{UInt8}
    bit_container::UInt64
    container_bits::Int
end

function BackwardBitWriter()
    return BackwardBitWriter(UInt8[], 0, 0)
end

function write_bits(bw::BackwardBitWriter, val::UInt64, n::Int)
    n == 0 && return
    # Add n bits from val (LSB first) into the container
    bw.bit_container |= (val & ((UInt64(1) << n) - 1)) << bw.container_bits
    bw.container_bits += n
    # Flush complete bytes
    while bw.container_bits >= 8
        push!(bw.buffer, UInt8(bw.bit_container & 0xFF))
        bw.bit_container >>= 8
        bw.container_bits -= 8
    end
end

function take_bits(bw::BackwardBitWriter)
    # Add sentinel bit (1) at the next available bit position.
    bw.bit_container |= (UInt64(1) << bw.container_bits)
    bw.container_bits += 1
    
    # Pad remaining bits of the byte with 0 (already 0)
    push!(bw.buffer, UInt8(bw.bit_container))
    
    return bw.buffer
end

end # module
