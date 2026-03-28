# Benchmark Results Log

## 2026-03-28 — Window_size fix, optional checksum, optimized frame header

Commit: 2e60e66

### Compression (MB/s, median, --quick)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio (jl/lib) |
|---------|---------|---------|----------|----------------|
| text 5KB | 141.4 | 111.5 | 0.8x | 72.5/73.5 |
| text 50KB | 373.8 | 894.2 | 2.4x | 838.1/825.0 |
| repetitive 160KB | 446.1 | 1611.3 | 3.6x | 4311.6/4551.1 |
| repetitive 1MB | 448.4 | 1707.8 | 3.8x | 8388.6/8738.1 |
| random 1MB | 918.2 | 752.7 | 0.8x | 1.0/1.0 |

### Decompression (MB/s, median, --quick)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio |
|---------|---------|---------|----------|-------|
| text 5KB | 314.2 | 488.3 | 1.6x | 72.5:1 |
| text 50KB | 551.0 | 956.5 | 1.7x | 838.1:1 |
| repetitive 160KB | 496.5 | 923.7 | 1.9x | 4311.6:1 |
| repetitive 1MB | 449.9 | 1063.0 | 2.4x | 8388.6:1 |
| random 1MB | 808.6 | 2473.6 | 3.1x | 1.0:1 |

### Notes
- Fixed single-segment frame window_size=0 bug (cross-block decompression was broken)
- Checksum now optional (`checksum=false` default, matching libzstd)
- Frame header uses window descriptor for data > 255 bytes (saves 3 bytes)
- All compression ratios within 6% of libzstd (was up to 2x gap)
- text 5KB and random 1MB compression faster than libzstd (0.8x)
- Decompression all within 3.1x (text cases under 2x)

---

## 2026-03-28 — Cached MatchContext, optimized XXHash and decompression output

Commit: 118c338

### Compression (MB/s, median, --quick)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio (jl/lib) |
|---------|---------|---------|----------|----------------|
| text 5KB | 135.5 | 116.5 | 0.9x | 67.6/73.5 |
| text 50KB | 329.0 | 983.5 | 3.0x | 776.5/825.0 |
| repetitive 160KB | 375.0 | 1611.8 | 4.3x | 3150.8/4551.1 |
| repetitive 1MB | 382.7 | 1604.2 | 4.2x | 4424.4/8738.1 |
| random 1MB | 628.7 | 671.6 | 1.1x | 1.0/1.0 |

### Decompression (MB/s, median, --quick)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio |
|---------|---------|---------|----------|-------|
| text 5KB | 298.8 | 699.6 | 2.3x | 67.6:1 |
| text 50KB | 471.9 | 1211.8 | 2.6x | 776.5:1 |
| repetitive 160KB | 491.7 | 1434.9 | 2.9x | 3150.8:1 |
| repetitive 1MB | 522.1 | 1597.4 | 3.1x | 4424.4:1 |
| random 1MB | 1196.4 | 1510.0 | 1.3x | 1.0:1 |

### Notes
- Cached MatchContext eliminates per-call allocation (~70-83% of compression time)
- XXHashNative ifb64/ifb32 rewritten with inline byte loads (was ~30-39% of decompression)
- Pre-sized decompression output buffer, in-place history trim
- text 5KB compression now faster than libzstd (0.9x)
- random 1MB within 1.1x compression, 1.3x decompression
- All gaps now under 4.3x (was up to 7.4x)

---

## 2026-03-28 — Long match support, Int32 tables, overlapping matches

Commit: 2d9af10

### Compression (MB/s, median, --quick)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio (jl/lib) |
|---------|---------|---------|----------|----------------|
| text 5KB | 91.4 | 109.5 | 1.2x | 67.6/73.5 |
| text 50KB | 197.4 | 883.1 | 4.5x | 776.5/825.0 |
| repetitive 160KB | 219.2 | 1620.5 | 7.4x | 3150.8/4551.1 |
| repetitive 1MB | 226.7 | 1607.0 | 7.1x | 4424.4/8738.1 |
| random 1MB | 295.0 | 735.9 | 2.5x | 1.0/1.0 |

### Decompression (MB/s, median, --quick)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio |
|---------|---------|---------|----------|-------|
| text 5KB | 175.7 | 846.6 | 4.8x | 67.6:1 |
| text 50KB | 242.6 | 1181.8 | 4.9x | 776.5:1 |
| repetitive 160KB | 253.7 | 1329.3 | 5.2x | 3150.8:1 |
| repetitive 1MB | 257.7 | 1226.1 | 4.8x | 4424.4:1 |
| random 1MB | 342.6 | 1252.1 | 3.7x | 1.0:1 |

### Notes
- Removed 255-byte match length cap — now supports overlapping matches up to 131074 bytes
- Int32 tables in MatchContext (halved allocation from ~1.1MB to ~0.55MB)
- Added `curr < pos` guard to prevent self-match from stale chain entries
- Compression ratio now within 1.1-2x of libzstd (was 2-49x)
- text 5KB compression within 1.2x throughput of libzstd
- random 1MB compression within 2.5x of libzstd
- Repetitive data: 167:1 → 3151:1 ratio (was 27x gap to libzstd, now 1.4x)
- Optional `ctx` parameter on `compress()` for MatchContext reuse across calls

---

## 2026-03-28 — Early exit, sparse hashing, table reuse, typed Huffman tree

Commit: d77d8fb

### Compression (MB/s, median, --quick)

| Dataset | Zstd.jl | libzstd | Slowdown | Ratio (jl/lib) |
|---------|---------|---------|----------|----------------|
| text 50KB | 141.9 | 884.5 | 6.2x | 114.0/825.0 |
| repetitive 160KB | 156.2 | 1633.8 | 10.5x | 167.0/4551.1 |
| random 1MB | 16.8 | 761.8 | 45.2x | 1.0/1.0 |

### Notes
- Early exit from chain walk when match >= 128 bytes
- Sparse hash update: only hash every other position for matches > 16 bytes
- Table reuse via MatchContext (chain_table not zeroed)
- Typed Huffman tree builder (was Any[] + sort!)
- ForwardBitWriter bulk bit packing
- text 50KB: 6.2x gap (was 16x last commit, 100x at start of session)
- Random 1MB gap mostly algorithmic (chain walk with search_depth=64 on incompressible data)

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
