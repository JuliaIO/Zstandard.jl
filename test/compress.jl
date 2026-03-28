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
