# Zstandard.jl

A pure Julia implementation of the [Zstandard](https://facebook.github.io/zstd/) (RFC 8878) compression algorithm. No C dependencies required.

## Features

- **Compression** and **decompression** of Zstandard frames
- Streaming decompression via `ZstdDecompressorStream` (implements `IO` interface)
- Huffman and FSE entropy coding
- Repeat offset encoding
- Multi-block support for data larger than 128KB
- Dictionary decompression
- Skippable frames
- Optional content checksums (XXH64)

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
