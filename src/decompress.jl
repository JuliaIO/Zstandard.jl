# One-shot decompression: `decompress`, with parallel decoding of concatenated frames.
# Included in module Zstandard.

# Inputs smaller than this are always decoded on one thread.
const PARALLEL_DECODE_MIN = 1 << 17

# Frames smaller than this on average are decoded serially: per-frame
# overhead would outweigh the parallelism.
const PARALLEL_DECODE_MIN_FRAME = 1 << 12

# Split `src` into runs of whole frames of roughly equal compressed size, or
# return nothing if there are fewer than two chunks worth splitting, the
# frames are tiny, or the scan fails (the serial decoder then reports the
# error at the right place).
function _frame_chunks(src::Vector{UInt8}, nchunks::Int)
    bounds = Int[]
    pos = 1
    try
        while pos <= length(src)
            push!(bounds, pos)
            pos += frame_compressed_size(src; offset=pos)
            # give up early on many tiny frames
            length(bounds) >= 64 && pos - 1 < length(bounds) * PARALLEL_DECODE_MIN_FRAME && return nothing
        end
    catch e
        e isa ZstdError || rethrow()
        return nothing
    end
    length(bounds) < 2 && return nothing
    push!(bounds, length(src) + 1)
    target = cld(length(src), nchunks)
    chunks = UnitRange{Int}[]
    start = 1
    for i in 2:length(bounds)
        if bounds[i] - start >= target || i == length(bounds)
            push!(chunks, start:bounds[i]-1)
            start = bounds[i]
        end
    end
    # A small remainder (say, a trailing index or metadata frame) joins the
    # previous chunk: as a chunk of its own it gains nothing and costs an
    # extra output buffer and copy.
    if length(chunks) >= 2 && length(chunks[end]) < target
        tail = pop!(chunks)
        chunks[end] = first(chunks[end]):tail.stop
    end
    return length(chunks) < 2 ? nothing : chunks
end

function _decompress_parallel(src::Vector{UInt8}, dict, chunks::Vector{UnitRange{Int}}, nthreads::Int)
    sem = Base.Semaphore(nthreads)
    tasks = map(chunks) do r
        Threads.@spawn Base.acquire(sem) do
            _with_state(st -> decompress_frames(src, st, dict; range=r))
        end
    end
    parts = map(tasks) do t
        try
            fetch(t)
        catch e
            e isa TaskFailedException ? e.task.exception : rethrow()
        end
    end
    for p in parts
        p isa Exception && throw(p)
    end
    out = Vector{UInt8}(undef, sum(length, parts))
    pos = 1
    for p in parts
        copyto!(out, pos, p, 1, length(p))
        pos += length(p)
    end
    return out
end

"""
    decompress(data::AbstractVector{UInt8}, dict=nothing; nthreads=Threads.nthreads())

Decompress Zstandard compressed data, which may contain several concatenated
and/or skippable frames. Optionally, a `ZstdDictionary` can be provided, or
several (a [`ZstdDictionarySet`](@ref) or a vector of `ZstdDictionary`) for
data whose frames use different dictionaries, each chosen by the dictionary ID
in the frame header.
Throws a [`ZstdError`](@ref) if the data is malformed.

When `data` holds several frames (at least $(PARALLEL_DECODE_MIN ÷ 1024) KiB in
total), they are decoded in parallel on up to `nthreads` tasks; a single frame
is always decoded on one thread. The result does not depend on `nthreads`.

With `magicless=true`, frames are read without magic numbers (as written by
`compress(data; magicless=true)`); skippable frames cannot occur then. With
`prefix = bytes`, frames written with that reference prefix are decoded (see
`compress`).
"""
function decompress(data::AbstractVector{UInt8},
                    dict::DictArg=nothing;
                    nthreads::Integer=Threads.nthreads(), magicless::Bool=false,
                    prefix::Union{Nothing,AbstractVector{UInt8}}=nothing)
    nthreads < 1 && throw(ArgumentError("nthreads must be at least 1"))
    dict = Encoder.prefix_dict(prefix, decode_dict(dict))
    magicless && return _with_state(st -> decompress_frames(data, st, dict; magicless))
    if nthreads > 1 && length(data) >= PARALLEL_DECODE_MIN
        src = data isa Vector{UInt8} ? data : Vector{UInt8}(data)
        chunks = _frame_chunks(src, 4 * Int(nthreads))
        chunks === nothing || return _decompress_parallel(src, dict, chunks, Int(nthreads))
        return _with_state(st -> decompress_frames(src, st, dict))
    end
    return _with_state(st -> decompress_frames(data, st, dict))
end
