# Zstandard.jl

A pure Julia implementation of the [Zstandard](https://facebook.github.io/zstd/) (RFC 8878) compression algorithm. No C dependencies required.

## Features

- **Compression** at levels -7 to 22 with libzstd 1.5.7's strategies and parameter tables (fast, dfast, greedy/lazy/lazy2 with the row-based match finder, btlazy2, btopt, btultra, btultra2), block pre- and post-splitting, and repeat-offset aware parsing; ratios match or beat libzstd's at nearly every level (3-byte match finder for levels 18-22 included)
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

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaIO/Zstandard.jl")
```

## Quick Start

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

# Optional content checksum
compressed = compress(data, checksum=true)
```

## See Also

- [CodecZstd.jl](https://github.com/JuliaIO/CodecZstd.jl) -- wraps the C libzstd library via [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl), providing a mature and battle-tested streaming interface.
- [ChunkCodecsLibZstd.jl](https://github.com/JuliaIO/ChunkCodecs.jl/tree/main/libs/ChunkCodecsLibZstd) -- wraps the C libzstd library via [ChunkCodecs.jl](https://github.com/JuliaIO/ChunkCodecs.jl), providing chunk-based encoding and decoding.

For production use, these C-backed packages are likely more reliable and performant. Zstandard.jl is useful when a pure Julia implementation is preferred, such as for environments where C dependencies are unavailable or for educational purposes.
