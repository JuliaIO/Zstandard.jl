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
    allocs = false
    for arg in args
        if arg == "--allocs"
            allocs = true
        else
            push!(filter_args, arg)
        end
    end
    filter = isempty(filter_args) ? nothing : filter_args
    return (; filter, allocs)
end

function profile_compress(; filter::Union{Nothing,Vector{String}}=nothing, allocs::Bool=false)
    all_datasets = make_datasets()
    datasets = if filter !== nothing
        [(n, d) for (n, d) in all_datasets if any(f -> occursin(f, n), filter)]
    else
        all_datasets
    end

    for (name, data) in datasets
        # Warmup
        compress(data)
        compress(data)

        println("=== Profile: compress $name ($(length(data)) bytes) ===")
        if allocs
            Profile.Allocs.clear()
            Profile.Allocs.@profile sample_rate=1.0 compress(data)
            results = Profile.Allocs.fetch()
            # Group by type
            type_sizes = Dict{String, Tuple{Int,Int}}()  # type => (count, total_size)
            for alloc in results
                t = string(alloc.type)
                sz = alloc.size
                prev = get(type_sizes, t, (0, 0))
                type_sizes[t] = (prev[1] + 1, prev[2] + sz)
            end
            sorted = sort(collect(type_sizes), by=x -> x[2][2], rev=true)
            println("Top allocations by total size:")
            for (i, (t, (count, total))) in enumerate(sorted[1:min(15, length(sorted))])
                @printf("  %6d × %-40s = %8.1f KB\n", count, t, total / 1024)
            end
        else
            Profile.clear()
            @profile for _ in 1:100
                compress(data)
            end
            Profile.print(mincount=5, noisefloor=2.0, sortedby=:count)
        end
        println()
    end
end

function main()
    opts = parse_args(ARGS)
    profile_compress(; opts...)
end

main()
