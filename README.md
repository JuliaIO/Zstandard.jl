# Zstandard.jl

A pure Julia implementation of the Zstandard compression algorithm.

## Status

Currently, this is a very early prototype of a decompressor.
It can handle:
- Zstd Magic Number
- Basic Frame Header (FD, WD, FCS)
- Multiple Frames
- Skippable Frames
- Raw Blocks
- RLE Blocks
- Raw/RLE Literals in Compressed Blocks (skeleton for Sequences)

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

## Running Tests

```bash
julia --project=. test/runtests.jl
```
