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

# Backward bit writing is more complex. 
# Zstd Huffman and Sequences use a backward bitstream.
# The simplest way to implement it is to write into a buffer and then reverse?
# No, Zstd says "the last byte contains a sentinel bit".
# Let's use a buffer and fill it from the end.

mutable struct BackwardBitWriter
    buffer::Vector{UInt8}
    bit_container::UInt64
    container_bits::Int
end

function BackwardBitWriter()
    # We'll grow the buffer as needed, but write backwards? 
    # Actually, let's just collect all bits and bytes and then reverse at the end.
    # OR, use a fixed size buffer and fill from the end.
    return BackwardBitWriter(UInt8[], 0, 0)
end

function write_bits(bw::BackwardBitWriter, val::UInt64, n::Int)
    # Bits are added such that the FIRST bit added is the MSB of the code in the final stream?
    # No, for Zstd: "The bitstream is read from the end... the first bit read is the MSB".
    # This means the LAST bit written (in forward time) is the FIRST bit read (in backward time).
    # So the bits of a code should be added to the container.
    
    # Let's push bits into the container.
    # When we have >= 8 bits, we push a byte to the buffer.
    # n=3, val=0b101. We want 1 to be the first bit read.
    # If we read backward, the first bit read is the one closest to the sentinel.
    
    for i in 0:n-1
        # Push bits of val from LSB to MSB? 
        # If val=0b101 (n=3), bits are 1, 0, 1.
        # If we push them in this order, and read them back, we get 1, 0, 1.
        bit = (val >> i) & 0x01
        bw.bit_container = (bw.bit_container << 1) | bit
        bw.container_bits += 1
        if bw.container_bits == 8
            push!(bw.buffer, UInt8(bw.bit_container))
            bw.bit_container = 0
            bw.container_bits = 0
        end
    end
end

function take_bits(bw::BackwardBitWriter)
    # Finalize
    # Add sentinel bit
    bw.bit_container = (bw.bit_container << 1) | 1
    bw.container_bits += 1
    # Pad to byte
    while bw.container_bits < 8
        bw.bit_container <<= 1
        bw.container_bits += 1
    end
    push!(bw.buffer, UInt8(bw.bit_container))
    
    # The buffer now contains bytes in the order they were filled.
    # But since it's a backward bitstream, the first byte written 
    # is actually the last byte in the stream?
    # Let's check: bits are read from the end. 
    # The last byte has the sentinel. 
    # So our sentinel byte should be the LAST byte.
    return bw.buffer
end

end # module
