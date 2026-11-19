# Precompilation workload: run the common paths once while the package image
# is generated, so that their native code is cached and first calls are fast.
# Included at the end of module Zstandard.

function _precompile_workload()
    # Text-like data with repeats (sequences, Huffman and FSE tables) followed
    # by pseudo-random bytes (raw literals) — about 150 KiB, i.e. two blocks.
    text = Vector{UInt8}(repeat("The quick brown fox jumps over the lazy dog; 0123456789\n", 1800))
    x = UInt32(1)
    noise = Vector{UInt8}(undef, 50_000)
    for i in eachindex(noise)
        x = x * 0x0019660D + 0x3C6EF35F
        noise[i] = (x >> 24) % UInt8
    end
    data = vcat(text, noise)
    for level in (1, 3, 9, 19)
        decompress(compress(data; level))
    end
    decompress(compress(data; checksum=true))
    decompress(compress(String(copy(text))))
    decompress(compress(view(data, 1:10_000)))
    frame_content_size(compress(text))

    for pledged in (nothing, length(data))
        buf = IOBuffer()
        s = ZstdCompressorStream(buf; checksum=true, pledged_size=pledged, close_io=false)
        write(s, data)
        close(s)
        read(ZstdDecompressorStream(IOBuffer(take!(buf))))
    end

    dict = ZstdDictionary(text[1:8192])
    decompress(compress(text; dict), dict)
    decompress(compress(text[1:2000]; dict=prepare_dictionary(dict)), dict)
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1
    _precompile_workload()
end
