module WriteBitstream

export ForwardBitWriter, BackwardBitWriter, write_bits, flush_bits, take_bits

mutable struct ForwardBitWriter
    io::IO
    bit_container::UInt64
    container_bits::Int
end

function ForwardBitWriter(io::IO)
    return ForwardBitWriter(io, UInt64(0), 0)
end

@inline function write_bits(bw::ForwardBitWriter, val::UInt32, n::Int)
    n == 0 && return
    bw.bit_container |= UInt64(val & ((UInt32(1) << n) - 1)) << bw.container_bits
    bw.container_bits += n
    while bw.container_bits >= 8
        write(bw.io, UInt8(bw.bit_container & 0xFF))
        bw.bit_container >>= 8
        bw.container_bits -= 8
    end
end

function flush_bits(bw::ForwardBitWriter)
    if bw.container_bits > 0
        write(bw.io, UInt8(bw.bit_container & 0xFF))
        bw.bit_container = UInt64(0)
        bw.container_bits = 0
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

function BackwardBitWriter(; sizehint::Int=0)
    buf = UInt8[]
    sizehint > 0 && sizehint!(buf, sizehint)
    return BackwardBitWriter(buf, 0, 0)
end

@inline function write_bits(bw::BackwardBitWriter, val::UInt64, n::Int)
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
