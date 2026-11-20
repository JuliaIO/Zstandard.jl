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
    @test (@allocated decompress(c)) < 1.6 * length(d)
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

@testset "close after a pledge mismatch" begin
    io = IOBuffer()
    s = Zstandard.ZstdCompressorStream(io; pledged_size=2000)
    write(s, lcg_bytes(1000, 4, 0x00:0xff))
    @test_throws ArgumentError close(s)
    @test !isopen(s)
    @test !isopen(io)
    close(s)                                   # already closed: no error
end

@testset "Size hint from a forged content size" begin
    @test TranscodingStreams.expectedsize(ZstandardDecompressor(),
        TranscodingStreams.Memory(pointer(forged_fcs(UInt64(1) << 46)), 16)) <= 1 << 26
    c = compress(lcg_bytes(1000, 5, 0x00:0xff))
    @test transcode(ZstandardDecompressor(), c) == decompress(c)
end

@testset "Precompile workload leaves the context pools empty" begin
    # in a fresh process, i.e. as loaded from the package image
    code = "using Zstandard; print(length(Zstandard._CCTX_POOL), \" \", length(Zstandard._STATE_POOL))"
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
    @test readchomp(cmd) == "0 0"
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

@testset "Prepared dictionaries in streams without a pledged size" begin
    dict = ZstdDictionary(repeat(lcg_bytes(1000, 10, UInt8.(0x41:0x50)), 100))
    pd = prepare_dictionary(dict; level=3)
    function streamed(d; kw...)
        io = IOBuffer()
        s = Zstandard.ZstdCompressorStream(io; close_io=false, dict=pd, kw...)
        for p in Iterators.partition(d, 50_000); write(s, p); end
        close(s); take!(io)
    end
    small = lcg_bytes(300, 11, UInt8.(0x41:0x50))
    for d in (small, UInt8[], lcg_bytes(70_000, 12, UInt8.(0x41:0x50)), repeat(small, 3000))
        c = streamed(d)
        @test decompress(c, dict) == d
    end
    # a small unpledged stream uses the prepared tables: same frame as pledged
    # apart from the header's content size
    @test decompress(streamed(small), dict) == small
    @test length(streamed(small)) <= length(streamed(small; pledged_size=300)) + 2
    # flushing before the end still works
    io = IOBuffer(); s = Zstandard.ZstdCompressorStream(io; close_io=false, dict=pd)
    write(s, small); flush(s); write(s, small); close(s)
    @test decompress(take!(io), dict) == vcat(small, small)
end

@testset "target_block_size on the streaming paths" begin
    # ~7.8 bits/byte literals with a short match every ~750 bytes: most
    # 1340-byte parts fall back to raw blocks, each with its own header
    function skew(seed, n)
        r = lcg_bytes(3n, seed, 0x00:0xff); k = 0
        nxt() = (k += 1; r[k])
        d = UInt8[nxt() < 0x1f ? nxt() & 0x0f : nxt() for _ in 1:n]
        i = 5000
        while i + 16 < n
            src = 1 + (Int(nxt()) << 8 | nxt()) % (i - 100)
            copyto!(d, i, d, src, 5 + nxt() % 5); i += 600 + Int(nxt())
        end
        d
    end
    for (seed, n) in ((2, 400_000), (1, 131_072)), level in (5, 16, 19)
        data = skew(seed, n)
        io = IOBuffer()
        s = Zstandard.ZstdCompressorStream(io; level, target_block_size=1340, close_io=false, checksum=true)
        write(s, data); close(s)
        c = take!(io)
        @test decompress(c) == data
        @test transcode(CodecZstd.ZstdDecompressor, c) == data
        @test decompress(transcode(ZstandardCompressor(; level, target_block_size=1340), data)) == data
    end
end

@testset "compress_sequences rejects oversized lengths" begin
    S = ZstdSequence
    @test_throws ArgumentError compress_sequences(UInt8[1, 2, 3, 4, 5, 5, 5, 5, 5],
        [S(0, 5, 0), S(1, 0, 3), S(0, typemax(Int), 0), S(1, 0, 3), S(0, typemax(Int), 0)])
    d = lcg_bytes(1000, 6, 0x00:0xff)
    compress_sequences(d, [S(0, 1000, 0)])                       # compile
    @test @elapsed(try compress_sequences(d, [S(1, 10^12, 3)]) catch end) < 1
    @test_throws ArgumentError compress_sequences(d, [S(1, 10^12, 3)])
    @test_throws ArgumentError compress_sequences(d, [S(1, 10, typemax(Int))])
end

@testset "Seekable archives" begin
    # forged frame sizes in the seek table
    tab = Zstandard._seek_table([(0, 4294967295, 0) for _ in 1:4], false)
    @test_throws ZstdError seek_table(tab)
    text = Vector{UInt8}(repeat("seekable archive keyword test ", 500))
    @test_throws ArgumentError compress_seekable(text; frame_size=1000, prefix=text[1:100])
    @test_throws ArgumentError compress_seekable(text; frame_size=1000, magicless=true)
    b = compress_seekable(text; frame_size=1000, magicless=false)
    @test decompress_range(b, 1:10) == text[1:10]
    @test decompress_range(b, 1:length(text)) == text
end

@testset "Dictionary training with f = 32" begin
    samples = [Vector{UInt8}("sample number $i: the quick brown fox jumps over the lazy dog $(i^2)\n"^8) for i in 1:100]
    @test_throws ArgumentError train_dictionary(samples; dict_size=4000, f=32)   # segfaulted
    @test length(train_dictionary(samples; dict_size=4000, f=16, k=200, d=8)) <= 4000
end

@testset "Small fixes" begin
    @test decompress(compress(UInt8[]; rsyncable=true)) == UInt8[]
    @test estimate_compression_memory(src_size=0, nthreads=4) == estimate_compression_memory(src_size=0)
    ctx = ZstdDecompressionContext()
    c = compress(lcg_bytes(300_000, 7, UInt8.(0:15)); checksum=true); c[end] ⊻= 0xff
    out = UInt8[]
    @test_throws ZstdError decompress!(ctx, out, c)
    @test isempty(out)
end

@testset "Multithreaded streaming" begin
    # history beyond the indexed overlap: as one-shot, byte for byte
    n = 11_889_238
    data = repeat(lcg_bytes(100_000, 5, 0x00:0xff), cld(n, 100_000))[1:n]
    io = IOBuffer()
    s = Zstandard.ZstdCompressorStream(io; close_io=false, level=1, window_log=17, nthreads=2, pledged_size=n)
    write(s, data); close(s)
    a = take!(io)
    @test a == compress(data; level=1, window_log=17, nthreads=2)
    @test decompress(a) == data

    # a failed job is not dropped: the stream stays failed
    io = IOBuffer()
    s = Zstandard.ZstdCompressorStream(io; close_io=false, nthreads=2)
    write(s, lcg_bytes(3_000_000, 6, 0x00:0xff))
    t = Threads.@spawn error("boom")                         # stand-in for a failing worker
    try wait(t) catch end                                    # done, so the next write collects it
    pushfirst!(s.sc.jobs, t)
    @test_throws TaskFailedException write(s, lcg_bytes(9_000_000, 7, 0x00:0xff))
    @test_throws ArgumentError write(s, UInt8[1, 2, 3])
    @test_throws ArgumentError flush(s)
    @test_throws ArgumentError close(s)
    @test !isopen(s)
end

@testset "Size bounds do not wrap" begin
    big1 = forged_fcs(UInt64(2)^62)
    @test_throws ZstdError decompress_bound(vcat(big1, big1))
    @test_throws ArgumentError compress_bound(typemax(Int))
    @test_throws ArgumentError compress_bound(-1)
    m = Zstandard.COMPRESS_BOUND_MAX_INPUT
    @test compress_bound(m) >= m
end

@testset "Forged block headers in a frame without a content size" begin
    f = UInt8[0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00]             # 1 KiB window
    for i in 1:25_000
        bh = (131072 << 3) | 2
        append!(f, UInt8[bh & 0xff, (bh >> 8) & 0xff, (bh >> 16) & 0xff, 0x41])
    end
    @test_throws ZstdError decompress(f)
    @test (@allocated try decompress(f) catch end) < 1 << 27
end
