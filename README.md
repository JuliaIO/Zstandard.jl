# Zstandard.jl

[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliaio.github.io/Zstandard.jl/dev/)

A pure Julia implementation of the [Zstandard](https://facebook.github.io/zstd/) (RFC 8878) compression algorithm, with no dependencies (TranscodingStreams.jl support is an optional extension).

## Features

- **Compression** at levels -7 to 22 with libzstd 1.5.7's strategies and parameter tables (fast, dfast, greedy/lazy/lazy2 with the row-based match finder, btlazy2, btopt, btultra, btultra2), block pre- and post-splitting, and repeat-offset aware parsing; ratios match or beat libzstd's at nearly every level (3-byte match finder for levels 18-22 included)
- Huffman literals (direct or FSE-compressed weights, 1 or 4 streams, table reuse across blocks) and FSE sequence coding with predefined/RLE/compressed/repeat table selection
- **Decompression** of all standard frames, including concatenated and skippable frames (decoded in parallel with `nthreads`), raw and formatted dictionaries (several at once with `ZstandardDictionarySet`, chosen per frame by dictionary ID)
- Streaming compression and decompression (`ZstandardCompressorStream`, `ZstandardDecompressorStream`, implementing `IO`): pledged sizes, size hints, long-distance matching and multithreading on streams, mid-frame `flush`, a window limit for untrusted input, and progress counters (`stream_progress`)
- Reusable contexts (`ZstandardCompressionContext`, `ZstandardDecompressionContext`) with `compress!` / `decompress!` into your own buffers
- Dictionaries: compression with raw or formatted dictionaries, prepared dictionaries for many small inputs, training (`train_dictionary`: fastCover or exact COVER, with parameter search on several threads)
- Reference prefixes (`prefix=`, as `zstd --patch-from`), long-distance matching (`long=true`), multithreaded compression (`nthreads`), `rsyncable` output
- libzstd's advanced parameters (`window_log`, `strategy`, ...), frame header options (`content_size`, `dict_id`, magicless frames) and a target compressed block size
- The seekable format (`compress_seekable`, `seek_table`, `decompress_range`), compatible with libzstd's `contrib/seekable_format`
- Sequence-level API (experimental, as in libzstd): `generate_sequences` and `compress_sequences` (as `ZSTD_generateSequences` / `ZSTD_compressSequences`)
- Frame inspection (`frame_header`, `frame_content_size`, `frame_compressed_size`, `decompressed_size`, skippable frames), size bounds (`compress_bound`, `decompress_bound`) and memory estimates (`estimate_compression_memory`, `estimate_decompression_memory`)
- Julia 1.10 (LTS) and later
- [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl) codecs `ZstandardCompressor` / `ZstandardDecompressor` (package extension, loaded with `using TranscodingStreams`)
- Malformed input is rejected with a `ZstandardError`

## See Also

- [CodecZstd.jl](https://github.com/JuliaIO/CodecZstd.jl) -- wraps the C libzstd library via [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl), providing a mature and battle-tested streaming interface.
- [ChunkCodecsLibZstd.jl](https://github.com/JuliaIO/ChunkCodecs.jl/tree/main/libs/ChunkCodecsLibZstd) -- wraps the C libzstd library via [ChunkCodecs.jl](https://github.com/JuliaIO/ChunkCodecs.jl), providing chunk-based encoding and decoding.
- [ZstdInflate.jl](https://github.com/BioTurboNick/ZstdInflate.jl) -- a pure Julia Zstandard decompressor (no compression), with in-memory and streaming decoding and parallel decoding of concatenated frames.

The C-backed packages wrap libzstd, which has years of production use and fuzzing behind it;
prefer them where that matters most. Zstandard.jl is a complete pure Julia implementation
(compression and decompression) for environments where C dependencies are unavailable or
undesirable; its compression ratios match libzstd's and its decompression is about as fast or
faster (see [Performance](#performance)).

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaIO/Zstandard.jl")
```


## Usage

```julia
using Zstandard     # exports the core API; the rest is public, as `Zstandard.name`

# Compress / decompress in memory
compressed = compress("Hello, world!")
compressed = compress(read("input.bin"); level=19, checksum=true)  # levels -7..22, default 3
data = decompress(compressed)

# Streaming decompression
open("file.zst") do io
    stream = ZstandardDecompressorStream(io)
    decompressed = read(stream)
end

# Streaming compression (close finishes the frame and closes the file)
stream = ZstandardCompressorStream(open("out.zst", "w"); level=5)
write(stream, data)
close(stream)

# If the total size is known in advance, pledge it: the frame header then records
# the content size and the compression parameters are sized to it
stream = ZstandardCompressorStream(open("out.zst", "w"); pledged_size=length(data))

# Dictionaries
dict = parse_dictionary(read("my.dict"))      # formatted (zstd --train) or raw content
compressed = compress(data; dict)
decompress(compressed, dict)

# Many small messages with one dictionary: prepare it once (much faster per message)
pdict = Zstandard.prepare_dictionary(dict; level=3)
compressed = compress(message; dict=pdict)      # decompress with `dict` as usual

# Frames using different dictionaries: each frame's dictionary ID picks one
decompress(vcat(compress(a; dict=dict_a), compress(b; dict=dict_b)), ZstandardDictionarySet(dict_a, dict_b))

# Train a dictionary from many small samples
dict_bytes = train_dictionary(samples; dict_size=16384)
dict = parse_dictionary(dict_bytes)

# Explicit parameters override the level's (as libzstd's ZSTD_c_* parameters)
compressed = compress(data; level=19, window_log=24, strategy=:btultra)

# Long-distance matching and multithreading (start Julia with `-t N`), also on streams
compressed = compress(big_data; level=9, long=true)
compressed = compress(big_data; level=3, nthreads=Threads.nthreads())
stream = ZstandardCompressorStream(open("big.zst", "w"); level=3, nthreads=Threads.nthreads())

# Preallocate output for `Zstandard.compress!` with the worst-case size
out = Vector{UInt8}(undef, Zstandard.compress_bound(length(data)))

# Frame inspection
Zstandard.frame_content_size(compressed)        # decompressed size from the header (or nothing)
Zstandard.frame_compressed_size(compressed)     # size of the first frame
meta = Zstandard.skippable_frame("user metadata")

# Reusable contexts: many small inputs without per-call allocation
ctx = Zstandard.ZstandardCompressionContext(level=3); out = UInt8[]
for msg in messages
    Zstandard.compress!(ctx, out, msg)          # `out` holds the frame
end

# Patches against an earlier version (as zstd --patch-from)
patch = compress(new_version; prefix=old_version, level=19)
decompress(patch; prefix=old_version)

# Seekable archives: decode any range without decoding everything before it
archive = Zstandard.compress_seekable(data; frame_size=1 << 20)
Zstandard.decompress_range(archive, 5_000_001:5_100_000)
open(io -> Zstandard.decompress_range(io, 1:1000), "archive.zst")     # reads only the frames needed

# Sequences (experimental, mirrors libzstd's experimental API): inspect what the
# compressor finds, or encode matches found elsewhere
seqs = Zstandard.generate_sequences(data; level=9)
frame = Zstandard.compress_sequences(data, seqs)

# TranscodingStreams codecs
using TranscodingStreams
compressed = transcode(ZstandardCompressor(level=3), data)
stream = TranscodingStream(ZstandardDecompressor(), open("file.zst"))
```

## Checksum implementation

Frame content checksums use this package's XXH64. The hook below for plugging in another
implementation is **internal** and may change in any release: it is not part of the public API.
It exists to compare implementations, and the findings are meant to flow into
[XXHashNative.jl](https://github.com/Moelf/XXHashNative.jl). To use it, subtype
`Zstandard.XXHash.AbstractXXH64` and define four methods:

```julia
struct MyXXH64 <: Zstandard.XXHash.AbstractXXH64 end
Zstandard.XXHash.xxh64(::MyXXH64, p::Ptr{UInt8}, n::Int, seed::UInt64) = ...   # one-shot
Zstandard.XXHash.xxh64_init(::MyXXH64, seed::UInt64) = ...                    # streaming state
Zstandard.XXHash.xxh64_update!(::MyXXH64, state, p::Ptr{UInt8}, n::Int) = ...
Zstandard.XXHash.xxh64_digest(::MyXXH64, state) = ...

Zstandard.XXHash.with_xxh64_implementation(MyXXH64()) do
    compress(data; checksum=true)
end
```

The tests check the native code against XXHashNative.jl and the xxHash C library, and
`test/benchmark/xxhash_compare.jl` compares their speed.

## Performance

Julia 1.11, measured on a 4-vCPU cloud VM (Xeon, 2.3 GHz) where timings vary by about 10%
between runs. Data: 4 MB of Julia `base/` sources ("text") and `libjulia-internal.so`
(13.9 MB, "binary"). libzstd 1.5.7 is called through
[CodecZstd.jl](https://github.com/JuliaIO/CodecZstd.jl), which adds some TranscodingStreams
overhead. Scripts: `test/benchmark/compress_compare.jl` and `test/benchmark/inflate_compare.jl`.

### Compression (single thread)

| Data | Level | Ratio (Zstandard.jl / libzstd) | MB/s (Zstandard.jl / libzstd) |
|------|------:|-------------------------------:|------------------------------:|
| text   | -5 | 2.32 / 2.33 | 327 / 421 |
| text   |  1 | 3.42 / 3.42 | 295 / 376 |
| text   |  3 | 3.80 / 3.78 | 189 / 201 |
| text   |  6 | 4.22 / 4.21 |  65 /  82 |
| text   |  9 | 4.36 / 4.35 |  38 /  54 |
| text   | 13 | 4.48 / 4.47 |  11 /  12 |
| text   | 16 | 4.80 / 4.76 | 4.0 / 5.9 |
| text   | 19 | 4.87 / 4.87 | 3.2 / 3.2 |
| binary |  1 | 2.68 / 2.67 | 309 / 407 |
| binary |  3 | 3.01 / 2.99 | 177 / 207 |
| binary |  9 | 3.27 / 3.22 |  40 /  58 |
| binary | 13 | 3.28 / 3.24 |  17 /  16 |
| binary | 16 | 3.53 / 3.46 | 4.7 / 6.6 |
| binary | 19 | 3.72 / 3.72 | 3.0 / 4.0 |
| binary | 22 | 3.73 / 3.72 | 3.1 / 3.4 |

Ratios match or beat libzstd at every level measured (text level -5 is 0.1% behind).
Compression takes about 1.0-1.5x libzstd's time. With `nthreads`, large inputs compress in
parallel (2x on 4 threads for 40 MB at levels 3 and 9, one-shot or streaming).

### Decompression (single thread, MB/s of output)

| Data (compressed by) | Zstandard.jl | [ZstdInflate.jl](https://github.com/BioTurboNick/ZstdInflate.jl) 0.2.1 | libzstd |
|------|------:|------:|------:|
| text 64KB (libzstd -3)  | 1203 | 659 |  823 |
| text (libzstd -1)       | 1114 | 550 | 1055 |
| text (libzstd -3)       | 1061 | 572 |  922 |
| text (libzstd -19)      | 1037 | 602 |  937 |
| binary (libzstd -3)     |  656 | 335 |  594 |
| text (Zstandard.jl -3)  | 1071 | 591 | 1126 |

ZstdInflate.jl's own benchmark (`test/performance/test_performance.jl` in that repository),
with Zstandard.jl added, gives times relative to libzstd (lower is faster):

| Size, data | In memory: Zstandard.jl / ZstdInflate.jl | Streaming: Zstandard.jl / ZstdInflate.jl |
|------|------:|------:|
| 1 KB text          | 0.11x / 0.33x | 0.23x / 0.40x |
| 100 KB huffman     | 1.15x / 1.77x | 0.87x / 1.26x |
| 100 KB text        | 0.23x / 0.35x | 0.36x / 0.40x |
| 10 MB incompressible | 0.40x / 0.60x | 1.40x / 1.45x |
| 10 MB huffman      | 1.10x / 1.94x | 1.16x / 1.69x |
| 10 MB repetitive   | 0.55x / 0.97x | 0.90x / 1.19x |
| 10 MB text         | 0.19x / 0.97x | 1.14x / 1.10x |

Concatenated frames decode in parallel: 100 frames of 100 KB (huffman data) take 0.53x
libzstd's time on 4 threads (ZstdInflate.jl 0.63x), 2.9x faster than on one.

### Checksums

The native XXH64 runs at 12-16 GB/s on Julia 1.11 through 1.14.0-beta1 (XXHashNative.jl
1.1.1: 4-7 GB/s). A test checks that LLVM does not vectorize its four lanes (see
`src/xxhash.jl`); `test/benchmark/xxhash_compare.jl` compares implementations.

## Running Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```
