module Zstandard

export decompress, compress, ZstdDecompressorStream, ZstdCompressorStream, ZstdDictionary,
       parse_dictionary, ZstdError, ZstandardCompressor, ZstandardDecompressor,
       ZstdFrameHeader, frame_header, frame_content_size, frame_compressed_size, frame_dict_id,
       decompressed_size, is_zstd_frame, is_skippable_frame, skippable_frame, read_skippable_frame,
       train_dictionary, finalize_dictionary, PreparedDictionary, prepare_dictionary,
       ZstdCompressionContext, ZstdDecompressionContext, compress!, decompress!,
       compress_seekable, ZstdSeekTable, seek_table, decompress_range,
       estimate_compression_memory, estimate_decompression_memory, stream_progress,
       ZstdSequence, generate_sequences, compress_sequences

# Swappable XXH64 implementation for frame checksums (see `Zstandard.XXHash`)
public XXHash, AbstractXXH64, NativeXXH64, XXH64_IMPLEMENTATION, with_xxh64_implementation

const MAGIC_NUMBER = 0xFD2FB528
const SKIPPABLE_MAGIC_START = 0x184D2A50
const SKIPPABLE_MAGIC_END   = 0x184D2A5F

include("xxhash.jl")

include("decoder.jl")
using .Decoder: ZstdError, ZstdDictionary, parse_dictionary, DecoderState, decompress_frames

include("frameinfo.jl")

include("encoder.jl")
using .Encoder: CompressionContext, compress_frame!, mt_layout, compress_job!, frame_header_bytes,
                train_dictionary, finalize_dictionary, PreparedDictionary, prepare_dictionary
using .XXHash: content_checksum, AbstractXXH64, NativeXXH64, XXH64_IMPLEMENTATION, with_xxh64_implementation

include("streaming.jl")
using .Streaming: ZstdDecompressorStream, ZstdCompressorStream, stream_progress

"""
    ZstandardCompressor(; level=3, checksum=false, dict=nothing, window_log=nothing, ...)

A [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl) codec
compressing to the Zstandard format, for use with `transcode`,
`TranscodingStream`, etc. Available once `TranscodingStreams` is loaded.
Accepts the parameter and frame keywords of [`compress`](@ref) (`window_log`,
..., `content_size`, `dict_id`, `magicless`), and `size_hint` (see
`ZstdCompressorStream`) for streams whose size is not pledged.

TranscodingStreams does not pass `flush` on to codecs, so flushing a
`TranscodingStream` does not make the data written so far decodable; write
`TranscodingStreams.TOKEN_END` to end the frame, or use `ZstdCompressorStream`,
whose `flush` emits a block that decoders can read before the frame ends.

```julia
using Zstandard, TranscodingStreams
compressed = transcode(ZstandardCompressor(level=5), data)
stream = TranscodingStream(ZstandardCompressor(), open("out.zst", "w"))
```
"""
function ZstandardCompressor end

"""
    ZstandardDecompressor(; dict=nothing, max_window_size=128 MiB, magicless=false)

A [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl) codec
decoding Zstandard data (concatenated and skippable frames included). Frames
with a window larger than `max_window_size` are rejected (see
`ZstdDecompressorStream`). With `magicless=true`, frames have no magic
numbers (see `compress`).
Available once `TranscodingStreams` is loaded.
"""
function ZstandardDecompressor end

function __init__()
    if isdefined(Base.Experimental, :register_error_hint)
        Base.Experimental.register_error_hint(MethodError) do io, exc, argtypes, kwargs
            if (exc.f === ZstandardCompressor || exc.f === ZstandardDecompressor) &&
               Base.get_extension(@__MODULE__, :ZstandardTranscodingStreamsExt) === nothing
                print(io, "\n$(exc.f) requires TranscodingStreams.jl; run `using TranscodingStreams` first.")
            end
        end
    end
end

# Pool of reusable decoder scratch states (~150KB each), so that repeated
# `decompress` calls do not reallocate them. Safe for concurrent use.
const _STATE_LOCK = ReentrantLock()
const _STATE_POOL = DecoderState[]

function _with_state(f)
    st = lock(_STATE_LOCK) do
        isempty(_STATE_POOL) ? DecoderState() : pop!(_STATE_POOL)
    end
    try
        return f(st)
    finally
        lock(_STATE_LOCK) do
            push!(_STATE_POOL, st)
        end
    end
end

const _CCTX_LOCK = ReentrantLock()
const _CCTX_POOL = CompressionContext[]

function _with_cctx(f)
    cc = lock(_CCTX_LOCK) do
        isempty(_CCTX_POOL) ? CompressionContext() : pop!(_CCTX_POOL)
    end
    try
        return f(cc)
    finally
        lock(_CCTX_LOCK) do
            push!(_CCTX_POOL, cc)
        end
    end
end

# Positions are stored as Int32 in the match finder tables.
const MAX_FRAME_INPUT = 1 << 30

# Compress one frame with jobs spread over up to `nthreads` tasks.
# rsyncable job boundaries (libzstd's ZSTDMT findSynchronizationPoint): a job
# ends after a byte where the rolling hash of the last 32 bytes hits a mask
# sized for the target job size, but never within 128 KiB of its start, and
# at the target size at the latest. Boundaries then depend only on nearby
# content, so a local change leaves the rest of the output unchanged.
const RSYNC_LENGTH = 32
const RSYNC_MIN_BLOCK = 1 << 17
const RSYNC_PRIME = 0xCF1BBCDCB7A56463
const RSYNC_CHAR_OFFSET = 10

function _rsync_jobs(data::Vector{UInt8}, job::Int)
    n = length(data)
    bits = 63 - leading_zeros(UInt64(max(job >> 10, 1))) + 10
    mask = (UInt64(1) << bits) - 1
    pp = UInt64(1)
    for _ in 1:RSYNC_LENGTH-1; pp *= RSYNC_PRIME; end
    ranges = UnitRange{Int}[]
    s = 1
    @inbounds while s <= n
        e = min(s + job - 1, n)
        if e - s + 1 > RSYNC_MIN_BLOCK
            # hash of the 32 bytes ending at s + RSYNC_MIN_BLOCK - 1, then roll
            q = s + RSYNC_MIN_BLOCK - 1
            h = UInt64(0)
            for i in q-RSYNC_LENGTH+1:q
                h = h * RSYNC_PRIME + (data[i] + RSYNC_CHAR_OFFSET)
            end
            # libzstd tests positions after the first 128 KiB of the job
            while q < e
                q += 1
                h -= (data[q - RSYNC_LENGTH] + RSYNC_CHAR_OFFSET) * pp
                h = h * RSYNC_PRIME + (data[q] + RSYNC_CHAR_OFFSET)
                if h & mask == mask
                    e = q
                    break
                end
            end
        end
        push!(ranges, s:e)
        s = e + 1
    end
    return ranges
end

function _compress_mt(data::Vector{UInt8}, level::Integer, checksum::Bool, nthreads::Int,
                      params=Encoder.NO_OVERRIDES, frame=Encoder.DEFAULT_FRAME, rsyncable::Bool=false)
    n = length(data)
    p, job, overlap = mt_layout(n, level, params)
    ranges = rsyncable ? _rsync_jobs(data, job) : [((j - 1) * job + 1):min(j * job, n) for j in 1:cld(n, job)]
    njobs = length(ranges)
    sem = Base.Semaphore(nthreads)
    tasks = map(1:njobs) do j
        js = first(ranges[j]); je = last(ranges[j])
        Threads.@spawn Base.acquire(sem) do
            _with_cctx(cc -> compress_job!(cc, p, level, data, js, je, overlap, j == njobs))
        end
    end
    parts = Vector{UInt8}[fetch(t) for t in tasks]
    njobs == 0 && push!(parts, UInt8[0x01, 0x00, 0x00])      # empty input: one empty last block
    out = frame_header_bytes(n, p, checksum, frame)
    sizehint!(out, length(out) + sum(length, parts) + 4)
    foreach(x -> append!(out, x), parts)
    if checksum
        h = content_checksum(data)
        for k in 0:3
            push!(out, (h >> (8k)) % UInt8)
        end
    end
    return out
end

"""
    compress(data; level=3, checksum=false, dict=nothing, nthreads=1, long=false,
             content_size=true, dict_id=true, magicless=false, prefix=nothing, rsyncable=false,
             target_block_size=nothing,
             window_log, hash_log, chain_log, search_log, min_match, target_length, strategy)
        -> Vector{UInt8}

Compress `data` (a byte vector or string) into a Zstandard frame.

`level` ranges from $(Encoder.MIN_LEVEL) (fastest) to $(Encoder.MAX_LEVEL) (strongest);
`0` selects the default level 3, as in libzstd. With `checksum=true` an XXH64
content checksum is appended. With a `ZstdDictionary`, its content serves as
history and, for formatted dictionaries, its entropy tables and repeat offsets
are used; the frame records the dictionary ID. When compressing many small
inputs with one dictionary, pass a [`PreparedDictionary`](@ref) from
[`prepare_dictionary`](@ref) instead: it is much faster, and its level is then
used (a conflicting `level` throws an `ArgumentError`). Inputs larger than
1 GiB are written as several concatenated frames.

The remaining keywords override individual parameters of the level, with the
meaning of libzstd's advanced parameters (`ZSTD_c_windowLog` etc.); see
[`Zstandard.Encoder.parameter_overrides`](@ref). For example,
`compress(data; level=19, window_log=24)` searches matches up to 16 MiB back.
A `window_log` above 27 makes frames that streaming decoders reject by default
(here and in libzstd): decode them with `max_window_size` set, as libzstd's
`--long=N`, or one-shot with `decompress`.

With `nthreads > 1`, inputs larger than a few window sizes are split into
jobs compressed in parallel tasks (within a single frame, as libzstd's
`nbWorkers`); start Julia with several threads (`julia -t N`) to benefit.
The output differs slightly from single-threaded compression. Not combined with
`dict` or `long` (those always run on one thread).

With `long=true`, long-distance matching finds repetitions up to 128 MiB
apart (as `zstd --long`); the frame then declares a window of up to 128 MiB,
which decoders must be willing to allocate.

With `target_block_size = n` (1340 to 131072; libzstd's
`ZSTD_c_targetCBlockSize`), blocks are split so that each compressed block is
about `n` bytes, which lets a streaming decoder start on each sooner (lower
latency, slightly lower ratio). Not applied to multithreaded jobs.

With `rsyncable=true` (as `zstd --rsyncable`), the input is cut into jobs at
content-defined points (as libzstd's `ZSTD_c_rsyncable`): each job starts
with fresh repeat offsets and entropy tables, so a local change to the input
changes the output only near it, and rsync-style tools can transfer the
difference efficiently. The ratio is slightly lower. Jobs run in parallel
with `nthreads > 1`.

With `prefix = bytes`, those bytes serve as history the data may refer to
(libzstd's `ZSTD_CCtx_refPrefix`, as `zstd --patch-from`): the frame records
nothing about them, and must be decoded with the same prefix
(`decompress(frame; prefix=bytes)`). Unless `window_log` is given, the window
is widened to reach back into the whole prefix (up to 128 MiB); combine with
`long=true` for large inputs. Not combined with `dict`.

Frame header options (libzstd's `ZSTD_c_contentSizeFlag`, `ZSTD_c_dictIDFlag`
and `ZSTD_f_zstd1_magicless`): `content_size=false` leaves the content size
out of the header, `dict_id=false` the dictionary ID (the decoder must then be
given the right dictionary), and `magicless=true` omits the 4-byte magic
number; such frames are decoded with `decompress(data; magicless=true)`.
"""
function compress(data::AbstractVector{UInt8}; level::Union{Nothing,Integer}=nothing,
                  checksum::Bool=false, dict::Union{Nothing,ZstdDictionary,PreparedDictionary}=nothing,
                  nthreads::Integer=1, long::Bool=false,
                  content_size::Bool=true, dict_id::Bool=true, magicless::Bool=false,
                  prefix::Union{Nothing,AbstractVector{UInt8}}=nothing, rsyncable::Bool=false,
                  target_block_size::Union{Nothing,Integer}=nothing,
                  window_log=nothing, hash_log=nothing, chain_log=nothing, search_log=nothing, min_match=nothing, target_length=nothing, strategy=nothing)
    nthreads < 1 && throw(ArgumentError("nthreads must be at least 1"))
    params = Encoder.parameter_overrides(; window_log, hash_log, chain_log, search_log, min_match, target_length, strategy)
    dict = Encoder.prefix_dict(prefix, dict)
    params = Encoder.prefix_params(params, prefix, level, min(length(data), MAX_FRAME_INPUT))
    frame = Encoder.FrameOptions(; content_size, dict_id, magicless, target_block_size)
    if dict isa PreparedDictionary
        Encoder.use_prepared(dict, 0, level, params)     # checks level and parameters
        level = dict.level
    end
    level = level === nothing ? 3 : Int(level)
    if rsyncable
        (dict !== nothing || long) && throw(ArgumentError("rsyncable cannot be combined with dict, prefix or long"))
        length(data) > MAX_FRAME_INPUT && throw(ArgumentError("rsyncable inputs are limited to 1 GiB"))
        return _compress_mt(data isa Vector{UInt8} ? data : Vector{UInt8}(data), level, checksum,
                            Int(nthreads), params, frame, true)
    end
    if nthreads > 1 && dict === nothing && !long && length(data) <= MAX_FRAME_INPUT
        _, job, _ = mt_layout(length(data), level, params)
        if length(data) > job
            return _compress_mt(data isa Vector{UInt8} ? data : Vector{UInt8}(data), level, checksum,
                                Int(nthreads), params, frame)
        end
    end
    _with_cctx() do cc
        if length(data) <= MAX_FRAME_INPUT
            return compress_frame!(cc, data, level; checksum, dict, long, params, frame)
        end
        out = UInt8[]
        for off in 0:MAX_FRAME_INPUT:length(data)-1
            chunk = view(data, off+1:min(off + MAX_FRAME_INPUT, length(data)))
            append!(out, compress_frame!(cc, chunk, level; checksum, dict, long, params, frame))
        end
        return out
    end
end
compress(data::AbstractString; kwargs...) = compress(codeunits(data); kwargs...)

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
    decompress(data::AbstractVector{UInt8}, dict::Union{Nothing, ZstdDictionary}=nothing;
               nthreads=Threads.nthreads())

Decompress Zstandard compressed data, which may contain several concatenated
and/or skippable frames. Optionally, a `ZstdDictionary` can be provided.
Throws a [`ZstdError`](@ref) if the data is malformed.

When `data` holds several frames (at least $(PARALLEL_DECODE_MIN ÷ 1024) KiB in
total), they are decoded in parallel on up to `nthreads` tasks; a single frame
is always decoded on one thread. The result does not depend on `nthreads`.

With `magicless=true`, frames are read without magic numbers (as written by
`compress(data; magicless=true)`); skippable frames cannot occur then. With
`prefix = bytes`, frames written with that reference prefix are decoded (see
`compress`).
"""
function decompress(data::AbstractVector{UInt8}, dict::Union{Nothing, ZstdDictionary}=nothing;
                    nthreads::Integer=Threads.nthreads(), magicless::Bool=false,
                    prefix::Union{Nothing,AbstractVector{UInt8}}=nothing)
    nthreads < 1 && throw(ArgumentError("nthreads must be at least 1"))
    dict = Encoder.prefix_dict(prefix, dict)
    magicless && return _with_state(st -> decompress_frames(data, st, dict; magicless))
    if nthreads > 1 && length(data) >= PARALLEL_DECODE_MIN
        src = data isa Vector{UInt8} ? data : Vector{UInt8}(data)
        chunks = _frame_chunks(src, 4 * Int(nthreads))
        chunks === nothing || return _decompress_parallel(src, dict, chunks, Int(nthreads))
        return _with_state(st -> decompress_frames(src, st, dict))
    end
    return _with_state(st -> decompress_frames(data, st, dict))
end

include("context.jl")
include("seekable.jl")
include("estimate.jl")
include("sequences.jl")
include("precompile.jl")

end # module
