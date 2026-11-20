using Zstandard
using Test

# Regression tests for bugs found in review.

lcg_bytes(n, seed, alphabet) = (x = UInt64(seed);
    UInt8[alphabet[(x = x * 6364136223846793005 + 1442695040888963407; (x >> 33) % length(alphabet) + 1)] for _ in 1:n])

@testset "Streaming frames larger than the window" begin
    # the buffer is compacted mid-frame; the content size and checksum must
    # still cover exactly the decoded bytes
    x = lcg_bytes(3_000_000, 1, UInt8.(collect("abcdefgh \n")))
    for checksum in (false, true)
        c = compress(x; level=1, checksum)
        @test read(Zstandard.ZstdDecompressorStream(IOBuffer(c))) == x
    end
end

@testset "read(stream, nb) does not allocate nb bytes" begin
    small = compress(lcg_bytes(100, 2, 0x00:0xff))
    @test length(read(Zstandard.ZstdDecompressorStream(IOBuffer(small)), typemax(Int))) == 100
    @test read(Zstandard.ZstdDecompressorStream(IOBuffer(small)), 10) == decompress(small)[1:10]
    @test_throws ArgumentError read(Zstandard.ZstdDecompressorStream(IOBuffer(small)), -1)
end

@testset "Forged sizes do not drive large allocations" begin
    # a forged content size followed by junk
    v = UInt8[0x28, 0xb5, 0x2f, 0xfd, 0xC0, 0x00]
    append!(v, reinterpret(UInt8, [UInt64(1) << 40])); append!(v, zeros(UInt8, 100_000))
    try decompress(v) catch end
    @test (@allocated try decompress(v) catch end) < 1 << 28
    # valid frames larger than the pre-size guess still decode
    big = fill(0x07, 50_000_000)
    @test decompress(compress(big; level=1)) == big
end

using TranscodingStreams
using CodecZstd

@testset "Reused decompressor codec" begin
    codec = ZstandardDecompressor()
    TranscodingStreams.initialize(codec)
    c1 = compress(fill(0x61, 100_000)); c2 = compress(fill(0x62, 10))
    s = TranscodingStream(codec, IOBuffer(c1)); read(s, 10)     # abandoned mid-output
    @test transcode(codec, c2) == fill(0x62, 10)
    @test transcode(codec, c1) == fill(0x61, 100_000)
    TranscodingStreams.finalize(codec)
end

@testset "Codec error hint" begin
    # with the extension loaded, a wrong call gets no misleading hint
    e = try ZstandardCompressor(3) catch e; e end
    @test e isa MethodError
    @test !occursin("requires TranscodingStreams", sprint(showerror, e))
end

# an io whose first eof check throws once
mutable struct FlakyIO <: IO
    io::IOBuffer
    fail::Bool
end
Base.eof(f::FlakyIO) = (f.fail && (f.fail = false; throw(InterruptException())); eof(f.io))
Base.readbytes!(f::FlakyIO, b::AbstractVector{UInt8}, n::Integer) = readbytes!(f.io, b, n)
Base.read(f::FlakyIO, ::Type{UInt8}) = read(f.io, UInt8)

@testset "Streaming decoder errors are sticky" begin
    data = lcg_bytes(1000, 8, 0x00:0x0f)
    bad = compress(data; checksum=true); bad[end] ⊻= 0x01
    s = Zstandard.ZstdDecompressorStream(IOBuffer(bad))
    e1 = try read(s) catch e; e end
    e2 = try read(s) catch e; e end
    @test e1 isa ZstdError
    @test e2 === e1                    # the original error, not an unrelated one
    # other exceptions (here from the wrapped io) are not sticky
    s = Zstandard.ZstdDecompressorStream(FlakyIO(IOBuffer(compress(data)), true))
    @test_throws InterruptException read(s)
    @test read(s) == data
end

@testset "Highly compressible frames with a recorded size" begin
    # above 64:1 the block-header guess is too small; growth extrapolates from
    # the ratio decoded so far instead of doubling
    pat = lcg_bytes(1000, 9, 0x00:0xff)
    d = repeat(pat, 50_000)
    c = compress(d; level=3)
    @test decompress(c) == d
    # (minimum of a few runs: a stray allocation elsewhere must not fail it)
    @test minimum(@allocated(decompress(c)) for _ in 1:3) < 1.6 * length(d)
end

@testset "Optimal parser at the block end (levels 16-22)" begin
    # a tree candidate reaching the block end without beating the best match
    # was ordered by the byte past the end: over-long matches, wrong output
    function mk(n, seed)
        x = lcg_bytes(300, seed, 0x00:0xff)
        d = repeat(x, n ÷ 300 + 1)[1:n]
        r = UInt64(seed)
        for k in 1:(n ÷ 97)
            r = r * 6364136223846793005 + 1442695040888963407
            d[(r >> 33) % n + 1] = (r >> 13) % UInt8
        end
        d
    end
    for (n, seed, level) in ((262144, 3, 19), (400000, 6, 18), (400000, 2, 19), (262144, 5, 16), (262144, 7, 22))
        d = mk(n, seed)
        c = compress(d; level)
        @test decompress(c) == d
        @test transcode(CodecZstd.ZstdDecompressor, c) == d
    end
end
