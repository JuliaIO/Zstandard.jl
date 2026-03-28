using Zstandard, Profile, Printf

function make_datasets()
    return [
        ("text 5KB",         Vector{UInt8}(repeat("hello world this is a test of huffman compression ", 100))),
        ("text 50KB",        Vector{UInt8}(repeat("the quick brown fox jumps over the lazy dog ", 1200))),
        ("repetitive 160KB", repeat(b"abcdefgh", 20 * 1024)),
        ("repetitive 1MB",   repeat(b"abcdefghijklmnop", 64 * 1024)),
        ("random 1MB",       rand(UInt8, 1024 * 1024)),
    ]
end

function parse_args(args)
    filter_args = String[]
    for arg in args
        push!(filter_args, arg)
    end
    filter = isempty(filter_args) ? nothing : filter_args
    return (; filter,)
end

function profile_decompress(; filter::Union{Nothing,Vector{String}}=nothing)
    all_datasets = make_datasets()
    datasets = if filter !== nothing
        [(n, d) for (n, d) in all_datasets if any(f -> occursin(f, n), filter)]
    else
        all_datasets
    end

    for (name, data) in datasets
        comp = compress(data)

        # Warmup
        decompress(comp)
        decompress(comp)

        n_iters = max(10, div(100_000_000, length(data)))  # ~100MB total work
        println("=== Profile: decompress $name ($(length(comp)) → $(length(data)) bytes, $n_iters iters) ===")
        Profile.clear()
        @profile for _ in 1:n_iters
            decompress(comp)
        end
        Profile.print(mincount=5, noisefloor=2.0, sortedby=:count)
        println()
    end
end

function main()
    opts = parse_args(ARGS)
    profile_decompress(; opts...)
end

main()
