using Zstandard
using Test
using CodecZstd
using TranscodingStreams
using Zstd_jll

# Text corpus with realistic structure (deterministic).
function make_text(n)
    words = ["function", "end", "return", "if", "else", "for", "while", "begin", "x", "y",
             "= ", "+ ", "(", ")", "\n", "    ", "const", "struct", "Int", "Vector{UInt8}"]
    x = UInt64(12345)
    out = UInt8[]
    while length(out) < n
        x = x * 6364136223846793005 + 1442695040888963407
        append!(out, codeunits(words[(x >> 33) % length(words) + 1]))
        (x >> 20) % 11 == 0 && append!(out, codeunits(string((x >> 40) % 997)))
        append!(out, codeunits(" "))
    end
    return out[1:n]
end

const ZCS = Zstandard.ZstdCompressorStream
frame_header_checksum(c) = (c[5] >> 2) & 1 == 1
const ZDS = Zstandard.ZstdDecompressorStream

@testset "ZstdCompressorStream" begin
    for n in (0, 1, 1000, 131072, 131073, 700_000), level in (1, 3, 9, 17, 19), checksum in (false, true)
        data = make_text(n)
        buf = IOBuffer()
        s = ZCS(buf; level, checksum, close_io=false)
        i = 1
        step = 1
        while i <= n
            k = min(n - i + 1, step)
            write(s, view(data, i:i+k-1))
            i += k
            step = step * 7 % 100_003 + 1
        end
        close(s)
        c = take!(buf)
        @test decompress(c) == data
        @test transcode(CodecZstd.ZstdDecompressor, c) == data
    end

    # flush makes everything written so far decodable
    data = make_text(300_000)
    buf = IOBuffer()
    s = ZCS(buf; close_io=false)
    write(s, view(data, 1:100_000))
    flush(s)
    partial = copy(buf.data[1:buf.size])
    d = ZDS(IOBuffer(partial))
    @test read(d, 100_000) == data[1:100_000]
    write(s, view(data, 100_001:300_000))
    close(s)
    @test decompress(take!(buf)) == data
    @test !isopen(s)

    # long stream: exceeds the window so the input buffer is rebased
    data = repeat(make_text(1_000_000), 5)
    buf = IOBuffer()
    s = ZCS(buf; level=1, close_io=false)
    for i in 1:250_000:length(data)
        write(s, view(data, i:min(i + 249_999, length(data))))
    end
    close(s)
    c = take!(buf)
    @test decompress(c) == data
    @test transcode(CodecZstd.ZstdDecompressor, c) == data
    ref = read(CodecZstd.ZstdCompressorStream(IOBuffer(data); level=1))
    @test length(c) < 1.1 * length(ref)

    # Streaming decoder on frames larger than the window that record their
    # content size and a checksum (buffer compaction mid-frame).
    c = compress(data; level=1, checksum=true)
    @test frame_header_checksum(c)
    d = ZDS(IOBuffer(c))
    got = UInt8[]
    buf2 = Vector{UInt8}(undef, 65_537)
    while !eof(d)
        n = readbytes!(d, buf2)
        append!(got, view(buf2, 1:n))
    end
    @test got == data
    @test length(d.d.out) < length(data)
    @test transcode(ZstandardDecompressor(), c) == data

    # close_io=true (default) closes the underlying stream
    path = tempname()
    open(path, "w") do f
        s = ZCS(f)
        write(s, "hello hello hello")
        close(s)
        @test !isopen(f)
    end
    @test String(decompress(read(path))) == "hello hello hello"
end

@testset "TranscodingStreams codecs" begin
    data = make_text(400_000)
    c = transcode(ZstandardCompressor(level=5), data)
    @test transcode(CodecZstd.ZstdDecompressor, c) == data
    @test transcode(ZstandardDecompressor(), c) == data
    c = transcode(ZstandardCompressor(checksum=true), data)
    @test transcode(CodecZstd.ZstdDecompressor, c) == data

    # libzstd output, concatenated and with a skippable frame in between
    f1 = transcode(CodecZstd.ZstdCompressor, data[1:100_000])
    f2 = transcode(CodecZstd.ZstdCompressor, data[100_001:end])
    skip = UInt8[0x50, 0x2a, 0x4d, 0x18, 0x03, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03]
    multi = vcat(f1, skip, f2)
    @test transcode(ZstandardDecompressor(), multi) == data
    @test read(TranscodingStream(ZstandardDecompressor(), IOBuffer(multi))) == data

    # empty input
    @test transcode(ZstandardDecompressor(), transcode(ZstandardCompressor(), UInt8[])) == UInt8[]

    # writing through a TranscodingStream
    buf = IOBuffer()
    st = TranscodingStream(ZstandardCompressor(level=3), buf; stop_on_end=false)
    write(st, data)
    write(st, TranscodingStreams.TOKEN_END)
    flush(st)
    @test decompress(take!(buf)) == data

    # corrupt and truncated input raise errors
    @test_throws Exception transcode(ZstandardDecompressor(), f1[1:end-10])
    bad = copy(f1); bad[1] = 0x00
    @test_throws Exception transcode(ZstandardDecompressor(), bad)
end

@testset "Dictionary compression" begin
    # Train a formatted dictionary with the reference CLI.
    dir = mktempdir()
    samples = [make_text(600 + 37i)[(13i % 200) + 1:end] for i in 1:400]
    for (i, smp) in enumerate(samples[1:300])
        write(joinpath(dir, "s$i.txt"), smp)
    end
    dpath = joinpath(mktempdir(), "test.dict")
    run(pipeline(`$(Zstd_jll.zstd()) -q --train -r $dir -o $dpath --maxdict=8192`, stderr=devnull))
    fd = parse_dictionary(read(dpath))
    @test fd.id != 0
    rd = ZstdDictionary(fd.content)

    total = Dict(:none => 0, :raw => 0, :formatted => 0)
    for smp in samples[301:end], level in (1, 3, 7, 19)
        c0 = compress(smp; level)
        cr = compress(smp; level, dict=rd)
        cf = compress(smp; level, dict=fd)
        @test decompress(cr, rd) == smp
        @test decompress(cf, fd) == smp
        @test read(ZDS(IOBuffer(cf), fd)) == smp
        total[:none] += length(c0); total[:raw] += length(cr); total[:formatted] += length(cf)
    end
    @test total[:formatted] < total[:none] ÷ 2
    @test total[:raw] < total[:none]

    # the reference decoder accepts our dictionary frames
    for smp in samples[301:310]
        f = tempname()
        write(f, compress(smp; dict=fd, checksum=true))
        @test read(`$(Zstd_jll.zstd()) -q -d -c -D $dpath $f`) == smp
    end
    rawpath = tempname(); write(rawpath, rd.content)
    f = tempname(); write(f, compress(samples[350]; dict=rd))
    @test read(`$(Zstd_jll.zstd()) -q -d -c -D $rawpath $f`) == samples[350]

    # ...and we decode the reference encoder's dictionary frames
    f = tempname(); write(f, samples[360])
    c = read(`$(Zstd_jll.zstd()) -q -19 -c -D $dpath $f`)
    @test decompress(c, fd) == samples[360]

    # wrong or missing dictionary is rejected
    @test_throws ZstdError decompress(compress(samples[301]; dict=fd))

    # streaming compressor and codec with a dictionary
    buf = IOBuffer()
    s = ZCS(buf; dict=fd, close_io=false)
    write(s, samples[320]); close(s)
    @test decompress(take!(buf), fd) == samples[320]
    c = transcode(ZstandardCompressor(dict=fd), samples[321])
    @test transcode(ZstandardDecompressor(dict=fd), c) == samples[321]
end

@testset "Optimal parser levels" begin
    data = make_text(600_000)
    sizes = Dict{Int,Int}()
    for level in (15, 16, 17, 18, 19, 22)
        c = compress(data; level)
        @test decompress(c) == data
        @test transcode(CodecZstd.ZstdDecompressor, c) == data
        sizes[level] = length(c)
    end
    # the optimal parser beats lazy2 and is close to libzstd at the same level
    @test sizes[19] < sizes[15]
    @test sizes[19] < 1.05 * length(transcode(CodecZstd.ZstdCompressor(level=19), data))
    # highly repetitive input spanning several blocks (period 256): the tree's
    # skip-ahead over long repetitions must not hide positions from the search
    periodic = UInt8[UInt8((i * 2654435761 >> 13) & 0xff) for i in 1:1_000_000]
    for level in (16, 19)
        c = compress(periodic; level)
        @test decompress(c) == periodic
        @test length(c) < 2 * length(compress(periodic; level=9)) + 100
    end
    # long stream at level 19: the binary tree is rebased with the input buffer
    big = repeat(make_text(300_000), 40)
    buf = IOBuffer()
    s = ZCS(buf; level=19, close_io=false)
    for i in 1:1_000_000:length(big)
        write(s, view(big, i:min(i + 999_999, length(big))))
    end
    close(s)
    @test decompress(take!(buf)) == big
end

@testset "Pledged source size" begin
    function stream_compress(data; chunk=7919, kwargs...)
        buf = IOBuffer()
        s = ZCS(buf; close_io=false, kwargs...)
        for i in 1:chunk:length(data)
            write(s, view(data, i:min(i + chunk - 1, length(data))))
        end
        close(s)
        return take!(buf), s
    end
    for n in (0, 1, 255, 256, 1000, 65_791, 65_792, 131_072, 131_073, 700_000), level in (1, 3, 19),
        checksum in (false, true)
        data = make_text(n)
        c, s = stream_compress(data; level, checksum, pledged_size=n)
        @test frame_content_size(c) == n
        @test decompress(c) == data
        @test transcode(CodecZstd.ZstdDecompressor, c) == data
        # the same parameters and block boundaries as one-shot compression
        @test c == compress(data; level, checksum)
        h = frame_header(c)
        @test h.single_segment == (n <= h.window_size)
    end
    # without a pledge the content size is not recorded
    c, _ = stream_compress(make_text(1000))
    @test frame_content_size(c) === nothing

    # pledges are enforced
    buf = IOBuffer()
    s = ZCS(buf; pledged_size=10, close_io=false)
    write(s, b"0123456789")
    @test_throws ArgumentError write(s, b"x")
    close(s)
    @test decompress(take!(buf)) == b"0123456789"
    s = ZCS(IOBuffer(); pledged_size=10, close_io=false)
    write(s, b"01234")
    @test_throws ArgumentError close(s)
    sc = Zstandard.Encoder.StreamCompressor()
    Zstandard.Encoder.stream_write!(sc, b"abc")
    @test_throws ArgumentError Zstandard.Encoder.stream_pledge!(sc, 3)

    # a pledged size smaller than the level's window shrinks the stream's buffers
    small = Zstandard.Encoder.StreamCompressor(; level=19, pledged_size=1000)
    Zstandard.Encoder.stream_write!(small, make_text(1000))
    big = Zstandard.Encoder.StreamCompressor(; level=19)
    Zstandard.Encoder.stream_write!(big, make_text(1000))
    @test small.cap <= 1 << 19 && big.cap >= 1 << 23    # ~385 KiB vs ~25 MiB at level 19
    @test length(small.cc.htab) < length(big.cc.htab)

    # with a dictionary
    d = ZstdDictionary(make_text(20_000))
    data = make_text(50_000)
    c, _ = stream_compress(data; dict=d, pledged_size=length(data))
    @test frame_content_size(c) == length(data)
    @test frame_dict_id(c) == 0
    @test decompress(c, d) == data
    @test c == compress(data; dict=d)

    # TranscodingStreams: `transcode` pledges the input size; expectedsize uses it
    data = make_text(300_000)
    c = transcode(ZstandardCompressor(level=3), data)
    @test frame_content_size(c) == length(data)
    @test c == compress(data)
    @test transcode(ZstandardDecompressor(), c) == data
    @test GC.@preserve c TranscodingStreams.expectedsize(ZstandardDecompressor(),
        TranscodingStreams.Memory(pointer(c), UInt(length(c)))) == length(data)
    # a streaming TranscodingStream does not pledge
    buf = IOBuffer()
    st = TranscodingStream(ZstandardCompressor(), buf; stop_on_end=false)
    write(st, data); write(st, TranscodingStreams.TOKEN_END); flush(st)
    c2 = take!(buf)
    @test frame_content_size(c2) === nothing
    @test decompress(c2) == data
end

@testset "Prepared dictionary" begin
    samples = [make_text(1200 + 37i)[(13i % 200) + 1:end] for i in 1:400]
    fd = parse_dictionary(train_dictionary(samples[1:300]; dict_size=16384))
    dpath = tempname(); write(dpath, Zstandard.Encoder.finalize_dictionary(fd.content, samples[1:300];
                                                                          dict_size=16384, dict_id=fd.id))
    fd = parse_dictionary(read(dpath))
    for level in (1, 3, 5, 9, 16, 19)
        pd = prepare_dictionary(fd; level)
        @test pd.level == level
        htab0 = copy(pd.htab); ctab0 = copy(pd.ctab)
        plain = 0; prepared = 0
        for s in samples[301:340]
            c = compress(s; dict=pd)
            @test decompress(c, fd) == s
            @test frame_dict_id(c) == fd.id
            plain += length(compress(s; level, dict=fd)); prepared += length(c)
        end
        # the prepared tree is built against the dictionary alone, so the
        # optimal parser loses a little (about 2% at level 19)
        @test prepared <= 1.03 * plain
        @test pd.htab == htab0 && pd.ctab == ctab0         # never modified
        @test compress(samples[350]; level, dict=pd) == compress(samples[350]; dict=pd)
        @test_throws ArgumentError compress(samples[350]; level=level + 1, dict=pd)
        # the reference decoder accepts the frames
        f = tempname(); write(f, compress(samples[360]; dict=pd, checksum=true))
        @test read(`$(Zstd_jll.zstd()) -q -d -c -D $dpath $f`) == samples[360]
        # inputs too large for the prepared window take the regular path
        big = make_text(600_000)
        @test compress(big; dict=pd) == compress(big; level, dict=fd)
    end
    pd = prepare_dictionary(fd; level=3)
    # streams: prepared tables with a small pledged size, regular path otherwise
    for pledged in (nothing, length(samples[370]))
        buf = IOBuffer()
        s = ZCS(buf; dict=pd, pledged_size=pledged, close_io=false)
        write(s, samples[370]); close(s)
        c = take!(buf)
        @test decompress(c, fd) == samples[370]
        pledged === nothing && @test c == (b2 = IOBuffer(); s2 = ZCS(b2; dict=fd, close_io=false);
                                          write(s2, samples[370]); close(s2); take!(b2))
    end
    @test_throws ArgumentError ZCS(IOBuffer(); dict=pd, level=5)
    # TranscodingStreams codec
    c = transcode(ZstandardCompressor(dict=pd), samples[371])
    @test transcode(ZstandardDecompressor(dict=fd), c) == samples[371]
    # shared between tasks
    results = fetch.([Threads.@spawn(compress(samples[i]; dict=pd)) for i in 301:400])
    @test all(decompress(results[k], fd) == samples[300 + k] for k in 1:100)
    @test occursin("PreparedDictionary", sprint(show, pd))
end

@testset "Decoder window size limit" begin
    data = make_text(300_000)
    f = tempname(); write(f, data)
    for wlog in (28, 30)
        # from a pipe the CLI cannot shrink the window to the input size
        c = read(pipeline(`cat $f`, `$(Zstd_jll.zstd()) -q -3 --long=$wlog -c`))
        @test frame_header(c).window_size == 1 << wlog
        @test_throws ZstdError read(ZDS(IOBuffer(c)))
        @test read(ZDS(IOBuffer(c); max_window_size=1 << wlog)) == data
        @test_throws Exception transcode(ZstandardDecompressor(), c)
        @test transcode(ZstandardDecompressor(max_window_size=1 << wlog), c) == data
        @test decompress(c) == data            # in memory: no window buffer, no limit needed
    end
    err = try read(ZDS(IOBuffer(read(pipeline(`cat $f`, `$(Zstd_jll.zstd()) -q --long=30 -c`))))) catch e; e end
    @test err isa ZstdError && occursin("max_window_size", sprint(showerror, err))
    # a lower limit rejects ordinary frames too
    c = transcode(CodecZstd.ZstdCompressor(level=19), data)
    @test frame_header(c).window_size > 1 << 16
    @test_throws ZstdError read(ZDS(IOBuffer(c); max_window_size=1 << 16))
    @test_throws ArgumentError ZDS(IOBuffer(c); max_window_size=100)
    # everything Zstandard.jl writes fits the default limit
    big = repeat(data, 20)
    for c in (compress(big; level=22), compress(big; long=true, level=19), compress(big; nthreads=2),
              (b = IOBuffer(); s = ZCS(b; level=22, close_io=false); write(s, data); close(s); take!(b)))
        @test frame_header(c).window_size <= Zstandard.Streaming.DEFAULT_MAX_WINDOW_SIZE
        @test length(read(ZDS(IOBuffer(c)))) > 0
    end
end

@testset "Advanced compression parameters" begin
    E = Zstandard.Encoder
    # explicit values replace the level's, then adapt to the input size
    p = E.compression_parameters(3, 10^8, E.parameter_overrides(window_log=24, hash_log=20, chain_log=19,
                                                               search_log=5, min_match=6, target_length=64,
                                                               strategy=:lazy2))
    @test (p.window_log, p.hash_log, p.chain_log, p.search_log, p.min_match, p.target_length, p.strategy) ==
          (24, 20, 19, 5, 6, 64, E.S_LAZY2)
    @test E.compression_parameters(3, 5000, E.parameter_overrides(window_log=24)).window_log == 13
    @test E.compression_parameters(19, 10^8, E.parameter_overrides(strategy=:btultra2)).strategy == E.S_BTULTRA2

    # window_log: a repeat 3 MB back is only found with a larger window
    a = make_text(1_000_000)
    filler = UInt8[UInt8((i * 2654435761 >> 13) % 251) for i in 1:2_000_000]
    data = vcat(a, filler, a)
    c_default = compress(data; level=3)
    c_wide = compress(data; level=3, window_log=23)
    @test frame_header(c_default).window_size == 1 << 21
    @test frame_header(c_wide).single_segment          # 4 MB fits the 8 MiB window
    @test frame_header(c_wide).window_size == length(data)
    @test length(c_wide) < length(c_default) - length(compress(a; level=3)) ÷ 2
    @test decompress(c_wide) == data
    @test transcode(CodecZstd.ZstdDecompressor, c_wide) == data

    # strategy changes the parser at a fixed level
    text = make_text(400_000)
    sizes = Dict(st => length(compress(text; level=5, strategy=st)) for st in (:fast, :dfast, :greedy, :lazy2, :btultra))
    @test sizes[:lazy2] < sizes[:greedy] < sizes[:fast]
    @test sizes[:btultra] < sizes[:fast]
    @test length(unique(values(sizes))) == 5

    # a grid of parameter combinations decodes with both decoders
    x = UInt64(5)
    nxt(r) = (x = x * 6364136223846793005 + 1442695040888963407; r[(x >> 33) % length(r) + 1])
    for trial in 1:40
        kw = (window_log=nxt(12:22), hash_log=nxt(8:20), chain_log=nxt(8:20), search_log=nxt(1:7),
              min_match=nxt(3:7), target_length=nxt([0, 8, 64, 999]),
              strategy=nxt([:fast, :dfast, :greedy, :lazy, :lazy2, :btlazy2, :btopt, :btultra, :btultra2]))
        d = text[1:nxt([1000, 50_000, 400_000])]
        c = compress(d; level=nxt(1:19), kw...)
        @test decompress(c) == d
        @test transcode(CodecZstd.ZstdDecompressor, c) == d
    end

    # streams and the codec take the same parameters (pledged = identical bytes)
    kw = (level=7, window_log=18, search_log=3, strategy=:greedy)
    buf = IOBuffer()
    s = ZCS(buf; pledged_size=length(text), close_io=false, kw...)
    write(s, text); close(s)
    @test take!(buf) == compress(text; kw...)
    @test transcode(ZstandardCompressor(; kw...), text) == compress(text; kw...)
    # multithreaded compression
    c = compress(data; nthreads=2, level=3, window_log=20)
    @test frame_header(c).window_size == 1 << 20
    @test decompress(c) == data

    # prepared dictionaries fix their parameters
    dict = ZstdDictionary(text[1:20_000])
    pd = prepare_dictionary(dict; level=3, window_log=19)
    @test pd.params.window_log <= 19
    msg = text[30_001:31_500]
    @test compress(msg; dict=pd) == compress(msg; dict=pd, window_log=19)
    @test_throws ArgumentError compress(msg; dict=pd, window_log=20)
    @test decompress(compress(msg; dict=pd), dict) == msg

    # Block_Maximum_Size = min(window, 128 KiB): small windows mean small blocks
    for wlog in (10, 12, 16)
        c = compress(text; level=3, window_log=wlog)
        @test !frame_header(c).single_segment && frame_header(c).window_size == 1 << wlog
        @test transcode(CodecZstd.ZstdDecompressor, c) == text
        b = IOBuffer(); s = ZCS(b; window_log=wlog, close_io=false); write(s, text); close(s)
        @test transcode(CodecZstd.ZstdDecompressor, take!(b)) == text
    end
    # ... and decoders reject a block larger than the window
    bad = vcat(UInt8[0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00],          # magic, FHD, 1 KiB window
               reinterpret(UInt8, [htol(UInt32(1 | (0 << 1) | (2000 << 3)))])[1:3],  # last raw block, 2000 B
               fill(0x61, 2000))
    @test_throws ZstdError decompress(bad)
    @test_throws ZstdError read(ZDS(IOBuffer(bad)))
    @test_throws Exception transcode(CodecZstd.ZstdDecompressor, bad)   # libzstd agrees

    # validation
    @test_throws ArgumentError compress(text; window_log=9)
    @test_throws ArgumentError compress(text; hash_log=40)
    @test_throws ArgumentError compress(text; min_match=2)
    @test_throws ArgumentError compress(text; strategy=:bogus)
    @test_throws ArgumentError compress(text; search_log=1.5)
end

# Block sizes in a frame (walks block headers).
function frame_block_sizes(c)
    h = frame_header(c)
    pos = h.header_size + 1
    sizes = Int[]
    while true
        b = Int(c[pos]) | Int(c[pos+1]) << 8 | Int(c[pos+2]) << 16
        typ = (b >> 1) & 3; sz = b >> 3
        push!(sizes, sz)                          # for RLE blocks: the decoded size
        pos += 3 + (typ == 1 ? 1 : sz)
        b & 1 == 1 && break
    end
    return sizes
end

@testset "Block splitting" begin
    # data that changes character every 24 KiB: text, pseudo-random bytes, small integers
    seg(i, n) = i % 3 == 0 ? make_text(n) : i % 3 == 1 ?
        UInt8[UInt8((k * 2654435761 + i) >> 11 & 0xff) for k in 1:n] : UInt8[UInt8(k % 7) for k in 1:n]
    data = reduce(vcat, [seg(i, 24 << 10)[1:24<<10] for i in 0:40])
    for level in (-1, 1, 3, 5, 6, 9, 13, 16, 18, 19)
        c = compress(data; level)
        @test decompress(c) == data
        @test transcode(CodecZstd.ZstdDecompressor, c) == data
        level >= 3 && @test length(frame_block_sizes(c)) > cld(length(data), 128 << 10)   # some blocks were split
        # streaming, with a small window so the stream buffer is rebased many times
        for (w, chunk) in ((nothing, 100_003), (17, 30_001))
            buf = IOBuffer()
            s = Zstandard.ZstdCompressorStream(buf; level, close_io=false, window_log=w)
            for part in Iterators.partition(data, chunk); write(s, part); end
            close(s)
            sc = take!(buf)
            @test transcode(CodecZstd.ZstdDecompressor, sc) == data
        end
    end
    # Real machine code: slices of libjulia-internal that exposed two bugs with
    # split blocks (a binary-tree candidate ordered by the byte past the block
    # end, at level 17; btlazy2 "unsorted" marks lost when the stream buffer is
    # rebased, at level 13). The bytes differ between Julia versions; the test
    # only needs varied real-world input.
    libdir = joinpath(Sys.BINDIR, Base.LIBDIR, "julia")
    libs = filter(f -> startswith(f, "libjulia-internal") && !islink(joinpath(libdir, f)), readdir(libdir))
    if !isempty(libs)
        lib = read(joinpath(libdir, first(libs)))
        for frac in (0.151, 0.189, 0.529, 0.567)
            off = (round(Int, frac * length(lib)) >> 19) << 19
            x = lib[off+1:min(end, off + (1 << 20))]
            @test decompress(compress(x; level=17)) == x
            buf = IOBuffer()
            s = Zstandard.ZstdCompressorStream(buf; level=13, close_io=false, window_log=17)
            for part in Iterators.partition(x, 50_001); write(s, part); end
            close(s)
            @test decompress(take!(buf)) == x
        end
    end
    # incompressible data is not split (it never saves 3 bytes)
    x = UInt64(1)
    rr = UInt8[(x ⊻= x << 13; x ⊻= x >> 7; x ⊻= x << 17; x % UInt8) for _ in 1:600_000]
    @test all(==(128 << 10), frame_block_sizes(compress(rr; level=19))[1:end-1])
end

@testset "Compression and decompression contexts" begin
    data = make_text(200_000)
    dict = parse_dictionary(train_dictionary([make_text(900 + 13i) for i in 1:200]; dict_size=8192))
    for kw in ((;), (; level=1), (; level=19, checksum=true), (; level=7, window_log=17, strategy=:lazy2),
               (; level=-3), (; level=5, dict), (; level=3, long=true))
        ctx = ZstdCompressionContext(; kw...)
        ref = compress(data; kw...)
        @test compress(ctx, data) == ref
        out = UInt8[]
        @test compress!(ctx, out, data) === out
        @test out == ref
        dctx = ZstdDecompressionContext(; dict=haskey(kw, :dict) ? dict : nothing)
        buf = UInt8[]
        @test decompress!(dctx, buf, out) === buf
        @test buf == data
        @test decompress(dctx, out) == data
        haskey(kw, :dict) || @test transcode(CodecZstd.ZstdDecompressor, compress(ctx, "abc"^100)) == codeunits("abc"^100)
        # reuse across sizes, including empty input and output shrinking
        for n in (0, 1, 17, 5000, 150_000, 3)
            x = data[1:n]
            compress!(ctx, out, x)
            @test out == compress(x; kw...)
            @test decompress!(dctx, buf, out) == x
        end
    end
    # a prepared dictionary fixes the level
    pd = prepare_dictionary(dict; level=4)
    ctx = ZstdCompressionContext(dict=pd)
    @test ctx.level == 4
    s = make_text(3000)
    @test compress(ctx, s) == compress(s; dict=pd)
    @test_throws ArgumentError ZstdCompressionContext(dict=pd, level=5)
    @test_throws ArgumentError ZstdCompressionContext(window_log=40)
    out = UInt8[1, 2, 3]
    @test_throws ArgumentError compress!(ctx, out, out)
    @test_throws ArgumentError decompress!(ZstdDecompressionContext(), out, out)
    @test_throws ZstdError decompress!(ZstdDecompressionContext(), UInt8[], UInt8[1, 2, 3, 4, 5])
    @test occursin("level=4", sprint(show, ctx))
end

# libzstd's experimental format parameter (ZSTD_c_format / ZSTD_d_format)
const ZLIB = Zstd_jll.libzstd
function lib_magicless_compress(src, level)
    cctx = ccall((:ZSTD_createCCtx, ZLIB), Ptr{Cvoid}, ())
    ccall((:ZSTD_CCtx_setParameter, ZLIB), Csize_t, (Ptr{Cvoid}, Cint, Cint), cctx, 10, 1)   # ZSTD_c_format = magicless
    ccall((:ZSTD_CCtx_setParameter, ZLIB), Csize_t, (Ptr{Cvoid}, Cint, Cint), cctx, 100, level)
    dst = Vector{UInt8}(undef, length(src) + 1024)
    n = ccall((:ZSTD_compress2, ZLIB), Csize_t, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              cctx, dst, length(dst), src, length(src))
    ccall((:ZSTD_freeCCtx, ZLIB), Csize_t, (Ptr{Cvoid},), cctx)
    return resize!(dst, n)
end
function lib_magicless_decompress(src, n)
    dctx = ccall((:ZSTD_createDCtx, ZLIB), Ptr{Cvoid}, ())
    ccall((:ZSTD_DCtx_setParameter, ZLIB), Csize_t, (Ptr{Cvoid}, Cint, Cint), dctx, 1000, 1) # ZSTD_d_format = magicless
    dst = Vector{UInt8}(undef, n)
    k = ccall((:ZSTD_decompressDCtx, ZLIB), Csize_t, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
              dctx, dst, n, src, length(src))
    ccall((:ZSTD_freeDCtx, ZLIB), Csize_t, (Ptr{Cvoid},), dctx)
    return k == n ? dst : nothing
end

@testset "Frame header options" begin
    data = make_text(150_000)
    dict = parse_dictionary(train_dictionary([make_text(900 + 13i) for i in 1:200]; dict_size=8192))
    # content size flag
    c = compress(data; content_size=false)
    @test frame_content_size(c) === nothing
    @test !frame_header(c).single_segment
    @test decompress(c) == data
    @test transcode(CodecZstd.ZstdDecompressor, c) == data
    @test frame_content_size(transcode(ZstandardCompressor(content_size=false), data)) === nothing
    buf = IOBuffer()
    s = Zstandard.ZstdCompressorStream(buf; pledged_size=length(data), content_size=false, close_io=false)
    write(s, data); close(s)
    c = take!(buf)
    @test frame_content_size(c) === nothing && decompress(c) == data
    # dictionary ID flag
    c = compress(data; dict, dict_id=false)
    @test frame_dict_id(c) == 0
    @test decompress(c, dict) == data
    @test frame_dict_id(compress(data; dict)) == dict.id
    # magicless frames
    for kw in ((;), (; checksum=true), (; dict), (; level=19), (; content_size=false, level=1))
        c = compress(data; magicless=true, kw...)
        ref = compress(data; kw...)
        @test c == ref[5:end]
        d = haskey(kw, :dict) ? dict : nothing
        @test decompress(c, d; magicless=true) == data
        @test frame_compressed_size(c; magicless=true) == length(c)
        haskey(kw, :dict) || @test lib_magicless_decompress(c, length(data)) == data
    end
    @test_throws ZstdError decompress(compress(data; magicless=true))
    lc = lib_magicless_compress(data, 5)
    @test decompress(lc; magicless=true) == data
    two = vcat(compress(data; magicless=true), lc)
    @test decompress(two; magicless=true) == vcat(data, data)
    @test read(Zstandard.ZstdDecompressorStream(IOBuffer(two); magicless=true)) == vcat(data, data)
    @test transcode(ZstandardDecompressor(magicless=true), two) == vcat(data, data)
    @test decompress(ZstdDecompressionContext(magicless=true), two) == vcat(data, data)
    @test decompress(compress(ZstdCompressionContext(magicless=true), data); magicless=true) == data
    @test decompress(compress(repeat(data, 30); nthreads=2, level=1, magicless=true); magicless=true) == repeat(data, 30)
    @test frame_header(compress(data; magicless=true); magicless=true).content_size == length(data)
    # size hint: parameters for the hinted size, no recorded size, any amount of input
    buf = IOBuffer()
    s = Zstandard.ZstdCompressorStream(buf; size_hint=2000, close_io=false)
    write(s, data); close(s)
    c = take!(buf)
    @test frame_header(c).window_size == 2048
    @test frame_content_size(c) === nothing
    @test decompress(c) == data
    # a pledged size (as `transcode` makes) takes precedence over the hint
    @test frame_header(transcode(ZstandardCompressor(size_hint=10_000), data)).window_size == length(data)
    buf = IOBuffer()
    st = TranscodingStream(ZstandardCompressor(size_hint=10_000), buf; stop_on_end=false)
    write(st, data); write(st, TranscodingStreams.TOKEN_END); flush(st)
    c = take!(buf)
    @test frame_header(c).window_size == 1 << 14
    @test decompress(c) == data
    @test_throws ArgumentError Zstandard.ZstdCompressorStream(IOBuffer(); size_hint=-1)
end

@testset "Reference prefix" begin
    old = make_text(400_000)
    new = copy(old)
    x = UInt64(3)
    for k in 1:100
        x = x * 6364136223846793005 + 1442695040888963407
        new[(x >> 33) % length(new) + 1] = UInt8('#')
    end
    new = vcat(new[1:200_000], codeunits("a fresh paragraph in the middle\n"), new[200_001:end])
    fold = tempname(); write(fold, old)
    for kw in ((; level=3), (; level=9), (; level=19), (; level=3, long=true), (; level=1, checksum=true))
        c = compress(new; prefix=old, kw...)
        @test length(c) < length(compress(new; kw...)) ÷ 20      # mostly references into the prefix
        @test frame_dict_id(c) == 0
        @test frame_header(c).window_size >= length(old)          # reaches back into the prefix
        @test decompress(c; prefix=old) == new
        @test decompress(ZstdDecompressionContext(prefix=old), c) == new
        @test read(Zstandard.ZstdDecompressorStream(IOBuffer(c); prefix=old)) == new
        f = tempname(); write(f, c)
        @test read(`$(Zstd_jll.zstd()) -q -d --long=27 --patch-from=$fold -c $f`) == new   # libzstd agrees
        @test compress(ZstdCompressionContext(; prefix=old, kw...), new) == c
    end
    # libzstd's patches decode here
    fnew = tempname(); write(fnew, new)
    z = read(`$(Zstd_jll.zstd()) -q -5 --patch-from=$fold -c $fnew`)
    @test decompress(z; prefix=old) == new
    # streaming compression with a prefix
    buf = IOBuffer()
    s = Zstandard.ZstdCompressorStream(buf; prefix=old, pledged_size=length(new), close_io=false)
    for part in Iterators.partition(new, 70_001); write(s, part); end
    close(s)
    c = take!(buf)
    @test length(c) < length(compress(new)) ÷ 20
    @test decompress(c; prefix=old) == new
    # an explicit window_log is kept; prefix and dict are exclusive
    @test frame_header(compress(new; prefix=old, window_log=17)).window_size == 1 << 17
    @test_throws ArgumentError compress(new; prefix=old, dict=ZstdDictionary(old))
    @test decompress(compress(new; prefix=UInt8[]); prefix=UInt8[]) == new
    @test decompress(compress(new; prefix=old[1:3]); prefix=old[1:3]) == new
end

struct ZInBuf; src::Ptr{UInt8}; size::Csize_t; pos::Csize_t; end
struct ZOutBuf; dst::Ptr{UInt8}; size::Csize_t; pos::Csize_t; end
# Feed `src` to a libzstd streaming decoder; return what it produced so far.
function lib_stream_decode(src::Vector{UInt8}, cap::Int)
    ds = ccall((:ZSTD_createDStream, ZLIB), Ptr{Cvoid}, ())
    out = zeros(UInt8, cap)
    ib = Ref(ZInBuf(pointer(src), length(src), 0)); ob = Ref(ZOutBuf(pointer(out), cap, 0))
    GC.@preserve src out while ib[].pos < length(src)
        r = ccall((:ZSTD_decompressStream, ZLIB), Csize_t, (Ptr{Cvoid}, Ref{ZOutBuf}, Ref{ZInBuf}), ds, ob, ib)
        ccall((:ZSTD_isError, ZLIB), Cuint, (Csize_t,), r) != 0 && error("libzstd error")
        ob[].pos == cap && break
    end
    ccall((:ZSTD_freeDStream, ZLIB), Csize_t, (Ptr{Cvoid},), ds)
    return out[1:ob[].pos]
end

@testset "Flush mid-frame" begin
    parts = [make_text(n) for n in (5_000, 200_000, 17, 0, 90_000)]
    for level in (1, 3, 9, 19), checksum in (false, true)
        io = IOBuffer()
        s = Zstandard.ZstdCompressorStream(io; level, checksum, close_io=false)
        written = UInt8[]
        for p in parts
            write(s, p); append!(written, p)
            flush(s); flush(s)                   # a second flush adds nothing
            sofar = Vector{UInt8}(view(io.data, 1:io.size))
            # everything written so far decodes from the unfinished frame
            r = Zstandard.ZstdDecompressorStream(IOBuffer(sofar))
            @test read(r, length(written)) == written
            @test lib_stream_decode(sofar, length(written) + 1) == written
        end
        close(s)
        c = take!(io)
        @test decompress(c) == written
        @test transcode(CodecZstd.ZstdDecompressor, c) == written
    end
end

@testset "Seekable format" begin
    data = make_text(1_000_000)
    for (fs, chk) in ((100_000, true), (1 << 20, false), (4093, true))
        a = compress_seekable(data; frame_size=fs, checksum=chk, level=3)
        @test decompress(a) == data                                   # a plain multi-frame stream
        @test transcode(CodecZstd.ZstdDecompressor, a) == data
        t = seek_table(a)
        @test length(t) == cld(length(data), fs)
        @test t.content_size == length(data)
        @test (t.checksums !== nothing) == chk
        @test sum(t.csize) + t.table_size == length(a)
        @test t == t && occursin("frames", sprint(show, t))
        @test t.dsize[1] == min(fs, length(data))
        f = tempname(); write(f, a)
        x = UInt64(7)
        for _ in 1:20
            x = x * 6364136223846793005 + 1442695040888963407
            lo = Int(x >> 40) % length(data) + 1
            hi = min(length(data), lo + Int(x >> 20) % 300_000)
            @test decompress_range(a, lo:hi) == data[lo:hi]
            @test decompress_range(IOBuffer(a), lo:hi) == data[lo:hi]
            @test open(io -> decompress_range(io, lo:hi; table=t), f) == data[lo:hi]
        end
        @test decompress_range(a, 1:length(data)) == data
        @test decompress_range(a, 5:4) == UInt8[]
        @test_throws BoundsError decompress_range(a, 0:10)
        @test_throws BoundsError decompress_range(a, length(data):length(data)+1)
        @test open(seek_table, f).csize == t.csize
    end
    # identical output on several tasks; other compress keywords pass through
    @test compress_seekable(data; frame_size=65536, nthreads=4) == compress_seekable(data; frame_size=65536)
    a = compress_seekable(data; frame_size=200_000, level=19, window_log=16)
    @test frame_header(a).window_size == 1 << 16
    @test decompress_range(a, 199_990:200_010) == data[199_990:200_010]
    # an empty frame (as libzstd's endStream writes) and a corrupt checksum
    fr = [compress(data[1:1000]), compress(UInt8[]), compress(data[1001:3000])]
    sums = [Zstandard.XXHash.content_checksum(d) for d in (data[1:1000], UInt8[], data[1001:3000])]
    tab = Zstandard._seek_table([(length(fr[i]), (1000, 0, 2000)[i], Int(sums[i])) for i in 1:3], true)
    a = vcat(fr..., tab)
    @test length(seek_table(a)) == 3
    @test decompress_range(a, 990:1010) == data[990:1010]
    @test decompress_range(a, 1001:1001) == data[1001:1001]
    bad = copy(a); bad[end - 9 - 12 + 8] ⊻= 0x01                    # last entry's checksum
    @test_throws ZstdError decompress_range(bad, 1500:1600)
    @test decompress_range(bad, 10:20) == data[10:20]               # other frames unaffected
    @test_throws ZstdError seek_table(compress(data))               # not seekable
    @test_throws ArgumentError compress_seekable(data; frame_size=0)
    @test decompress(compress_seekable(UInt8[])) == UInt8[]
    @test length(seek_table(compress_seekable(UInt8[]))) == 0
end

@testset "Memory estimates and stream progress" begin
    data = make_text(3_000_000)
    E = Zstandard.Encoder
    for level in (-3, 1, 3, 7, 13, 16, 19)
        cc = E.CompressionContext()
        E.compress_frame!(cc, data, level)
        est = estimate_compression_memory(; level, src_size=length(data))
        @test 0.9 < est / Base.summarysize(cc) < 1.1
    end
    @test estimate_compression_memory(level=19) > estimate_compression_memory(level=1)
    @test estimate_compression_memory(level=3, src_size=1000) < estimate_compression_memory(level=3)
    @test estimate_compression_memory(level=3, src_size=10^8, nthreads=4) >
          3 * estimate_compression_memory(level=3, src_size=10^8)
    @test estimate_compression_memory(level=3, long=true) > estimate_compression_memory(level=3)
    for level in (1, 3, 9)
        buf = IOBuffer()
        s = Zstandard.ZstdCompressorStream(buf; level, close_io=false)
        for p in Iterators.partition(data, 100_000); write(s, p); end
        @test Base.summarysize(s.sc) < 1.1 * estimate_compression_memory(; level, streaming=true)
        pr = stream_progress(s)
        @test pr.ingested == length(data)
        @test 0 < pr.consumed <= pr.ingested
        @test pr.flushed <= pr.produced
        close(s)
        c = take!(buf)
        pr = stream_progress(s)
        @test pr.consumed == pr.ingested == length(data)
        @test pr.flushed == pr.produced == length(c)
        # decoder side
        c2 = vcat(c, skippable_frame(UInt8[1, 2, 3]), compress(data[1:1000]))
        r = Zstandard.ZstdDecompressorStream(IOBuffer(c2))
        @test stream_progress(r) == (; consumed=0, produced=0, frames=0)
        read(r, 10)
        @test stream_progress(r).produced >= 10
        rest = read(r)
        pr = stream_progress(r)
        @test pr.consumed == length(c2)
        @test pr.produced == length(data) + 1000 == 10 + length(rest)
        @test pr.frames == 2
        w = frame_header(c).window_size
        @test Base.summarysize(r.d) < 1.2 * estimate_decompression_memory(window_size=w)
    end
    @test estimate_decompression_memory(streaming=false) < estimate_decompression_memory(window_size=1 << 20)
end

@testset "Sequence API" begin
    nodelim(s) = begin
        out = ZstdSequence[]; carry = 0
        for x in s
            if x.match_length == 0
                carry += x.literal_length
            else
                push!(out, ZstdSequence(x.offset, x.literal_length + carry, x.match_length)); carry = 0
            end
        end
        out
    end
    text = make_text(600_000)
    x = UInt64(11)
    rnd(n) = UInt8[(x = x * 6364136223846793005 + 1442695040888963407; (x >> 56) % UInt8) for _ in 1:n]
    mixed = vcat(rnd(150_000), repeat(text[1:1000], 200), rnd(70_001))
    for d in (text, mixed, UInt8[], UInt8[1, 2, 3], fill(0x07, 300_000)), level in (1, 9, 19)
        s = generate_sequences(d; level)
        @test all(z -> z.match_length == 0 || (z.offset >= 1 && z.match_length >= 3), s)
        @test sum(z -> z.literal_length + z.match_length, s; init=0) == length(d)
        @test count(z -> z.offset == 0 && z.match_length == 0, s) >= cld(length(d), 128 << 10)
        c = compress_sequences(d, s; level)
        @test transcode(CodecZstd.ZstdDecompressor, c) == d
        level < 16 && @test length(c) <= length(compress(d; level)) + 8
        c2 = compress_sequences(d, nodelim(s); level, checksum=true)
        @test decompress(c2) == d
    end
    # matches and literal runs longer than a block, implied trailing literals
    d = repeat(UInt8[1, 2, 3, 4, 5], 100_000)
    @test decompress(compress_sequences(d, [ZstdSequence(5, 5, length(d) - 5)])) == d
    @test decompress(compress_sequences(text, ZstdSequence[])) == text
    @test decompress(compress_sequences(text, [ZstdSequence(0, length(text) - 100, 0)][1:0])) == text
    # validation
    @test_throws ArgumentError compress_sequences(text, [ZstdSequence(3, 10, 2)])           # match too short
    @test_throws ArgumentError compress_sequences(text, [ZstdSequence(50, 10, 20)])          # reaches before the data
    @test_throws ArgumentError compress_sequences(text, [ZstdSequence(1, 10, 20)])           # does not match
    @test_throws ArgumentError compress_sequences(text, [ZstdSequence(0, length(text) + 1, 0)])
    @test_throws ArgumentError compress_sequences(text, [ZstdSequence(0, 200_000, 0)])        # block too large
    @test_throws ArgumentError compress_sequences(text, [ZstdSequence(0, 1000, 0), ZstdSequence(3, 1, 5)])
    c = compress_sequences(text, [ZstdSequence(1, 10, 20)]; validate=false)                   # unchecked: decodes to other bytes
    @test length(decompress(c)) == length(text) && decompress(c) != text
    @test sprint(show, ZstdSequence(1, 2, 3)) == "ZstdSequence(1, 2, 3)"
end
