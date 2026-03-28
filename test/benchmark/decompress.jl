using Zstandard, CodecZstd, BenchmarkTools, Printf

function bench_decompress()
    datasets = [
        ("text 5KB",         Vector{UInt8}(repeat("hello world this is a test of huffman compression ", 100))),
        ("text 50KB",        Vector{UInt8}(repeat("the quick brown fox jumps over the lazy dog ", 1200))),
        ("repetitive 160KB", repeat(b"abcdefgh", 20 * 1024)),
        ("repetitive 1MB",   repeat(b"abcdefghijklmnop", 64 * 1024)),
        ("random 1MB",       rand(UInt8, 1024 * 1024)),
    ]

    println("Decompression throughput (MB/s, median):")
    println("-"^68)
    @printf("%-22s | %10s %10s | %8s %8s\n", "Dataset", "Zstd.jl", "libzstd", "Slowdown", "Ratio")
    println("-"^68)
    for (name, data) in datasets
        sz_mb = length(data) / (1024 * 1024)
        comp = compress(data)
        ratio = length(data) / length(comp)
        b_jl  = @benchmark decompress($comp) seconds=3
        b_lib = @benchmark transcode(ZstdDecompressor, $comp) seconds=3
        t_jl  = median(b_jl).time / 1e9
        t_lib = median(b_lib).time / 1e9
        @printf("%-22s | %8.2f   %8.2f   | %6.1fx  %6.1f:1\n", name, sz_mb/t_jl, sz_mb/t_lib, t_jl/t_lib, ratio)
    end
    println("-"^68)
end

bench_decompress()
