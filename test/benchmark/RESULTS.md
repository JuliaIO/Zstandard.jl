# Benchmark Results Log

## 2026-03-28 — Table reuse, typed Huffman tree, ForwardBitWriter bulk ops

Commit: (pending commit)

### Compression (MB/s, median)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio (jl/lib) |
|---------|---------|---------|----------|----------------|
| text 5KB | 41.6 | 117.0 | 2.8x | 37.0/73.5 |
| text 50KB | 56.3 | 899.2 | 16.0x | 129.1/825.0 |
| repetitive 160KB | 62.9 | 2088.2 | 33.2x | 182.7/4551.1 |
| repetitive 1MB | 60.8 | 1849.5 | 30.4x | 201.8/8738.1 |
| random 1MB | 16.9 | 948.4 | 56.2x | 1.0/1.0 |

### Notes
- Table reuse via MatchContext: hash_table zeroed with memset (16K entries), chain_table reused without zeroing
- Huffman tree builder: replaced Any[] + sort! with typed flat arrays + sorted priority queue
- ForwardBitWriter: bulk bit packing into UInt64 container instead of byte-at-a-time
- IOBuffer pre-sized with sizehint
- Remaining gap is largely algorithmic: search_depth=64 chain walk dominates

---

## 2026-03-28 — After @inbounds, vectorized match extension, MSB-first bitreader

Commit: 3c559db

### Decompression (MB/s, median)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio |
|---------|---------|---------|----------|-------|
| text 5KB | 115.2 | 763.8 | 6.6x | 37.0:1 |
| text 50KB | 247.8 | 1142.0 | 4.6x | 129.1:1 |
| repetitive 160KB | 271.9 | 1527.8 | 5.6x | 182.7:1 |
| repetitive 1MB | 261.3 | 1536.1 | 5.9x | 201.8:1 |
| random 1MB | 321.8 | 1291.5 | 4.0x | 1.0:1 |

### Compression (MB/s, median)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio (jl/lib) |
|---------|---------|---------|----------|----------------|
| text 5KB | 24.5 | 117.8 | 4.8x | 37.0/73.5 |
| text 50KB | 45.7 | 888.3 | 19.5x | 129.1/825.0 |
| repetitive 160KB | 59.8 | 1649.6 | 27.6x | 182.7/4551.1 |
| repetitive 1MB | 53.5 | 1629.1 | 30.4x | 201.8/8738.1 |
| random 1MB | 12.2 | 780.8 | 64.1x | 1.0/1.0 |

### Notes
- Compression: 3-5x faster than previous commit (was ~9 MB/s across the board)
- Decompression: ~5x gap to libzstd, down from ~25x at start of session
- Compression ratio still ~2-40x worse than libzstd on larger data
- Main compression bottleneck: hash chain walk depth (search_depth=64 at level 3)
- Main decompression bottleneck: bitstream read overhead, allocation
