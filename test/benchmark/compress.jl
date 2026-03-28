using Zstandard, CodecZstd, BenchmarkTools, Printf

function bench_compress()
    datasets = [
        ("text 5KB",         Vector{UInt8}(repeat("hello world this is a test of huffman compression ", 100))),
        ("text 50KB",        Vector{UInt8}(repeat("the quick brown fox jumps over the lazy dog ", 1200))),
        ("repetitive 160KB", repeat(b"abcdefgh", 20 * 1024)),
        ("repetitive 1MB",   repeat(b"abcdefghijklmnop", 64 * 1024)),
        ("random 1MB",       rand(UInt8, 1024 * 1024)),
    ]

    println("Compression throughput (MB/s, median):")
    println("-"^68)
    @printf("%-22s | %10s %10s | %8s %8s\n", "Dataset", "Zstd.jl", "libzstd", "Slowdown", "Ratio")
    println("-"^68)
    for (name, data) in datasets
        sz_mb = length(data) / (1024 * 1024)
        b_jl  = @benchmark compress($data) seconds=3
        b_lib = @benchmark transcode(ZstdCompressor, $data) seconds=3
        comp_jl = compress(data)
        comp_lib = transcode(ZstdCompressor, data)
        ratio_jl = length(data) / length(comp_jl)
        ratio_lib = length(data) / length(comp_lib)
        t_jl  = median(b_jl).time / 1e9
        t_lib = median(b_lib).time / 1e9
        @printf("%-22s | %8.2f   %8.2f   | %6.1fx  %4.1f/%4.1f\n", name, sz_mb/t_jl, sz_mb/t_lib, t_jl/t_lib, ratio_jl, ratio_lib)
    end
    println("-"^68)
end

bench_compress()
