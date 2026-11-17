# Decompression comparison: Zstandard.jl vs ZstdInflate.jl vs libzstd (CodecZstd.jl)
#
# Uses realistic corpora (Julia's own base/ sources and a shared library) compressed
# by libzstd at several levels, so that literals, Huffman tables and FSE sequence
# decoding are all exercised.
#
# Usage (needs an environment with Zstandard, ZstdInflate, CodecZstd, BenchmarkTools):
#   julia --project=<env> test/benchmark/inflate_compare.jl [--quick] [filter...]

using Zstandard, ZstdInflate, CodecZstd, BenchmarkTools, Printf

function corpus_text()
    base = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base")
    io = IOBuffer()
    for (root, _, files) in walkdir(base), f in sort(files)
        endswith(f, ".jl") && write(io, read(joinpath(root, f)))
    end
    return take!(io)
end

function corpus_binary()
    libdir = joinpath(Sys.BINDIR, Base.LIBDIR, "julia")
    cands = filter(f -> startswith(f, "libjulia-internal.so") && !islink(joinpath(libdir, f)), readdir(libdir))
    return read(joinpath(libdir, first(cands)))
end

function make_datasets()
    text = corpus_text()
    bin = corpus_binary()
    lz(d, lvl) = transcode(ZstdCompressor(level=lvl), d)
    return [
        ("text 64KB L3",   lz(text[1:64*1024], 3),  64*1024),
        ("text 4MB L1",    lz(text[1:4<<20], 1),    4<<20),
        ("text 4MB L3",    lz(text[1:4<<20], 3),    4<<20),
        ("text 4MB L19",   lz(text[1:4<<20], 19),   4<<20),
        ("binary L3",      lz(bin, 3),              length(bin)),
        ("text 4MB jl",    Zstandard.compress(text[1:4<<20]), 4<<20),
    ]
end

function parse_args(args)
    filter_args = String[]
    seconds = 2.0
    for arg in args
        arg == "--quick" ? (seconds = 0.5) : push!(filter_args, arg)
    end
    return (; filter = isempty(filter_args) ? nothing : filter_args, seconds)
end

function main()
    opts = parse_args(ARGS)
    datasets = make_datasets()
    if opts.filter !== nothing
        datasets = [d for d in datasets if any(f -> occursin(f, d[1]), opts.filter)]
    end
    println("Decompression throughput (MB/s of output, median), single thread")
    println("-"^78)
    @printf("%-14s | %7s | %10s %12s %10s | %8s\n", "Dataset", "ratio", "Zstd.jl", "ZstdInflate", "libzstd", "jl/Infl")
    println("-"^78)
    for (name, comp, n) in datasets
        ref = transcode(ZstdDecompressor, comp)
        @assert length(ref) == n
        Zstandard.decompress(comp) == ref || @warn "Zstandard.jl mismatch on $name"
        ZstdInflate.inflate_zstd(comp; nthreads=1) == ref || @warn "ZstdInflate mismatch on $name"
        mb = n / 2^20
        t(b) = median(b).time / 1e9
        t_jl  = t(run(@benchmarkable Zstandard.decompress($comp) seconds=opts.seconds))
        t_inf = t(run(@benchmarkable ZstdInflate.inflate_zstd($comp; nthreads=1) seconds=opts.seconds))
        t_lib = t(run(@benchmarkable transcode(ZstdDecompressor, $comp) seconds=opts.seconds))
        @printf("%-14s | %6.2f  | %10.1f %12.1f %10.1f | %7.2fx\n", name, n/length(comp),
                mb/t_jl, mb/t_inf, mb/t_lib, t_jl/t_inf)
    end
    println("-"^78)
end

main()
