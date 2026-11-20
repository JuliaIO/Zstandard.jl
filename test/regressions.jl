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
        @test read(ZstdDecompressorStream(IOBuffer(c))) == x
    end
end

@testset "read(stream, nb) does not allocate nb bytes" begin
    small = compress(lcg_bytes(100, 2, 0x00:0xff))
    @test length(read(ZstdDecompressorStream(IOBuffer(small)), typemax(Int))) == 100
    @test read(ZstdDecompressorStream(IOBuffer(small)), 10) == decompress(small)[1:10]
    @test_throws ArgumentError read(ZstdDecompressorStream(IOBuffer(small)), -1)
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

@testset "Parallel decode chunking" begin
    d = reduce(vcat, [compress(lcg_bytes(20, i, 0x00:0xff)) for i in 1:20_000])
    @test Zstandard._frame_chunks(d, 16) === nothing                 # tiny frames: serial
    @test decompress(d; nthreads=4) == reduce(vcat, [lcg_bytes(20, i, 0x00:0xff) for i in 1:20_000])
    x = lcg_bytes(2_000_000, 3, UInt8.(0:40))
    big = compress(x; level=1)
    t = vcat(big, skippable_frame(zeros(UInt8, 16)))
    @test Zstandard._frame_chunks(t, 16) === nothing                 # tiny remainder merged
    two = vcat(big, big)
    @test Zstandard._frame_chunks(two, 2) == [1:length(big), length(big)+1:2length(big)]
    @test decompress(two; nthreads=2) == vcat(x, x)
    @test frame_header(view(big, 1:length(big))).content_size == length(x)   # non-Vector input
end

@testset "XXH64 update with a negative length" begin
    st = Zstandard.XXHash.XXH64State()
    @test_throws ArgumentError Zstandard.XXHash.update!(st, Ptr{UInt8}(0), -1)
    @test st.total == 0
end
