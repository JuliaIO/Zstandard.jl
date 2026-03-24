# Zstandard.jl

A pure Julia implementation of the Zstandard compression algorithm.

## Status

Currently, this is a early prototype of a decompressor.
It supports:
- Zstd Magic Number
- Basic Frame Header (FD, WD, FCS)
- Multiple Frames
- Skippable Frames
- Raw Blocks
- RLE Blocks
- Compressed Blocks (Huffman literals and FSE sequences)
- Checksum verification (XXH64)
- Dictionary support (Raw content)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/mkitti/Zstandard.jl")
```

## Usage

```julia
using Zstandard
data = read("example.zst")
decompressed = decompress(data)
```

### Streaming API

```julia
using Zstandard
open("example.zst", "r") do io
    stream = ZstdDecompressorStream(io)
    data = read(stream)
end
```

## API Reference

```@index
```

```@autodocs
Modules = [Zstandard, Zstandard.Streaming, Zstandard.Dictionary]
```
