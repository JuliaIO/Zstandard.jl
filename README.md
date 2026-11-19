# Zstandard.jl

A pure Julia implementation of the [Zstandard](https://facebook.github.io/zstd/) (RFC 8878) compression algorithm, with no dependencies (TranscodingStreams.jl support is an optional extension).

## Features

- **Compression** at levels -7 to 22 using libzstd-style strategies (fast, dfast, greedy, lazy, lazy2, and binary-tree optimal parsing for levels 16-22) with repeat-offset aware parsing
- Huffman literals (direct or FSE-compressed weights, 1 or 4 streams, table reuse across blocks) and FSE sequence coding with predefined/RLE/compressed/repeat table selection
- Frame content size recorded in the header; optional XXH64 content checksum
- **Decompression** of all standard frames, including concatenated and skippable frames (decoded in parallel with `nthreads`), raw and formatted dictionaries
- Streaming decompression via `ZstdDecompressorStream` (implements `IO`, memory bounded by the window size; frames with windows above `max_window_size`, default 128 MiB as in libzstd, are rejected)
- Streaming compression via `ZstdCompressorStream` (implements `IO`, with `flush` support)
- Dictionary compression (raw content or formatted dictionaries) and dictionary training (`train_dictionary`, fastCover as `zstd --train`)
- Long-distance matching (`long=true`, as `zstd --long`) and multithreaded compression (`nthreads`)
- Frame inspection: `frame_header`, `frame_content_size`, `frame_compressed_size`, `decompressed_size`, skippable frames
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

# Long-distance matching and multithreading (start Julia with `-t N`)
compressed = compress(big_data; level=9, long=true)
compressed = compress(big_data; level=3, nthreads=Threads.nthreads())

# Frame inspection
frame_content_size(compressed)        # decompressed size from the header (or nothing)
frame_compressed_size(compressed)     # size of the first frame
meta = skippable_frame("user metadata")

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
| text   |  1 | 3.35 / 3.42 | 255 / 247 |
| text   |  3 | 3.77 / 3.78 | 151 / 157 |
| text   |  9 | 4.33 / 4.35 |  20 /  41 |
| text   | 16 | 4.80 / 4.76 | 2.4 / 3.4 |
| text   | 19 | 4.86 / 4.87 | 2.1 / 2.1 |
| binary |  3 | 2.98 / 2.99 | 130 / 179 |
| binary | 16 | 3.47 / 3.46 | 1.9 / 4.4 |
| binary | 19 | 3.63 / 3.72 | 1.8 / 2.5 |

Ratios are within about 3% of libzstd at all levels. Levels 13-15 use lazy2 (libzstd uses a
binary-tree lazy parser there); levels 16-22 use an optimal parser with a binary-tree match finder.

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
