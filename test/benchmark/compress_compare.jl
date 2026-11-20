# Compression comparison on realistic data: Zstandard.jl vs libzstd (CodecZstd.jl).
#   julia --project=<env> test/benchmark/compress_compare.jl [--quick]
using Zstandard, CodecZstd, BenchmarkTools, Printf

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
    f = first(filter(f -> startswith(f, "libjulia-internal.so") && !islink(joinpath(libdir, f)), readdir(libdir)))
    return read(joinpath(libdir, f))
end

function main()
    seconds = "--quick" in ARGS ? 0.5 : 2.0
    text = corpus_text()[1:4<<20]
    bin = corpus_binary()
    println("Compression: ratio and throughput (MB/s of input, median)")
    println("-"^84)
    @printf("%-12s %5s | %8s %8s | %9s %9s | %8s\n", "Dataset", "level", "ratio jl", "ratio C", "MB/s jl", "MB/s C", "slowdown")
    println("-"^84)
    for (name, data) in (("text 4MB", text), ("binary", bin))
        for lvl in (1, 3, 6, 9, 16, 19)
            cj = compress(data; level=lvl)
            @assert transcode(ZstdDecompressor, cj) == data
            cc = transcode(ZstdCompressor(level=lvl), data)
            tj = median(run(@benchmarkable compress($data; level=$lvl) seconds=seconds samples=20)).time / 1e9
            tc = median(run(@benchmarkable transcode(ZstdCompressor(level=$lvl), $data) seconds=seconds samples=20)).time / 1e9
            mb = length(data) / 2^20
            @printf("%-12s %5d | %8.3f %8.3f | %9.1f %9.1f | %7.1fx\n", name, lvl,
                    length(data)/length(cj), length(data)/length(cc), mb/tj, mb/tc, tj/tc)
            GC.gc()
        end
    end
    println("-"^84)
end
main()
