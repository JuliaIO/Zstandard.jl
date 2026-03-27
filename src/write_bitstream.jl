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
    for i in 0:n-1
        bit = (val >> i) & 0x01
        bw.current_byte |= (UInt8(bit) << bw.bits_in_container)
        bw.bits_in_container += 1
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
    if n == 0; return; end
    
    # We add bits to the LSB side of our container.
    # We want bits of 'val' to be added such that MSB is "closest to the end".
    # Since we fill bytes and push them to buffer, "closest to the end" means
    # highest bit index in the last byte.
    
    # Let's add bits from LSB to MSB.
    # When we push a byte, the bits we added EARLIER are at LOWER indices.
    # The bits we add LATER are at HIGHER indices.
    # This matches the decoder: it reads from sentinel (highest index) towards LSB.
    # So the bit written LAST should be the one read FIRST.
    # The bit read FIRST is the MSB of the value.
    # So the MSB should be written LAST.
    
    for i in 0:n-1
        bit = (val >> i) & 0x01
        bw.bit_container |= (UInt64(bit) << bw.container_bits)
        bw.container_bits += 1
        
        if bw.container_bits == 8
            push!(bw.buffer, UInt8(bw.bit_container))
            bw.bit_container = 0
            bw.container_bits = 0
        end
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
