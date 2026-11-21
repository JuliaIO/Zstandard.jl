# Compare XXH64 implementations: Zstandard.jl's native code, XXHashNative.jl,
# the reference C library (xxHash_jll), and ZstdInflate.jl's SIMD version
# when it is installed. Implementations are the adapters in
# test/xxhash_impls.jl; add one there to include it here.
#
# Run in an environment with the test dependencies and BenchmarkTools, e.g.
#   julia --project=test test/benchmark/xxhash_compare.jl [--quick]   (Julia >= 1.12 workspaces)
# or via TestEnv (`using TestEnv; TestEnv.activate()`) on Julia 1.11.

using BenchmarkTools, Printf
include(joinpath(@__DIR__, "..", "xxhash_impls.jl"))

impls = Pair{String,AbstractXXH64}[XXH64_IMPLEMENTATIONS...]

# Optional: ZstdInflate.jl (one-shot SIMD.jl XXH64 and a scalar streaming XXH64)
const HAS_ZSTDINFLATE = try
    @eval import ZstdInflate
    true
catch
    false
end
if HAS_ZSTDINFLATE
    @eval begin
        struct ZstdInflateXXH64 <: AbstractXXH64 end
        xxh64(::ZstdInflateXXH64, p::Ptr{UInt8}, n::Int, seed::UInt64) =
            ZstdInflate.xxhash64(unsafe_wrap(Array, p, n), seed)
        xxh64_init(::ZstdInflateXXH64, seed::UInt64) = ZstdInflate.XXH64Stream(seed)
        xxh64_update!(::ZstdInflateXXH64, st, p::Ptr{UInt8}, n::Int) =
            (ZstdInflate.xxh_update!(st, unsafe_wrap(Array, p, n)); st)
        xxh64_digest(::ZstdInflateXXH64, st) = ZstdInflate.xxh_finalize(st)
    end
    push!(impls, "ZstdInflate.jl" => ZstdInflateXXH64())
end

seconds = "--quick" in ARGS ? 0.3 : 1.5
mbs(bytes, t_ns) = bytes / t_ns * 1e9 / 2^20
best(b) = minimum(b).time

# Check that every implementation agrees before timing anything.
let x = rand(UInt8, 100_003), ref = hash_oneshot(LibXXH64(), x)
    for (name, impl) in impls
        hash_oneshot(impl, x) == ref || error("$name disagrees with the C library")
        hash_streaming(impl, x, (4096,)) == ref || error("$name (streaming) disagrees with the C library")
    end
end

w = maximum(length ∘ first, impls)
println("XXH64 one-shot (MB/s)")
sizes = (16, 100, 1024, 64 << 10, 16 << 20)
@printf("%-*s", w, ""); foreach(n -> @printf(" %10s", Base.format_bytes(n)), sizes); println()
for (name, impl) in impls
    @printf("%-*s", w, name)
    for n in sizes
        x = rand(UInt8, n)
        t = best(run(@benchmarkable hash_oneshot($impl, $x) seconds=seconds))
        @printf(" %10.0f", mbs(n, t))
    end
    println()
end

println("\nXXH64 streaming, 16 MiB in pieces of the given size (MB/s)")
pieces = (4096, 128 << 10)
@printf("%-*s", w, ""); foreach(n -> @printf(" %10s", Base.format_bytes(n)), pieces); println()
x = rand(UInt8, 16 << 20)
for (name, impl) in impls
    @printf("%-*s", w, name)
    for k in pieces
        t = best(run(@benchmarkable hash_streaming($impl, $x, ($k,)) seconds=seconds))
        @printf(" %10.0f", mbs(length(x), t))
    end
    println()
end

println("\nZstandard.jl with each implementation, 4 MiB checksummed frame (MB/s)")
data = repeat(Vector{UInt8}("The quick brown fox jumps over the lazy dog; " *
                            "pack my box with five dozen liquor jugs. "), 50_000)[1:4<<20]
frame = compress(data; checksum=true)
@printf("%-*s %12s %12s %12s\n", w, "", "decompress", "stream read", "compress L1")
for (name, impl) in impls
    Zstandard.with_xxh64_implementation(impl) do
        td = best(run(@benchmarkable decompress($frame) seconds=seconds))
        ts = best(run(@benchmarkable read(Zstandard.ZstandardDecompressorStream(IOBuffer($frame))) seconds=seconds))
        tc = best(run(@benchmarkable compress($data; level=1, checksum=true) seconds=seconds))
        @printf("%-*s %12.0f %12.0f %12.0f\n", w, name, mbs(length(data), td), mbs(length(data), ts),
                mbs(length(data), tc))
    end
end
