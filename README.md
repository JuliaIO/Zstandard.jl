# Zstandard.jl

A pure Julia implementation of the [Zstandard](https://facebook.github.io/zstd/) (RFC 8878) compression algorithm, with no dependencies (TranscodingStreams.jl support is an optional extension).

## Features

- **Compression** at levels -7 to 22 with libzstd 1.5.7's strategies and parameter tables (fast, dfast, greedy/lazy/lazy2 with the row-based match finder, btlazy2, btopt, btultra, btultra2), block pre- and post-splitting, and repeat-offset aware parsing; ratios match or beat libzstd's at nearly every level
- Huffman literals (direct or FSE-compressed weights, 1 or 4 streams, table reuse across blocks) and FSE sequence coding with predefined/RLE/compressed/repeat table selection
- **Decompression** of all standard frames, including concatenated and skippable frames (decoded in parallel with `nthreads`), raw and formatted dictionaries
- Streaming compression and decompression (`ZstdCompressorStream`, `ZstdDecompressorStream`, implementing `IO`): pledged sizes, size hints, mid-frame `flush`, a window limit for untrusted input, and progress counters (`stream_progress`)
- Reusable contexts (`ZstdCompressionContext`, `ZstdDecompressionContext`) with `compress!` / `decompress!` into your own buffers
- Dictionaries: compression with raw or formatted dictionaries, prepared dictionaries for many small inputs, training (`train_dictionary`: fastCover or exact COVER, with parameter search on several threads)
- Reference prefixes (`prefix=`, as `zstd --patch-from`), long-distance matching (`long=true`), multithreaded compression (`nthreads`), `rsyncable` output
- libzstd's advanced parameters (`window_log`, `strategy`, ...), frame header options (`content_size`, `dict_id`, magicless frames) and a target compressed block size
- The seekable format (`compress_seekable`, `seek_table`, `decompress_range`), compatible with libzstd's `contrib/seekable_format`
- Sequence-level API: `generate_sequences` and `compress_sequences` (as `ZSTD_generateSequences` / `ZSTD_compressSequences`)
- Frame inspection (`frame_header`, `frame_content_size`, `frame_compressed_size`, `decompressed_size`, skippable frames) and memory estimates (`estimate_compression_memory`, `estimate_decompression_memory`)
- [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl) codecs `ZstandardCompressor` / `ZstandardDecompressor` (package extension, loaded with `using TranscodingStreams`)
- Malformed input is rejected with a `ZstdError`

## See Also

- [CodecZstd.jl](https://github.com/JuliaIO/CodecZstd.jl) -- wraps the C libzstd library via [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl), providing a mature and battle-tested streaming interface.
- [ChunkCodecsLibZstd.jl](https://github.com/JuliaIO/ChunkCodecs.jl/tree/main/libs/ChunkCodecsLibZstd) -- wraps the C libzstd library via [ChunkCodecs.jl](https://github.com/JuliaIO/ChunkCodecs.jl), providing chunk-based encoding and decoding.

For production use, these C-backed packages are likely more reliable and performant. Zstandard.jl is useful when a pure Julia implementation is preferred, such as for environments where C dependencies are unavailable or for educational purposes.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaIO/Zstandard.jl")
```


## Usage

```julia
using Zstandard

# Compress / decompress in memory
compressed = compress("Hello, world!")
compressed = compress(read("input.bin"); level=19, checksum=true)  # levels -7..22, default 3
data = decompress(compressed)

# Streaming decompression
open("file.zst") do io
    stream = ZstdDecompressorStream(io)
    decompressed = read(stream)
end

# Streaming compression (close finishes the frame and closes the file)
stream = ZstdCompressorStream(open("out.zst", "w"); level=5)
write(stream, data)
close(stream)

# If the total size is known in advance, pledge it: the frame header then records
# the content size and the compression parameters are sized to it
stream = ZstdCompressorStream(open("out.zst", "w"); pledged_size=length(data))

# Dictionaries
dict = parse_dictionary(read("my.dict"))      # formatted (zstd --train) or raw content
compressed = compress(data; dict)
decompress(compressed, dict)

# Many small messages with one dictionary: prepare it once (much faster per message)
pdict = prepare_dictionary(dict; level=3)
compressed = compress(message; dict=pdict)      # decompress with `dict` as usual

# Train a dictionary from many small samples
dict_bytes = train_dictionary(samples; dict_size=16384)
dict = parse_dictionary(dict_bytes)

# Explicit parameters override the level's (as libzstd's ZSTD_c_* parameters)
compressed = compress(data; level=19, window_log=24, strategy=:btultra)

# Long-distance matching and multithreading (start Julia with `-t N`)
compressed = compress(big_data; level=9, long=true)
compressed = compress(big_data; level=3, nthreads=Threads.nthreads())

# Frame inspection
frame_content_size(compressed)        # decompressed size from the header (or nothing)
frame_compressed_size(compressed)     # size of the first frame
meta = skippable_frame("user metadata")

# Reusable contexts: many small inputs without per-call allocation
ctx = ZstdCompressionContext(level=3); out = UInt8[]
for msg in messages
    compress!(ctx, out, msg)          # `out` holds the frame
end

# Patches against an earlier version (as zstd --patch-from)
patch = compress(new_version; prefix=old_version, level=19)
decompress(patch; prefix=old_version)

# Seekable archives: decode any range without decoding everything before it
archive = compress_seekable(data; frame_size=1 << 20)
decompress_range(archive, 5_000_001:5_100_000)
open(io -> decompress_range(io, 1:1000), "archive.zst")     # reads only the frames needed

# Sequences: inspect what the compressor finds, or encode matches found elsewhere
seqs = generate_sequences(data; level=9)
frame = compress_sequences(data, seqs)

# TranscodingStreams codecs
using TranscodingStreams
compressed = transcode(ZstandardCompressor(level=3), data)
stream = TranscodingStream(ZstandardDecompressor(), open("file.zst"))
```

## Checksum implementation

Frame content checksums use this package's XXH64 by default. Another implementation can be plugged
in by subtyping `Zstandard.AbstractXXH64` and defining four methods (see `Zstandard.XXHash`):

```julia
struct MyXXH64 <: Zstandard.AbstractXXH64 end
Zstandard.XXHash.xxh64(::MyXXH64, p::Ptr{UInt8}, n::Int, seed::UInt64) = ...   # one-shot
Zstandard.XXHash.xxh64_init(::MyXXH64, seed::UInt64) = ...                    # streaming state
Zstandard.XXHash.xxh64_update!(::MyXXH64, state, p::Ptr{UInt8}, n::Int) = ...
Zstandard.XXHash.xxh64_digest(::MyXXH64, state) = ...

Zstandard.with_xxh64_implementation(MyXXH64()) do
    compress(data; checksum=true)
end
```

The tests check the native code against XXHashNative.jl and the xxHash C library, and
`test/benchmark/xxhash_compare.jl` compares their speed.

## Performance

Single thread, Julia 1.11, on realistic data: 4 MB of Julia `base/` sources ("text") and
`libjulia-internal.so` ("binary"). libzstd is called through
[CodecZstd.jl](https://github.com/JuliaIO/CodecZstd.jl)'s `transcode`, which adds some
TranscodingStreams overhead. Scripts: `test/benchmark/compress_compare.jl` and
`test/benchmark/inflate_compare.jl`.

### Compression

| Data | Level | Ratio (Zstandard.jl / libzstd) | MB/s (Zstandard.jl / libzstd) |
|------|------:|-------------------------------:|------------------------------:|
| text   | -5 | 2.32 / 2.33 | 326 / 408 |
| text   |  1 | 3.42 / 3.42 | 277 / 352 |
| text   |  3 | 3.80 / 3.78 | 167 / 175 |
| text   |  9 | 4.36 / 4.35 |  32 /  46 |
| text   | 13 | 4.48 / 4.47 |  12 /  12 |
| text   | 16 | 4.80 / 4.76 | 4.4 / 5.3 |
| text   | 19 | 4.87 / 4.87 | 3.2 / 3.0 |
| binary |  1 | 2.68 / 2.67 | 292 / 382 |
| binary |  3 | 3.01 / 2.99 | 155 / 183 |
| binary |  9 | 3.27 / 3.22 |  42 /  52 |
| binary | 13 | 3.28 / 3.24 |  14 /  13 |
| binary | 16 | 3.53 / 3.46 | 4.1 / 5.8 |
| binary | 19 | 3.71 / 3.72 | 2.6 / 3.0 |

Ratios match or beat libzstd at every level except binary level 19 (-0.2%); speed is
within about 1.0-1.4x of libzstd's. Timings on this machine vary by about 10% between runs.

### Decompression (MB/s of output)

| Data (libzstd level) | Zstandard.jl | [ZstdInflate.jl](https://github.com/BioTurboNick/ZstdInflate.jl) | libzstd |
|------|------:|------:|------:|
| text 64KB (3) | 914 | 553 | 693 |
| text (1)      | 811 | 432 | 742 |
| text (3)      | 791 | 399 | 646 |
| text (19)     | 622 | 366 | 604 |
| binary (3)    | 648 | 264 | 557 |

## Running Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```
