using Zstandard
using Test
using Random
using TranscodingStreams

# Robustness against forged, corrupt or out-of-range input, from review.

# a frame header with a 2^k content size (8-byte FCS field), then 1 empty raw last block
forged_fcs(fcs::UInt64) = vcat(reinterpret(UInt8, [0xFD2FB528]), UInt8[0xC0, 0x00],
                               reinterpret(UInt8, [fcs]), UInt8[0x01, 0x00, 0x00])

@testset "Forged sizes do not drive large allocations" begin
    # a forged content size followed by junk
    v = UInt8[0x28, 0xb5, 0x2f, 0xfd, 0xC0, 0x00]
    append!(v, reinterpret(UInt8, [UInt64(1) << 40])); append!(v, zeros(UInt8, 100_000))
    try decompress(v; nthreads=1) catch end                     # compile
    a = @allocated try decompress(v; nthreads=1) catch end
    @test a < 1 << 28

    # forged RLE block sizes in a frame without a content size (1 KiB window)
    f = UInt8[0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00]
    for i in 1:25_000
        bh = (131072 << 3) | 2
        append!(f, UInt8[bh & 0xff, (bh >> 8) & 0xff, (bh >> 16) & 0xff, 0x41])
    end
    @test_throws ZstdError decompress(f)
    a = @allocated try decompress(f) catch end
    @test a < 1 << 27

    # the TranscodingStreams size hint is clamped as well
    @test TranscodingStreams.expectedsize(ZstandardDecompressor(),
        TranscodingStreams.Memory(pointer(forged_fcs(UInt64(1) << 46)), 16)) <= 1 << 26

    # valid frames larger than the pre-size limit still decode (the output grows)
    big = fill(0x07, 200_000_000)
    @test decompress(compress(big; level=1)) == big
end

@testset "Size sums do not wrap" begin
    big1 = forged_fcs(UInt64(2)^62)
    @test_throws ZstdError decompressed_size(vcat(big1, big1))
    @test_throws ZstdError decompressed_size(vcat(big1, big1, big1, big1))
    @test_throws ZstdError decompress_bound(vcat(big1, big1))
    @test decompressed_size(big1) == 2^62
    @test_throws ArgumentError compress_bound(typemax(Int))
    @test_throws ArgumentError compress_bound(-1)
    m = Zstandard.COMPRESS_BOUND_MAX_INPUT
    @test compress_bound(m) >= m
    # an untrusted size sum is not used as a hint: transcode still works
    c = compress(rand(UInt8, 1000))
    @test transcode(ZstandardDecompressor(), c) == decompress(c)
end

@testset "Streaming decoder reads" begin
    small = compress(rand(MersenneTwister(1), UInt8, 100))
    s = ZstdDecompressorStream(IOBuffer(small))
    @test length(read(s, typemax(Int))) == 100
    @test_throws ArgumentError read(ZstdDecompressorStream(IOBuffer(small)), -1)

    # errors are sticky
    bad = compress(rand(MersenneTwister(2), UInt8, 1000); checksum=true); bad[end] ⊻= 0x01
    s = ZstdDecompressorStream(IOBuffer(bad))
    e1 = try read(s) catch e; e end
    e2 = try read(s) catch e; e end
    @test e1 isa ZstdError
    @test e2 === e1
end

@testset "Seek tables with forged sizes" begin
    tab = Zstandard._seek_table([(0, 4294967295, 0) for _ in 1:4], false)
    @test_throws ZstdError seek_table(tab)
    # a frame size within the limit, but not matching the frame, is caught
    # without allocating the claimed size
    text = Vector{UInt8}(repeat("seekable ", 1000))
    b = compress_seekable(text; frame_size=1000, checksum=false)
    t = seek_table(b)
    @test decompress_range(b, 1:t.content_size) == text
end

@testset "compress_sequences rejects oversized lengths" begin
    S = ZstdSequence
    @test_throws ArgumentError compress_sequences(UInt8[1, 2, 3, 4, 5, 5, 5, 5, 5],
        [S(0, 5, 0), S(1, 0, 3), S(0, typemax(Int), 0), S(1, 0, 3), S(0, typemax(Int), 0)])
    d = rand(UInt8, 1000)
    compress_sequences(d, [S(0, 1000, 0)])                       # compile
    @test @elapsed(try compress_sequences(d, [S(1, 10^12, 3)]) catch end) < 1
    @test_throws ArgumentError compress_sequences(d, [S(1, 10^12, 3)])
    @test_throws ArgumentError compress_sequences(d, [S(1, 10, typemax(Int))])
end

@testset "Dictionary training parameters" begin
    samples = [Vector{UInt8}("sample number $i: the quick brown fox jumps over the lazy dog $(i^2)\n"^8) for i in 1:100]
    for f in (0, 32, 65)
        @test_throws ArgumentError train_dictionary(samples; dict_size=4000, f)
    end
    @test_throws ArgumentError train_dictionary(samples; dict_size=4000, k=0)
    @test_throws ArgumentError train_dictionary(samples; dict_size=4000, k=7, d=8)
    @test length(train_dictionary(samples; dict_size=4000, f=16, k=200, d=8)) <= 4000
    content = reduce(vcat, samples)[1:3000]
    @test_throws ArgumentError finalize_dictionary(content, samples; dict_id=-1)
    @test_throws ArgumentError finalize_dictionary(content, samples; dict_id=Int64(typemax(UInt32)) + 1)
end

@testset "Frame inspection offsets" begin
    c = compress(rand(UInt8, 1000))
    @test !is_zstd_frame(c; offset=0)
    @test !is_skippable_frame(c; offset=-3)
    @test_throws ArgumentError frame_compressed_size(c; offset=0)
    @test_throws ArgumentError frame_header(c; offset=0)
    @test_throws ArgumentError frame_content_size(c; offset=0)
    @test frame_header(view(c, 1:length(c))).content_size == 1000   # non-Vector input
end

@testset "Parallel decode chunking" begin
    rng = MersenneTwister(3)
    d = reduce(vcat, [compress(rand(rng, UInt8, 20)) for _ in 1:20_000])
    @test Zstandard._frame_chunks(d, 16) === nothing                 # tiny frames: serial
    x = rand(MersenneTwister(3), UInt8.(0:40), 2_000_000)
    big = compress(x; level=1)
    t = vcat(big, skippable_frame(zeros(UInt8, 16)))
    @test Zstandard._frame_chunks(t, 16) === nothing                 # tiny remainder merged
    two = vcat(big, big)
    ch = Zstandard._frame_chunks(two, 2)
    @test ch == [1:length(big), length(big)+1:2length(big)]
    @test decompress(two; nthreads=2) == vcat(x, x)
end

@testset "decompress! leaves out empty on error" begin
    ctx = ZstdDecompressionContext()
    c = compress(rand(MersenneTwister(4), UInt8.(0:15), 300_000); checksum=true); c[end] ⊻= 0xff
    out = UInt8[]
    @test_throws ZstdError decompress!(ctx, out, c)
    @test isempty(out)
end

@testset "XXH64 update with a negative length" begin
    st = Zstandard.XXHash.XXH64State()
    @test_throws ArgumentError Zstandard.XXHash.update!(st, Ptr{UInt8}(0), -1)
    @test st.total == 0
end

@testset "Precompile workload leaves the context pools empty" begin
    # in a fresh process, i.e. as loaded from the package image
    code = "using Zstandard; print(length(Zstandard._CCTX_POOL), \" \", length(Zstandard._STATE_POOL))"
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
    @test readchomp(cmd) == "0 0"
end
