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
const ZDS = Zstandard.ZstdDecompressorStream

@testset "ZstdCompressorStream" begin
    for n in (0, 1, 1000, 131072, 131073, 700_000), level in (1, 3, 9), checksum in (false, true)
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
    for smp in samples[301:end], level in (1, 3, 7)
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
