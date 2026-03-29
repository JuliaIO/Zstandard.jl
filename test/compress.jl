using Zstandard
using Test
using CodecZstd

@testset "Zstandard Compressor (Raw/Level 0)" begin
    # 1. Simple String
    data1 = b"Hello, Zstandard Compression!"
    comp1 = compress(data1)

    @test decompress(comp1) == data1
    @test transcode(ZstdDecompressor, comp1) == data1

    # 2. Empty Data
    data2 = b""
    comp2 = compress(data2)

    @test decompress(comp2) == data2
    @test transcode(ZstdDecompressor, comp2) == data2

    # 3. Large Data (Multiple Raw Blocks)
    # 300 KB ensures it's split into multiple 128 KB chunks
    data3 = rand(UInt8, 300 * 1024)
    comp3 = compress(data3)

    @test decompress(comp3) == data3
    @test transcode(ZstdDecompressor, comp3) == data3

    # 4. Repetitive Data (Triggers Match Finder)
    data4 = repeat(b"abc", 100)
    comp4 = compress(data4)
    @test decompress(comp4) == data4
    @test transcode(ZstdDecompressor, comp4) == data4

    # 5. Level 0 Alias (should work same as Level 3)
    comp0 = compress(data4, level=0)
    @test decompress(comp0) == data4
    @test transcode(ZstdDecompressor, comp0) == data4

    # 6. Fast Levels
    comp_fast = compress(data4, level=-1)
    @test decompress(comp_fast) == data4
end

@testset "RLE Literals" begin
    # All same byte → RLE literals section
    data_rle = fill(0x42, 200)
    comp_rle = compress(data_rle)
    @test decompress(comp_rle) == data_rle
    @test transcode(ZstdDecompressor, comp_rle) == data_rle

    # Large RLE (>4096 bytes to exercise 3-byte header)
    data_rle_large = fill(0xAB, 5000)
    comp_rle_large = compress(data_rle_large)
    @test decompress(comp_rle_large) == data_rle_large
    @test transcode(ZstdDecompressor, comp_rle_large) == data_rle_large
end

@testset "Huffman Literal Compression" begin
    # ASCII text with skewed distribution — Huffman should help
    data_text = Vector{UInt8}(repeat("the quick brown fox jumps over the lazy dog ", 50))
    comp_text = compress(data_text)
    @test decompress(comp_text) == data_text
    @test transcode(ZstdDecompressor, comp_text) == data_text
    # Compression ratio should be better than raw
    @test length(comp_text) < length(data_text)

    # Large ASCII text (>1KB literals triggers 4-stream Huffman)
    data_large_text = Vector{UInt8}(repeat("hello world this is a test of huffman compression ", 100))
    comp_large_text = compress(data_large_text)
    @test decompress(comp_large_text) == data_large_text
    @test transcode(ZstdDecompressor, comp_large_text) == data_large_text
end

@testset "Large Data Compression (>128KB)" begin
    # Repetitive large data — should compress across multiple blocks
    data_rep = repeat(b"abcdefgh", 20 * 1024)  # 160 KB
    comp_rep = compress(data_rep)
    @test decompress(comp_rep) == data_rep
    @test transcode(ZstdDecompressor, comp_rep) == data_rep
    @test length(comp_rep) < length(data_rep)

    # Random large data — raw blocks fallback
    data_rand = rand(UInt8, 300 * 1024)
    comp_rand = compress(data_rand)
    @test decompress(comp_rand) == data_rand
    @test transcode(ZstdDecompressor, comp_rand) == data_rand
end

@testset "Repeat Offsets" begin
    # Pattern where repeat offsets should kick in heavily
    data_rep4 = repeat(b"abcd", 1000)
    comp_rep4 = compress(data_rep4)
    @test decompress(comp_rep4) == data_rep4
    @test transcode(ZstdDecompressor, comp_rep4) == data_rep4
    @test length(comp_rep4) < length(data_rep4) ÷ 10  # Should compress very well

    # Multi-block with repeat offsets persisting across blocks
    data_rep_large = repeat(b"xyzw", 40 * 1024)  # 160 KB, spans multiple 128KB blocks
    comp_rep_large = compress(data_rep_large)
    @test decompress(comp_rep_large) == data_rep_large
    @test transcode(ZstdDecompressor, comp_rep_large) == data_rep_large
    @test length(comp_rep_large) < length(data_rep_large) ÷ 10
end

# ===== Expanded tests inspired by zstd reference implementation =====

@testset "Golden Decompression (reference impl)" begin
    fixtures_dir = joinpath(@__DIR__, "fixtures")

    @testset "RLE first block (1MB zeros)" begin
        # Tests RLE as first block — decoder bug in zstd v1.4.3
        compressed = read(joinpath(fixtures_dir, "rle-first-block.zst"))
        decompressed = decompress(compressed)
        @test decompressed == zeros(UInt8, 1048576)
    end

    @testset "Empty block" begin
        compressed = read(joinpath(fixtures_dir, "empty-block.zst"))
        decompressed = decompress(compressed)
        @test decompressed == UInt8[]
    end

    @testset "Block exactly 128KB" begin
        # Tests block size boundary — decoder edge case from zstd v1.5.2
        compressed = read(joinpath(fixtures_dir, "block-128k.zst"))
        decompressed = decompress(compressed)
        @test length(decompressed) > 0
        # Verify libzstd agrees
        @test decompressed == transcode(ZstdDecompressor, compressed)
    end

    @testset "Zero sequences (2-byte format)" begin
        # Tests 0 sequences using 2-byte format — decoder bug in zstd v1.5.5
        compressed = read(joinpath(fixtures_dir, "zeroSeq_2B.zst"))
        decompressed = decompress(compressed)
        @test decompressed == transcode(ZstdDecompressor, compressed)
    end
end

@testset "Decompression Error Detection" begin
    fixtures_dir = joinpath(@__DIR__, "fixtures")

    # These invalid frames should be rejected by the decoder.
    # Marked as broken until error detection is implemented.
    @testset "Invalid offset 0" begin
        compressed = read(joinpath(fixtures_dir, "off0.bin.zst"))
        @test_broken try decompress(compressed); false catch; true end
    end

    @testset "Truncated Huffman state" begin
        compressed = read(joinpath(fixtures_dir, "truncated_huff_state.zst"))
        @test_broken try decompress(compressed); false catch; true end
    end

    @testset "Extraneous zero sequences" begin
        compressed = read(joinpath(fixtures_dir, "zeroSeq_extraneous.zst"))
        @test_broken try decompress(compressed); false catch; true end
    end
end

@testset "Checksum" begin
    # Verify checksum=true produces valid frames
    data = b"checksum test data for verification"
    comp = compress(data, checksum=true)
    @test decompress(comp) == data
    @test transcode(ZstdDecompressor, comp) == data

    # Large data with checksum
    data_large = rand(UInt8, 200 * 1024)
    comp_large = compress(data_large, checksum=true)
    @test decompress(comp_large) == data_large
    @test transcode(ZstdDecompressor, comp_large) == data_large
end

@testset "Cross-validation with libzstd" begin
    # Decompress libzstd-compressed data with our decompressor
    @testset "libzstd → Zstandard.jl ($label)" for (label, data) in [
        ("small text", Vector{UInt8}("The quick brown fox jumps over the lazy dog")),
        ("1KB random", rand(UInt8, 1024)),
        ("10KB repetitive", repeat(b"hello world ", 850)),
        ("256KB mixed", vcat(rand(UInt8, 128 * 1024), repeat(b"pattern!", 16 * 1024))),
    ]
        comp_lib = transcode(ZstdCompressor, data)
        @test decompress(comp_lib) == data
    end

    # Compress with us, decompress with libzstd
    @testset "Zstandard.jl → libzstd ($label)" for (label, data) in [
        ("single byte", UInt8[0x42]),
        ("255 bytes", rand(UInt8, 255)),
        ("256 bytes", rand(UInt8, 256)),
        ("1KB", rand(UInt8, 1024)),
        ("exactly 128KB", rand(UInt8, 128 * 1024)),
        ("128KB + 1", rand(UInt8, 128 * 1024 + 1)),
        ("256KB", rand(UInt8, 256 * 1024)),
    ]
        comp_jl = compress(data)
        @test transcode(ZstdDecompressor, comp_jl) == data
    end
end

@testset "Streaming Decompression" begin
    @testset "Byte-by-byte read" begin
        data = Vector{UInt8}("streaming byte by byte test")
        comp = compress(data)
        stream = Zstandard.ZstdDecompressorStream(IOBuffer(comp))
        result = UInt8[]
        while !eof(stream)
            push!(result, read(stream, UInt8))
        end
        @test result == data
    end

    @testset "Chunked readbytes!" begin
        data = repeat(b"chunked reads ", 500)
        comp = compress(data)
        stream = Zstandard.ZstdDecompressorStream(IOBuffer(comp))
        result = UInt8[]
        buf = Vector{UInt8}(undef, 100)
        while !eof(stream)
            n = readbytes!(stream, buf)
            append!(result, view(buf, 1:n))
        end
        @test result == data
    end

    @testset "read(stream, n)" begin
        data = rand(UInt8, 1000)
        comp = compress(data)
        stream = Zstandard.ZstdDecompressorStream(IOBuffer(comp))
        part1 = read(stream, 500)
        part2 = read(stream, 500)
        @test vcat(part1, part2) == data
    end

    @testset "Multi-block streaming" begin
        data = repeat(b"streaming multi-block ", 10000)  # > 128KB
        comp = compress(data)
        stream = Zstandard.ZstdDecompressorStream(IOBuffer(comp))
        result = read(stream)
        @test result == data
    end

    @testset "Concatenated frames" begin
        data1 = b"frame one"
        data2 = b"frame two"
        comp = vcat(compress(data1), compress(data2))
        stream = Zstandard.ZstdDecompressorStream(IOBuffer(comp))
        result = read(stream)
        @test result == vcat(data1, data2)
    end
end

@testset "Data Sizes up to 10MB" begin
    @testset "1MB repetitive" begin
        data = repeat(b"abcdefghijklmnop", 64 * 1024)  # 1 MB
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
        @test length(comp) < length(data) ÷ 100
    end

    @testset "1MB random" begin
        data = rand(UInt8, 1024 * 1024)
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
    end

    @testset "5MB text-like" begin
        # Simulate text with skewed byte distribution
        alphabet = Vector{UInt8}(" etaoinshrdlu\nThe quick brown fox")
        data = alphabet[rand(1:length(alphabet), 5 * 1024 * 1024)]
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
        @test length(comp) < length(data)
    end

    @testset "10MB repetitive" begin
        data = repeat(b"ABCDEFGH", 1280 * 1024)  # 10 MB
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
        @test length(comp) < 2048  # Should compress extremely well (some multi-block overhead)
    end

    @testset "10MB random" begin
        data = rand(UInt8, 10 * 1024 * 1024)
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
    end

    @testset "10MB mixed (compressible + random)" begin
        # First half repetitive, second half random
        data = vcat(
            repeat(b"compressible pattern data! ", 200 * 1024),
            rand(UInt8, 5 * 1024 * 1024)
        )
        # Trim/pad to exactly 10MB
        resize!(data, 10 * 1024 * 1024)
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
    end
end

@testset "Edge Cases" begin
    @testset "All byte values" begin
        data = UInt8.(0:255)
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
    end

    @testset "Single byte repeated" begin
        for byte in [0x00, 0x01, 0x7F, 0x80, 0xFF]
            data = fill(byte, 10000)
            comp = compress(data)
            @test decompress(comp) == data
            @test transcode(ZstdDecompressor, comp) == data
        end
    end

    @testset "Power-of-two sizes" begin
        for exp in [0, 1, 7, 8, 10, 15, 16, 17]
            n = 1 << exp
            data = rand(UInt8, n)
            comp = compress(data)
            @test decompress(comp) == data
            @test transcode(ZstdDecompressor, comp) == data
        end
    end

    @testset "Block boundary sizes" begin
        # Test around the 128KB block boundary
        for n in [128 * 1024 - 1, 128 * 1024, 128 * 1024 + 1,
                  256 * 1024 - 1, 256 * 1024, 256 * 1024 + 1]
            data = rand(UInt8, n)
            comp = compress(data)
            @test decompress(comp) == data
            @test transcode(ZstdDecompressor, comp) == data
        end
    end

    @testset "Overlapping matches (offset < match_length)" begin
        # Pattern where match copies overlap with themselves
        data = vcat(b"AB", repeat(b"A", 5000))
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
    end

    @testset "Long literal runs" begin
        # Random data followed by repetitive — forces long literal sequence
        data = vcat(rand(UInt8, 50000), repeat(b"x", 50000))
        comp = compress(data)
        @test decompress(comp) == data
        @test transcode(ZstdDecompressor, comp) == data
    end

    @testset "Compression levels" begin
        data = repeat(b"level test data ", 100)
        for level in [-3, -1, 0, 1, 2, 3]
            comp = compress(data, level=level)
            @test decompress(comp) == data
            @test transcode(ZstdDecompressor, comp) == data
        end
    end
end
