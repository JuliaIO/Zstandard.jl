using Zstandard, CodecZstd, Printf

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
    verbose = false
    for arg in args
        if arg == "--verbose" || arg == "-v"
            verbose = true
        else
            push!(filter_args, arg)
        end
    end
    filter = isempty(filter_args) ? nothing : filter_args
    return (; filter, verbose)
end

function analyze_sequences(data::Vector{UInt8})
    seqs = Zstandard.MatchFinder.find_sequences(data)
    n_seqs = count(s -> s.match_length > 0, seqs)
    total_ll = sum(Int(s.literal_length) for s in seqs)
    total_ml = sum(Int(s.match_length) for s in seqs)
    avg_ml = n_seqs > 0 ? total_ml / n_seqs : 0.0
    max_ml = n_seqs > 0 ? maximum(Int(s.match_length) for s in seqs if s.match_length > 0) : 0

    # Count repeat offset opportunities
    rep_offsets = [1, 4, 8]
    n_rep = 0
    for s in seqs
        s.match_length == 0 && continue
        off = Int(s.offset)
        ll = Int(s.literal_length)
        if ll > 0
            if off == rep_offsets[1] || off == rep_offsets[2] || off == rep_offsets[3]
                n_rep += 1
            end
        else
            if off == rep_offsets[2] || off == rep_offsets[3] || (rep_offsets[1] > 1 && off == rep_offsets[1] - 1)
                n_rep += 1
            end
        end
        # Update rep_offsets (simplified — doesn't track actual encoder state)
        if off != rep_offsets[1] && off != rep_offsets[2] && off != rep_offsets[3]
            rep_offsets[3] = rep_offsets[2]; rep_offsets[2] = rep_offsets[1]; rep_offsets[1] = off
        end
    end

    return (; n_seqs, total_ll, total_ml, avg_ml, max_ml, n_rep, seqs)
end

function bench_ratio(; filter::Union{Nothing,Vector{String}}=nothing, verbose::Bool=false)
    all_datasets = make_datasets()
    datasets = if filter !== nothing
        [(n, d) for (n, d) in all_datasets if any(f -> occursin(f, n), filter)]
    else
        all_datasets
    end

    println("Compression ratio analysis:")
    println("-"^90)
    @printf("%-22s | %8s %8s %8s | %6s %6s %6s %6s\n",
        "Dataset", "Zstd.jl", "libzstd", "Gap", "Seqs", "AvgML", "MaxML", "RepOff")
    println("-"^90)
    for (name, data) in datasets
        comp_jl = Zstandard.compress(data)
        comp_lib = transcode(ZstdCompressor, data)
        ratio_jl = length(data) / length(comp_jl)
        ratio_lib = length(data) / length(comp_lib)
        gap = ratio_lib / ratio_jl

        stats = analyze_sequences(data)

        @printf("%-22s | %6.1f:1 %6.1f:1 %6.1fx | %6d %6.1f %6d %5d\n",
            name, ratio_jl, ratio_lib, gap,
            stats.n_seqs, stats.avg_ml, stats.max_ml, stats.n_rep)

        if verbose
            println("  First 10 sequences:")
            for (i, s) in enumerate(stats.seqs[1:min(10, length(stats.seqs))])
                @printf("    %3d: ll=%d ml=%d off=%d\n", i, s.literal_length, s.match_length, s.offset)
            end
        end
    end
    println("-"^90)
end

function main()
    opts = parse_args(ARGS)
    bench_ratio(; opts...)
end

main()
