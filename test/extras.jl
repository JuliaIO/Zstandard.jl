using Zstandard
using Test
using CodecZstd

@testset "Frame inspection" begin
    a = compress(Vector{UInt8}(repeat("frame a ", 200)))
    b = transcode(CodecZstd.ZstdCompressor, rand(UInt8, 300_000))   # no content size
    c = compress(rand(UInt8, 70_000); checksum=true)
    s = skippable_frame("metadata"; variant=7)
    data = vcat(a, s, c, b)

    h = frame_header(a)
    @test h.content_size == 1600
    @test h.single_segment
    @test !h.checksum
    @test h.dict_id == 0
    @test frame_header(c).checksum
    @test frame_content_size(c) == 70_000
    @test frame_content_size(b) === nothing
    @test frame_content_size(s) == 0
    @test frame_header(b).window_size >= 300_000 || frame_header(b).window_size >= 1 << 17

    @test frame_compressed_size(data) == length(a)
    @test frame_compressed_size(data; offset=length(a) + 1) == length(s)
    @test frame_compressed_size(data; offset=length(a) + length(s) + 1) == length(c)
    @test frame_compressed_size(b) == length(b)
    @test decompressed_size(vcat(a, s, c)) == 1600 + 70_000
    @test decompressed_size(data) === nothing

    @test is_zstd_frame(a) && is_zstd_frame(s)
    @test !is_zstd_frame(UInt8[1, 2, 3, 4, 5])
    @test is_skippable_frame(s) && !is_skippable_frame(a)
    @test read_skippable_frame(data; offset=length(a) + 1) == (7, Vector{UInt8}("metadata"))
    @test decompress(data) == vcat(decompress(a), decompress(c), decompress(b))
    @test transcode(CodecZstd.ZstdDecompressor, vcat(s, a)) == decompress(a)



    @test_throws ZstdError frame_header(s)
    @test_throws ZstdError frame_compressed_size(a[1:end-2])
    @test_throws ArgumentError skippable_frame(UInt8[]; variant=16)
end

@testset "Multithreaded compression" begin
    words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "\n", "  ", "123"]
    x = UInt64(5)
    text = UInt8[]
    while length(text) < 5_000_000
        x = x * 6364136223846793005 + 1442695040888963407
        append!(text, codeunits(words[(x >> 33) % length(words) + 1]))
        (x >> 13) % 5 == 0 && append!(text, codeunits(string(x >> 50)))
    end
    data = vcat(text, rand(UInt8, 300_000), text[1:1_000_000])
    for level in (1, 3, 7, 12), nthreads in (2, 4), checksum in (false, true)
        c = compress(data; level, nthreads, checksum)
        @test decompress(c) == data
        @test transcode(CodecZstd.ZstdDecompressor, c) == data
        @test frame_content_size(c) == length(data)
        # one frame, close to single-threaded compression
        @test frame_compressed_size(c) == length(c)
        @test length(c) < 1.03 * length(compress(data; level))
    end
    # small inputs and dictionaries fall back to one thread
    @test compress(text[1:1000]; nthreads=4) == compress(text[1:1000])
    @test_throws ArgumentError compress(text; nthreads=0)
end

using Zstd_jll

@testset "Dictionary training" begin
    # JSON-like records sharing structure: a good fit for dictionaries
    x = UInt64(77)
    nxt(n) = (x = x * 6364136223846793005 + 1442695040888963407; Int((x >> 33) % n))
    names = ["alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi"]
    cities = ["Ashburn", "Berlin", "Cairo", "Denver", "Edinburgh", "Fukuoka"]
    record() = codeunits(string("{\"id\":", nxt(100000), ",\"name\":\"", names[nxt(8)+1],
        "\",\"city\":\"", cities[nxt(6)+1], "\",\"active\":", nxt(2) == 1, ",\"score\":", nxt(1000) / 10,
        ",\"tags\":[\"", names[nxt(8)+1], "\",\"", cities[nxt(6)+1], "\"]}\n"))
    samples = [reduce(vcat, [Vector{UInt8}(record()) for _ in 1:(3 + nxt(6))]) for _ in 1:1200]
    train, test = samples[1:900], samples[901:end]

    d = train_dictionary(train; dict_size=8192)
    @test length(d) <= 8192
    fd = parse_dictionary(d)
    @test fd.id >= 32768
    @test length(fd.content) > 1000

    plain = sum(s -> length(compress(s)), test)
    ours = sum(s -> length(compress(s; dict=fd)), test)
    @test ours < plain ÷ 2
    for s in test[1:50]
        @test decompress(compress(s; dict=fd), fd) == s
    end

    # interoperability with the reference implementation
    dpath = tempname(); write(dpath, d)
    for s in test[1:20]
        f = tempname(); write(f, s)
        c = read(`$(Zstd_jll.zstd()) -q -3 -c -D $dpath $f`)
        @test decompress(c, fd) == s
        write(f, compress(s; dict=fd))
        @test read(`$(Zstd_jll.zstd()) -q -d -c -D $dpath $f`) == s
    end
    # comparable to `zstd --train` on the same samples
    dir = mktempdir()
    for (i, s) in enumerate(train)
        write(joinpath(dir, "s$i"), s)
    end
    cli = tempname()
    run(pipeline(`$(Zstd_jll.zstd()) -q --train -r $dir -o $cli --maxdict=8192`, stderr=devnull))
    cd_ = parse_dictionary(read(cli))
    ref = sum(s -> length(compress(s; dict=cd_)), test)
    @test ours < 1.1 * ref

    # explicit k, finalize_dictionary on custom content
    @test parse_dictionary(train_dictionary(train; dict_size=4096, k=200)).id != 0
    content = reduce(vcat, train[1:20])
    fd2 = parse_dictionary(finalize_dictionary(content, train; dict_size=6000, dict_id=123456))
    @test fd2.id == 123456
    @test decompress(compress(test[1]; dict=fd2), fd2) == test[1]
    @test_throws ArgumentError train_dictionary(Vector{UInt8}[])
    @test_throws ArgumentError train_dictionary(train; d=7)
end

@testset "Long-distance matching" begin
    words = ["alpha", "beta", "gamma", "delta", "\n", " ", "=", "123"]
    x = UInt64(11)
    a = UInt8[]
    while length(a) < 1_000_000
        x = x * 6364136223846793005 + 1442695040888963407
        append!(a, codeunits(words[(x >> 33) % length(words) + 1]))
    end
    filler = UInt8[UInt8((i * 2654435761 >> 13) & 0xff) for i in 1:3_000_000]
    data = vcat(a, filler, a)
    for level in (1, 3, 9, 17, 19)
        c0 = compress(data; level)
        c1 = compress(data; level, long=true)
        @test decompress(c1) == data
        @test transcode(CodecZstd.ZstdDecompressor, c1) == data
        @test read(Zstandard.ZstdDecompressorStream(IOBuffer(c1))) == data
        window = 1 << Zstandard.Encoder.compression_parameters(level, length(data)).window_log
        if window < length(a) + length(filler)
            # the second copy of `a` lies beyond the regular window: only LDM finds it
            @test length(c1) < length(c0) - length(compress(a; level)) ÷ 2
        else
            @test length(c1) <= length(c0) + 64
        end
    end
    # small inputs: long mode is harmless
    @test decompress(compress(a[1:1000]; long=true)) == a[1:1000]
end

@testset "Parallel frame decoding" begin
    words = ["red", "green", "blue", "\n", " ", "#", "0xff"]
    x = UInt64(3)
    text = UInt8[]
    while length(text) < 1_500_000
        x = x * 6364136223846793005 + 1442695040888963407
        append!(text, codeunits(words[(x >> 33) % length(words) + 1]))
    end
    pieces = [text[i:min(end, i + 99_999)] for i in 1:100_000:length(text)]
    frames = Vector{UInt8}[]
    for (k, p) in enumerate(pieces)
        push!(frames, k % 3 == 0 ? transcode(CodecZstd.ZstdCompressor, p) :     # no content size
                      compress(p; checksum=isodd(k)))
        k == 5 && push!(frames, skippable_frame("between frames"))
    end
    mf = reduce(vcat, frames)
    @test decompress(mf; nthreads=1) == text
    for nt in (2, 4, 8)
        @test decompress(mf; nthreads=nt) == text
    end
    @test decompress(view(mf, 1:length(mf)); nthreads=4) == text

    # with a dictionary
    d = ZstdDictionary(text[1:50_000])
    mfd = reduce(vcat, [compress(p; dict=d) for p in pieces])
    @test decompress(mfd, d; nthreads=4) == text

    # errors surface as ZstdError, not TaskFailedException
    bad = copy(mf)
    mid = sum(length, frames[1:7]) + 200
    bad[mid] ⊻= 0xff
    bad[mid + 1] ⊻= 0x5a
    @test_throws ZstdError decompress(bad; nthreads=4)
    # cut inside the second-to-last frame
    @test_throws ZstdError decompress(mf[1:end-length(frames[end])-5]; nthreads=4)
    # dropping whole trailing frames leaves valid input
    @test decompress(mf[1:end-length(frames[end])]; nthreads=4) == text[1:end-length(pieces[end])]
    @test_throws ArgumentError decompress(mf; nthreads=0)
end
