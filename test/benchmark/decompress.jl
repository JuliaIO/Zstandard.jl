using Zstandard, CodecZstd, BenchmarkTools, Printf

const ALL_DATASETS = [
    ("text 5KB",         Vector{UInt8}(repeat("hello world this is a test of huffman compression ", 100))),
    ("text 50KB",        Vector{UInt8}(repeat("the quick brown fox jumps over the lazy dog ", 1200))),
    ("repetitive 160KB", repeat(b"abcdefgh", 20 * 1024)),
    ("repetitive 1MB",   repeat(b"abcdefghijklmnop", 64 * 1024)),
    ("random 1MB",       rand(UInt8, 1024 * 1024)),
]

function bench_decompress(; filter::Union{Nothing,Vector{String}}=nothing, seconds=3)
    datasets = if filter !== nothing
        [(n, d) for (n, d) in ALL_DATASETS if any(f -> occursin(f, n), filter)]
    else
        ALL_DATASETS
    end

    println("Decompression throughput (MB/s, median):")
    println("-"^68)
    @printf("%-22s | %10s %10s | %8s %8s\n", "Dataset", "Zstd.jl", "libzstd", "Slowdown", "Ratio")
    println("-"^68)
    for (name, data) in datasets
        sz_mb = length(data) / (1024 * 1024)
        comp = compress(data)
        ratio = length(data) / length(comp)
        b_jl  = run(@benchmarkable decompress($comp) seconds=seconds)
        b_lib = run(@benchmarkable transcode(ZstdDecompressor, $comp) seconds=seconds)
        t_jl  = median(b_jl).time / 1e9
        t_lib = median(b_lib).time / 1e9
        @printf("%-22s | %8.2f   %8.2f   | %6.1fx  %6.1f:1\n", name, sz_mb/t_jl, sz_mb/t_lib, t_jl/t_lib, ratio)
    end
    println("-"^68)
end

let
    filter_args = String[]
    seconds = 3
    for arg in ARGS
        if arg == "--quick"
            seconds = 1
        else
            push!(filter_args, arg)
        end
    end
    bench_decompress(filter=isempty(filter_args) ? nothing : filter_args, seconds=seconds)
end
