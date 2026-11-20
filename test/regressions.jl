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

# a frame header with an 8-byte content size field, then an empty raw last block
forged_fcs(fcs::UInt64) = vcat(reinterpret(UInt8, [0xFD2FB528]), UInt8[0xC0, 0x00],
                               reinterpret(UInt8, [fcs]), UInt8[0x01, 0x00, 0x00])

@testset "decompressed_size does not wrap" begin
    big1 = forged_fcs(UInt64(2)^62)
    @test decompressed_size(big1) == 2^62
    @test_throws ZstdError decompressed_size(vcat(big1, big1))
    @test_throws ZstdError decompressed_size(vcat(big1, big1, big1, big1))
end

@testset "Frame inspection offsets" begin
    c = compress(lcg_bytes(1000, 3, 0x00:0xff))
    @test !is_zstd_frame(c; offset=0)
    @test !is_skippable_frame(c; offset=-3)
    @test_throws ArgumentError frame_compressed_size(c; offset=0)
    @test_throws ArgumentError frame_header(c; offset=0)
    @test_throws ArgumentError frame_content_size(c; offset=0)
end

@testset "Dictionary training" begin
    # flat literal statistics: samples covered by the dictionary content, or zeros
    words = ["alpha", "beta", "gamma", "{\"id\":", "true", "1234"]
    txt(n, seed) = Vector{UInt8}(join([words[(x % 6) + 1] for x in lcg_bytes(n, seed, 0x00:0xff)], " "))
    for samples in ([txt(100, 1)], [zeros(UInt8, 100_000)])
        dict_size = samples[1][1] == 0 ? 1000 : 112640
        dict = train_dictionary(samples; dict_size)
        @test length(dict) <= dict_size
        d = parse_dictionary(dict)
        @test decompress(compress(samples[1]; dict=d), d) == samples[1]
    end
    samples = [Vector{UInt8}("sample number $i: the quick brown fox jumps over the lazy dog $(i^2)\n"^8) for i in 1:100]
    for f in (0, 32, 65)
        @test_throws ArgumentError train_dictionary(samples; dict_size=4000, f)
    end
    @test_throws ArgumentError train_dictionary(samples; dict_size=4000, k=0)
    @test_throws ArgumentError train_dictionary(samples; dict_size=4000, k=7, d=8)
    content = reduce(vcat, samples)[1:3000]
    @test_throws ArgumentError finalize_dictionary(content, samples; dict_id=-1)
    @test_throws ArgumentError finalize_dictionary(content, samples; dict_id=Int64(typemax(UInt32)) + 1)
end

@testset "Long-distance matching samples every ~128 bytes" begin
    # N random 1000-byte records followed by the same records shuffled: the
    # repeats are 4 MiB back, inside the window but beyond the regular
    # match finder; zstd --long=27 compresses this to ~51% of plain level 3
    recs = [lcg_bytes(1000, i, 0x00:0xff) for i in 1:4096]
    perm = sortperm([hash(i) for i in 1:4096])
    d = vcat(reduce(vcat, recs), reduce(vcat, recs[perm]))
    plain = length(compress(d; level=3))
    c = compress(d; level=3, long=true)
    @test decompress(c) == d
    @test length(c) < 0.56 * plain          # was 0.74 with the sparse rate
end
