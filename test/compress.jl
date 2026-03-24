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
