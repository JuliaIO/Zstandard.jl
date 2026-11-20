# Zstandard.jl

A pure Julia implementation of the [Zstandard](https://facebook.github.io/zstd/) (RFC 8878) compression algorithm. No C dependencies required.

## Features

- **Compression** at levels -7 to 22 using libzstd-style strategies (fast, dfast, greedy, lazy, lazy2) with repeat-offset aware parsing
- Huffman literals (direct or FSE-compressed weights, 1 or 4 streams, table reuse across blocks) and FSE sequence coding with predefined/RLE/compressed/repeat table selection
- Frame content size recorded in the header; optional XXH64 content checksum
- **Decompression** of all standard frames, including concatenated and skippable frames, raw and formatted dictionaries
- Streaming decompression via `ZstdDecompressorStream` (implements `IO`, memory bounded by the window size)
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

> **Note:** This package depends on a fork of [XXHashNative.jl](https://github.com/Moelf/XXHashNative.jl) that adds XXH64 support. The `[sources]` section in `Project.toml` points to this fork until [Moelf/XXHashNative.jl#28](https://github.com/Moelf/XXHashNative.jl/pull/28) is merged.

## Usage

```julia
using Zstandard

# Compress
compressed = compress("Hello, world!")
compressed = compress(read("input.bin"))

# Decompress
data = decompress(compressed)

# Streaming decompression
open("file.zst") do io
    stream = ZstdDecompressorStream(io)
    decompressed = read(stream)
end

# Compression level (-7 to 22, default 3) and optional content checksum
compressed = compress(data; level=19, checksum=true)
```

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
| text   |  9 | 4.33 / 4.35 |  25 /  45 |
| text   | 19 | 4.43 / 4.87 | 2.3 / 2.0 |
| binary |  3 | 2.98 / 2.99 | 121 / 170 |
| binary | 19 | 3.18 / 3.72 | 4.3 / 2.4 |

Levels 1-12 are within about 3% of libzstd's ratio. Levels 13-22 use lazy2 parsing instead
of libzstd's binary-tree and optimal parsers, so they compress less than libzstd.

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
