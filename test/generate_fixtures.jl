using CodecZstd
using Test

function generate_fixtures()
    fixtures_dir = joinpath(@__DIR__, "fixtures")
    mkpath(fixtures_dir)

    # 1. Simple "Hello, Zstd!" message
    data1 = "Hello, Zstd!"
    open(joinpath(fixtures_dir, "hello.zst"), "w") do io
        write(io, transcode(ZstdCompressor, data1))
    end
    open(joinpath(fixtures_dir, "hello.txt"), "w") do io
        write(io, data1)
    end

    # 2. Large repetetive data
    data2 = "abc" ^ 1000
    open(joinpath(fixtures_dir, "repetitive.zst"), "w") do io
        write(io, transcode(ZstdCompressor, data2))
    end
    open(joinpath(fixtures_dir, "repetitive.txt"), "w") do io
        write(io, data2)
    end

    # 3. Empty file
    data3 = ""
    open(joinpath(fixtures_dir, "empty.zst"), "w") do io
        write(io, transcode(ZstdCompressor, data3))
    end
    open(joinpath(fixtures_dir, "empty.txt"), "w") do io
        write(io, data3)
    end
    
    # 4. Large zeros (RLE)
    data4 = fill(UInt8(0), 1000)
    open(joinpath(fixtures_dir, "zeros.zst"), "w") do io
        write(io, transcode(ZstdCompressor, data4))
    end
    open(joinpath(fixtures_dir, "zeros.txt"), "w") do io
        write(io, data4)
    end

    # 5. Multi-frame
    data5_1 = "Frame 1"
    data5_2 = "Frame 2"
    open(joinpath(fixtures_dir, "multi_frame.zst"), "w") do io
        write(io, transcode(ZstdCompressor, data5_1))
        write(io, transcode(ZstdCompressor, data5_2))
    end
    open(joinpath(fixtures_dir, "multi_frame.txt"), "w") do io
        write(io, data5_1 * data5_2)
    end
    
    # 6. Random data (Huffman)
    data6 = join(rand('a':'z', 200))
    open(joinpath(fixtures_dir, "random.zst"), "w") do io
        write(io, transcode(ZstdCompressor, data6))
    end
    open(joinpath(fixtures_dir, "random.txt"), "w") do io
        write(io, data6)
    end

    # 7. Mixed data (Huffman + Sequences)
    data7 = "The quick brown fox jumps over the lazy dog. " ^ 20
    open(joinpath(fixtures_dir, "mixed.zst"), "w") do io
        write(io, transcode(ZstdCompressor, data7))
    end
    open(joinpath(fixtures_dir, "mixed.txt"), "w") do io
        write(io, data7)
    end
    
    # 8. Dictionary (Raw)
    dict_data = "This is a dictionary content. " ^ 10
    data8 = "This is a dictionary content. " * "Some extra data."
    dict_path = joinpath(fixtures_dir, "raw.dict")
    write(dict_path, dict_data)
    
    # Use CLI to compress with dictionary
    run(`zstd -f -D $dict_path -o $(joinpath(fixtures_dir, "dict.zst")) $(joinpath(fixtures_dir, "hello.txt"))`)
    # Actually let's compress something that uses the dictionary
    open(joinpath(fixtures_dir, "use_dict.txt"), "w") do io
        write(io, data8)
    end
    run(`zstd -f -D $dict_path -o $(joinpath(fixtures_dir, "use_dict.zst")) $(joinpath(fixtures_dir, "use_dict.txt"))`)

    # 9. Use zstd CLI for comparison
    run(`zstd -f -o $(joinpath(fixtures_dir, "hello_cli.zst")) $(joinpath(fixtures_dir, "hello.txt"))`)
end

if abspath(PROGRAM_FILE) == @__FILE__
    generate_fixtures()
end
