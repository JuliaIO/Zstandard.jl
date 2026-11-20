using Zstandard
using Test
using Random
using TranscodingStreams
using CodecZstd

# Regression tests for bugs found in review.

@testset "target_block_size on the streaming paths" begin
    # ~7.8 bits/byte literals with a short match every ~750 bytes: most
    # 1340-byte parts fall back to raw blocks, each with its own header.
    function skew(rng, n)
        d = UInt8[rand(rng) < 0.12 ? rand(rng, 0x00:0x0f) : rand(rng, UInt8) for _ in 1:n]
        i = 5000
        while i + 16 < n
            copyto!(d, i, d, rand(rng, 1:i-100), rand(rng, 5:9)); i += rand(rng, 600:900)
        end
        d
    end
    for (seed, n) in ((2, 400_000), (1, 131_072)), level in (5, 16, 19)
        data = skew(MersenneTwister(seed), n)
        io = IOBuffer()
        s = Zstandard.ZstdCompressorStream(io; level, target_block_size=1340, close_io=false, checksum=true)
        write(s, data); close(s)
        c = take!(io)
        @test decompress(c) == data
        @test transcode(CodecZstd.ZstdDecompressor, c) == data
        t = transcode(ZstandardCompressor(; level, target_block_size=1340), data)
        @test decompress(t) == data
    end
end

@testset "Multithreaded streaming" begin
    # history beyond the indexed overlap: as one-shot, byte for byte
    n = 11_889_238
    data = repeat(rand(MersenneTwister(5), UInt8, 100_000), cld(n, 100_000))[1:n]
    io = IOBuffer()
    s = Zstandard.ZstdCompressorStream(io; close_io=false, level=1, window_log=17, nthreads=2, pledged_size=n)
    write(s, data); close(s)
    a = take!(io)
    b = compress(data; level=1, window_log=17, nthreads=2)
    @test a == b
    @test decompress(a) == data

    # a failed job is not dropped: the stream stays failed
    io = IOBuffer()
    s = Zstandard.ZstdCompressorStream(io; close_io=false, nthreads=2)
    write(s, rand(UInt8, 3_000_000))
    t = Threads.@spawn error("boom")                         # stand-in for a failing worker
    try wait(t) catch end                                    # done, so the next write collects it
    pushfirst!(s.sc.jobs, t)
    @test_throws TaskFailedException write(s, rand(UInt8, 9_000_000))
    @test_throws ArgumentError write(s, rand(UInt8, 100))
    @test_throws ArgumentError flush(s)
    @test_throws ArgumentError close(s)
    @test !isopen(s)
end

@testset "close after a pledge mismatch" begin
    io = IOBuffer()
    s = Zstandard.ZstdCompressorStream(io; pledged_size=2000)
    write(s, rand(UInt8, 1000))
    @test_throws ArgumentError close(s)
    @test !isopen(s)
    @test !isopen(io)
    close(s)                                   # already closed: no error
end

@testset "Reused decompressor codec" begin
    codec = ZstandardDecompressor()
    TranscodingStreams.initialize(codec)
    c1 = compress(fill(0x61, 100_000)); c2 = compress(fill(0x62, 10))
    s = TranscodingStream(codec, IOBuffer(c1)); read(s, 10)     # abandoned mid-output
    @test transcode(codec, c2) == fill(0x62, 10)
    @test transcode(codec, c1) == fill(0x61, 100_000)
    TranscodingStreams.finalize(codec)
end

@testset "Prepared dictionary levels" begin
    dict = ZstdDictionary(Vector{UInt8}(repeat("dictionary content for prepared levels ", 200)))
    x = Vector{UInt8}("some dictionary content for prepared levels to compress")
    @test prepare_dictionary(dict; level=99).level == Zstandard.Encoder.MAX_LEVEL
    pd = prepare_dictionary(dict; level=0)
    @test pd.level == 3
    @test decompress(compress(x; dict=pd, level=3), dict) == x
    @test decompress(compress(x; dict=pd, level=0), dict) == x
end

@testset "Memory estimate for an empty input" begin
    @test estimate_compression_memory(src_size=0, nthreads=4) == estimate_compression_memory(src_size=0)
end

@testset "Seekable archive keywords" begin
    text = Vector{UInt8}(repeat("seekable archive keyword test ", 500))
    @test_throws ArgumentError compress_seekable(text; frame_size=1000, prefix=text[1:100])
    @test_throws ArgumentError compress_seekable(text; frame_size=1000, magicless=true)
    b = compress_seekable(text; frame_size=1000, magicless=false)
    @test decompress_range(b, 1:10) == text[1:10]
end

@testset "Codec error hint" begin
    # with the extension loaded, a wrong call gets no misleading hint
    e = try ZstandardCompressor(3) catch e; e end
    @test e isa MethodError
    @test !occursin("requires TranscodingStreams", sprint(showerror, e))
end
