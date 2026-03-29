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

## Performance

Benchmarked against libzstd (via [CodecZstd.jl](https://github.com/JuliaIO/CodecZstd.jl)) on an AMD Ryzen system, Julia 1.11:

### Compression Ratio

| Dataset | Zstd.jl | libzstd | Gap |
|---------|---------|---------|-----|
| text 5KB | 72.5:1 | 73.5:1 | 1.0x |
| text 50KB | 838.1:1 | 825.0:1 | 1.0x |
| repetitive 160KB | 4311.6:1 | 4551.1:1 | 1.1x |
| repetitive 1MB | 8388.6:1 | 8738.1:1 | 1.0x |
| random 1MB | 1.0:1 | 1.0:1 | 1.0x |

Compression ratios are within 6% of libzstd across all tested datasets.

### Throughput (MB/s)

| Dataset | Compress (jl/lib) | Decompress (jl/lib) |
|---------|-------------------|---------------------|
| text 5KB | 141 / 112 | 314 / 488 |
| text 50KB | 374 / 894 | 551 / 957 |
| repetitive 160KB | 446 / 1611 | 497 / 924 |
| repetitive 1MB | 448 / 1708 | 450 / 1063 |
| random 1MB | 918 / 753 | 809 / 2474 |

Compression is faster than libzstd on small text and incompressible data. Decompression is within 2-3x of libzstd for compressible data.

## Running Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```
