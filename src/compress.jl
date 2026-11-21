# One-shot compression: `compress`, multithreaded jobs and rsyncable job boundaries.
# Included in module Zstandard.

# Positions are stored as Int32 in the match finder tables.
const MAX_FRAME_INPUT = 1 << 30

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

# Compress one frame with jobs spread over up to `nthreads` tasks.
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
content checksum is appended. With a `ZstandardDictionary`, its content serves as
history and, for formatted dictionaries, its entropy tables and repeat offsets
are used; the frame records the dictionary ID. When compressing many small
inputs with one dictionary, pass a [`PreparedDictionary`](@ref) from
[`prepare_dictionary`](@ref) instead: it is much faster, and its level is then
used (a conflicting `level` throws an `ArgumentError`). Inputs larger than
1 GiB are written as several concatenated frames.

The remaining keywords override individual parameters of the level (each
`nothing`, the default, keeps the level's value), with the meaning of
libzstd's advanced parameters (`ZSTD_c_windowLog` etc.):

- `window_log` (10-30): log2 of the maximum match distance (window size)
- `hash_log` (6-27): log2 of the main hash table size
- `chain_log` (6-28): log2 of the chain / secondary table size (unused by the
  greedy and lazy strategies, whose row-based match finder sizes rows from
  `search_log`, as in libzstd)
- `search_log` (1-26): log2 of the number of match candidates searched
- `min_match` (3-7): minimum match length searched for (the match finders
  use 4-7 for fast/dfast, 4-6 for greedy/lazy, 3-4 for btopt/btultra)
- `target_length` (0-131072): for fast, a step size (acceleration); for
  btopt/btultra, a length taken without optimizing (unused by greedy/lazy,
  as in libzstd)
- `strategy`: `:fast`, `:dfast`, `:greedy`, `:lazy`, `:lazy2`, `:btlazy2`,
  `:btopt`, `:btultra` or `:btultra2` (libzstd's strategies)

Values out of range throw an `ArgumentError`. Parameters are adapted to the
input size afterwards, as in libzstd (the window shrinks for small inputs).
For example, `compress(data; level=19, window_log=24)` searches matches up to
16 MiB back.
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
                  checksum::Bool=false, dict::Union{Nothing,ZstandardDictionary,PreparedDictionary}=nothing,
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
