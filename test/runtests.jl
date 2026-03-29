using Zstandard
using Test
using Aqua

@testset "Zstandard Decompressor" begin
    fixtures_dir = joinpath(@__DIR__, "fixtures")

    @testset "Hello, Zstd!" begin
        compressed = read(joinpath(fixtures_dir, "hello.zst"))
        expected = read(joinpath(fixtures_dir, "hello.txt"))
        decompressed = decompress(compressed)
        @test decompressed == expected
    end

    @testset "Hello CLI" begin
        compressed = read(joinpath(fixtures_dir, "hello_cli.zst"))
        expected = read(joinpath(fixtures_dir, "hello.txt"))
        decompressed = decompress(compressed)
        @test decompressed == expected
    end

    @testset "Empty file" begin
        compressed = read(joinpath(fixtures_dir, "empty.zst"))
        expected = read(joinpath(fixtures_dir, "empty.txt"))
        decompressed = decompress(compressed)
        @test decompressed == expected
    end

    @testset "Multi-frame" begin
        compressed = read(joinpath(fixtures_dir, "multi_frame.zst"))
        expected = read(joinpath(fixtures_dir, "multi_frame.txt"))
        decompressed = decompress(compressed)
        @test decompressed == expected
    end

    @testset "Zeros" begin
        compressed = read(joinpath(fixtures_dir, "zeros.zst"))
        expected = read(joinpath(fixtures_dir, "zeros.txt"))
        decompressed = decompress(compressed)
        @test decompressed == expected
    end

    @testset "Random data (Huffman)" begin
        compressed = read(joinpath(fixtures_dir, "random.zst"))
        expected = read(joinpath(fixtures_dir, "random.txt"))
        decompressed = decompress(compressed)
        @test decompressed == expected
    end

    @testset "Mixed data" begin
        compressed = read(joinpath(fixtures_dir, "mixed.zst"))
        expected = read(joinpath(fixtures_dir, "mixed.txt"))
        decompressed = decompress(compressed)
        @test decompressed == expected
    end

    @testset "Dictionary" begin
        dict_path = joinpath(fixtures_dir, "raw.dict")
        compressed_path = joinpath(fixtures_dir, "use_dict.zst")
        expected = read(joinpath(fixtures_dir, "use_dict.txt"))
        
        dict = parse_dictionary(read(dict_path))
        decompressed = decompress(read(compressed_path), dict)
        @test decompressed == expected
    end

    @testset "Streaming Mixed data" begin
        compressed_path = joinpath(fixtures_dir, "mixed.zst")
        expected = read(joinpath(fixtures_dir, "mixed.txt"))
        
        open(compressed_path, "r") do io
            stream = ZstdDecompressorStream(io)
            decompressed = read(stream)
            @test decompressed == expected
        end
    end
end

include("compress.jl")

@testset "Aqua.jl" begin
    Aqua.test_all(Zstandard)
end
