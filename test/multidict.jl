using Zstandard
using Zstandard: frame_dict_id, skippable_frame, finalize_dictionary, ZstandardDecompressionContext,
    decompress!, compress_seekable, decompress_range
using Test
using TranscodingStreams
using Zstd_jll

# Deterministic text from a word list, so two corpora get different dictionaries.
function corpus_text(words, n, seed)
    x = UInt64(seed)
    out = UInt8[]
    while length(out) < n
        x = x * 6364136223846793005 + 1442695040888963407
        append!(out, codeunits(words[(x >> 33) % length(words) + 1]))
    end
    return resize!(out, n)
end

# Incompressible bytes (to make the input large enough for parallel decoding).
function noise(n, seed)
    x = UInt64(seed)
    return [(x = x * 6364136223846793005 + 1442695040888963407; UInt8(x >> 56)) for _ in 1:n]
end

const WORDS_A = ["function", "end", "return", "if", "else", "for", "while", "begin", "x", "y",
                 "= ", "+ ", "(", ")", "\n", "    ", "const", "struct", "Int", "Vector{UInt8}"]
const WORDS_B = ["<div class=\"", "\">", "</div>", "<span>", "</span>", "href=", "\n", "  ",
                 "<a ", "</a>", "style=\"", "color: red;", "margin: 0;", "<p>", "</p>", "id=\""]

@testset "Multiple dictionaries" begin
    samples_a = [corpus_text(WORDS_A, 800 + 7i, i) for i in 1:300]
    samples_b = [corpus_text(WORDS_B, 800 + 7i, 1000 + i) for i in 1:300]
    da = parse_dictionary(train_dictionary(samples_a; dict_size=8192))
    db = parse_dictionary(train_dictionary(samples_b; dict_size=8192))
    raw = ZstandardDictionary(corpus_text(WORDS_A, 4096, 77))
    @test da.id != 0 && db.id != 0 && da.id != db.id

    @testset "construction" begin
        s = ZstandardDictionarySet(da, db)
        @test length(s) == 2
        @test haskey(s, da.id) && haskey(s, db.id) && !haskey(s, 0)
        @test ZstandardDictionarySet([da, db]).dicts == s.dicts
        sr = ZstandardDictionarySet(da, raw, db)
        @test sr.default === raw && length(sr) == 3 && haskey(sr, 0)
        # a formatted default is also selected by its ID
        sd = ZstandardDictionarySet(db; default=da)
        @test sd.default === da && haskey(sd, da.id) && haskey(sd, db.id)
        @test occursin(string(da.id), sprint(show, s))
        clash = parse_dictionary(finalize_dictionary(da.content, samples_a; dict_id=db.id))
        @test clash.id == db.id
        @test_throws ArgumentError ZstandardDictionarySet(da, db, clash)
        @test length(ZstandardDictionarySet(da, db, da)) == 2          # the same dictionary twice is fine
        @test ZstandardDictionarySet(da; default=da).default === da
        @test_throws ArgumentError ZstandardDictionarySet(raw, ZstandardDictionary(UInt8[1, 2, 3]))
        @test_throws ArgumentError ZstandardDictionarySet(raw; default=ZstandardDictionary(UInt8[1, 2, 3]))
        @test_throws ArgumentError ZstandardDictionarySet(Any[da, "not a dictionary"])
        @test length(ZstandardDictionarySet()) == 0
        # an equal copy (the same file parsed twice) is not a clash
        da2 = parse_dictionary(train_dictionary(samples_a; dict_size=8192))
        @test da2 !== da && length(ZstandardDictionarySet(da, db, da2)) == 2
        @test length(ZstandardDictionarySet(raw, ZstandardDictionary(copy(raw.content)))) == 1
        # haskey and getindex take any integer
        @test !haskey(s, -1) && !haskey(s, Int64(typemax(UInt32)) + 1) && !haskey(s, 12345)
        @test s[da.id] === da && s[Int(db.id)] === db && sr[0] === raw
        @test_throws KeyError s[0]
        @test_throws KeyError s[-1]
        @test_throws KeyError s[Int64(typemax(UInt32)) + 1]
        # iteration
        @test collect(sr) == [da, raw, db] && eltype(sr) == ZstandardDictionary
        @test Set(d.id for d in sd) == Set([da.id, db.id]) && length(sd) == 2
        @test [d for d in ZstandardDictionarySet()] == ZstandardDictionary[]
    end

    # Frames using dictionary A, dictionary B, no dictionary and the raw
    # dictionary (ID 0), interleaved.
    texts = Vector{UInt8}[]
    frames = Vector{UInt8}[]
    for i in 1:24
        k = mod1(i, 4)
        t = k == 1 || k == 3 ? corpus_text(WORDS_A, 6000 + 101i, 5000 + i) :
                               corpus_text(WORDS_B, 6000 + 101i, 6000 + i)
        t = vcat(t, noise(5000, i))
        f = k == 1 ? compress(t; dict=da, level=3 + i % 5) :
            k == 2 ? compress(t; dict=db, level=1 + i % 7, checksum=true) :
            k == 3 ? compress(t; dict=raw) :
                     compress(t)
        push!(texts, t); push!(frames, f)
    end
    data = reduce(vcat, frames)
    expected = reduce(vcat, texts)
    @test length(data) >= Zstandard.PARALLEL_DECODE_MIN    # exercises the parallel path
    set = ZstandardDictionarySet(da, db, raw)

    @testset "one-shot" begin
        @test_throws ZstandardError decompress(data, da)          # the old single-dictionary limit
        for nt in (1, 4)
            @test decompress(data, set; nthreads=nt) == expected
            @test decompress(data, [da, db, raw]; nthreads=nt) == expected
            @test decompress(data, Any[da, db, raw]; nthreads=nt) == expected
        end
        @test decompress(data, (da, db, raw) |> collect) == expected
        # raw bytes are not a dictionary
        @test_throws ArgumentError decompress(data, raw.content)
        @test_throws ArgumentError decompress(data, Any[da, raw.content])
        @test decompress(view(data, 1:length(data)), set) == expected
        # skippable frames between dictionary frames
        sk = vcat(frames[1], skippable_frame(UInt8[1, 2, 3]), frames[2])
        @test decompress(sk, set) == vcat(texts[1], texts[2])
        # without the raw default, raw-dictionary frames cannot reference it
        @test decompress(vcat(frames[1], frames[2], frames[4]), ZstandardDictionarySet(da, db)) ==
              vcat(texts[1], texts[2], texts[4])
    end

    @testset "context" begin
        ctx = ZstandardDecompressionContext(; dict=set)
        @test decompress(ctx, data) == expected
        @test decompress(ctx, data) == expected               # reuse
        out = UInt8[]
        @test decompress!(ctx, out, data) === out && out == expected
        @test ZstandardDecompressionContext(; dict=[da, db, raw]).dict isa ZstandardDictionarySet
        @test decompress(ZstandardDecompressionContext(; dict=Any[da, db, raw]), data) == expected
        @test occursin("dicts", sprint(show, ctx))
    end

    @testset "stream" begin
        @test read(Zstandard.ZstandardDecompressorStream(IOBuffer(data), set)) == expected
        @test read(Zstandard.ZstandardDecompressorStream(IOBuffer(data), [da, db, raw])) == expected
        @test read(Zstandard.ZstandardDecompressorStream(IOBuffer(data), Any[da, db, raw])) == expected
        s = Zstandard.ZstandardDecompressorStream(IOBuffer(data), set)
        got = UInt8[]
        while !eof(s)
            append!(got, read(s, 3001))
        end
        @test got == expected
        # a frame needing a dictionary outside the set: the earlier frames are readable
        s = Zstandard.ZstandardDecompressorStream(IOBuffer(vcat(frames[1], frames[2])), ZstandardDictionarySet(da))
        @test read(s, length(texts[1])) == texts[1]
        @test_throws ZstandardError read(s)
    end

    @testset "codec" begin
        @test transcode(ZstandardDecompressor(; dict=set), data) == expected
        codec = ZstandardDecompressor(; dict=[da, db, raw])
        @test transcode(codec, data) == expected
        @test transcode(codec, frames[2]) == texts[2]         # codec reuse
        @test transcode(ZstandardDecompressor(; dict=Any[da, db, raw]), data) == expected
        @test read(TranscodingStream(ZstandardDecompressor(; dict=set), IOBuffer(data))) == expected
    end

    @testset "seekable archive" begin
        a = compress_seekable(expected; frame_size=10_000, dict=db)
        @test decompress_range(a, 12_345:56_789; dict=set) == expected[12_345:56_789]
        @test decompress_range(a, 1:length(expected); dict=[da, db]) == expected
        @test decompress_range(a, 1:length(expected); dict=Any[da, db]) == expected
        @test_throws ZstandardError decompress_range(a, 1:10; dict=ZstandardDictionarySet(da))
    end

    @testset "accessors" begin
        @test Zstandard.dictionary_id(da) == da.id != 0
        @test Zstandard.dictionary_id(raw) == 0
        @test Zstandard.dictionary_content(raw) == raw.content
        @test Zstandard.dictionary_content(da) == da.content
        @test Zstandard.dictionary_id(da) == frame_dict_id(frames[1])
        @test VERSION < v"1.11" || Base.ispublic(Zstandard, :dictionary_id)
        # Base.parse is parse_dictionary
        bytes = finalize_dictionary(da.content, samples_a; dict_id=da.id)
        @test Zstandard.dictionary_id(parse(ZstandardDictionary, bytes)) == da.id
        @test parse(ZstandardDictionary, view(bytes, 1:length(bytes))).content == parse_dictionary(bytes).content
        @test Zstandard.dictionary_id(parse(ZstandardDictionary, UInt8[1, 2, 3])) == 0
        # prepared dictionaries
        pd = Zstandard.prepare_dictionary(da; level=7)
        @test Zstandard.compression_level(pd) == 7
        @test ZstandardDictionary(pd) === da
        @test decompress(compress(texts[1]; dict=pd); dict=ZstandardDictionary(pd)) == texts[1]
    end

    @testset "dict keyword" begin
        @test decompress(data; dict=set) == expected
        @test decompress(frames[1]; dict=da) == texts[1]
        @test decompress(data; dict=[da, db, raw], nthreads=4) == expected
        @test read(Zstandard.ZstandardDecompressorStream(IOBuffer(data); dict=set)) == expected
        @test read(Zstandard.ZstandardDecompressorStream(IOBuffer(frames[2]); dict=db)) == texts[2]
        @test_throws ArgumentError decompress(frames[1], da; dict=da)
        @test_throws ArgumentError Zstandard.ZstandardDecompressorStream(IOBuffer(frames[1]), da; dict=da)
    end

    @testset "frame ID 0 with a formatted default" begin
        # dict_id=false leaves the ID out of the header: the default decodes it
        f = vcat(compress(texts[1]; dict=da, dict_id=false), frames[2])
        @test frame_dict_id(f) == 0
        @test decompress(f, ZstandardDictionarySet(db; default=da)) == vcat(texts[1], texts[2])
        @test read(Zstandard.ZstandardDecompressorStream(IOBuffer(f), ZstandardDictionarySet(db; default=da))) ==
              vcat(texts[1], texts[2])
    end

    @testset "errors" begin
        e = try
            decompress(data, ZstandardDictionarySet(da, raw)); nothing
        catch err
            err
        end
        @test e isa ZstandardError && occursin(string(db.id), sprint(showerror, e))
        @test_throws ZstandardError decompress(data, ZstandardDictionarySet(); nthreads=4)
        @test_throws ZstandardError read(Zstandard.ZstandardDecompressorStream(IOBuffer(data), ZstandardDictionarySet(db)))
        @test_throws ZstandardError transcode(ZstandardDecompressor(; dict=ZstandardDictionarySet(da)), data)
        @test_throws ArgumentError decompress(data, set; prefix=UInt8[1, 2, 3])
        @test_throws ArgumentError ZstandardDecompressionContext(; dict=set, prefix=UInt8[1, 2, 3])
    end

    @testset "frames written by libzstd" begin
        dir = mktempdir()
        pa = joinpath(dir, "a.dict"); pb = joinpath(dir, "b.dict")
        write(pa, train_dictionary(samples_a; dict_size=8192))
        write(pb, train_dictionary(samples_b; dict_size=8192))
        zstd = Zstd_jll.zstd()
        parts = Vector{UInt8}[]
        for (i, (t, p)) in enumerate(zip(texts[1:2:8], Iterators.cycle((pa, pb))))
            f = joinpath(dir, "t$i"); write(f, t)
            push!(parts, read(`$zstd -q -c -$(1 + 2i) -D $p $f`))
        end
        @test frame_dict_id(parts[1]) == da.id && frame_dict_id(parts[2]) == db.id
        lib = reduce(vcat, parts)
        want = reduce(vcat, texts[1:2:8])
        @test decompress(lib, set) == want
        @test read(Zstandard.ZstandardDecompressorStream(IOBuffer(lib), set)) == want
    end
end
