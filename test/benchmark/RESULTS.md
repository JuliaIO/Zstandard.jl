# Benchmark Results Log

## 2026-11-19 — XXH64 implementations compared

Script: `test/benchmark/xxhash_compare.jl` (adapters in `test/xxhash_impls.jl`; ZstdInflate.jl is
included when installed). Julia 1.11, 4-core Xeon VM.

```
XXH64 one-shot (MB/s)
                                16 bytes  100 bytes 1024 bytes 64.000 KiB 16.000 MiB
Zstandard.jl (native)                381       1734       7398      10967      10718
XXHashNative.jl                      193        782       2625       3478       3359
xxHash C library (xxHash_jll)        381       1766       7398      10969      10748
ZstdInflate.jl                       272       1109       3742       5176       5066

XXH64 streaming, 16 MiB in pieces of the given size (MB/s)
                               4.000 KiB 128.000 KiB
Zstandard.jl (native)              10765      10794
XXHashNative.jl                     3239       3298
xxHash C library (xxHash_jll)      10789      10833
ZstdInflate.jl                     10438      10759

Zstandard.jl with each implementation, 4 MiB checksummed frame (MB/s)
                                decompress  stream read  compress L1
Zstandard.jl (native)                 5251         1710         5145
XXHashNative.jl                       2526         1211         2525
xxHash C library (xxHash_jll)         5185         1673         5134
ZstdInflate.jl                        3360         2048         3334
```

Zstandard.jl's native XXH64 matches the C reference library. ZstdInflate.jl's one-shot hash packs the
four lanes into a SIMD.jl vector and is about half as fast as its own scalar streaming code.

---

## 2026-11-18 — XXH64 rewrite, parallel decoding of concatenated frames

XXH64, 16 MB (MB/s): XXHashNative 3,522; ZstdInflate (SIMD.jl, 4 lanes in one vector) 5,209;
new scalar implementation 11,167 (one-shot) / 11,010 (streaming, 128 KB updates).
The four XXH64 lanes are serial multiply/rotate chains, so packing them into one vector does not
help: `vpmullq` has much higher latency than scalar `imul`. LLVM's SLP vectorizer packed the
streaming loop on its own (halving its speed); an empty inline-asm barrier per lane prevents that.

Concatenated frames, 4 threads, `decompress` vs `inflate_zstd(...; nthreads=4)` (MB/s):

| Input | Zstandard.jl | ZstdInflate |
|---|--:|--:|
| 4 MB in 4 frames | 2,330 | 1,074 |
| 16 MB in 16 frames | 1,708 | 423 |
| 16 MB in 256 frames | 1,887 | 1,192 |

Checksummed 4 MB frame: 642 MB/s (was 548), the same as without a checksum.

---

## 2026-11-17 — Optimal parser for levels 16-22

Script: `test/benchmark/compress_compare.jl` (now also level 16). Same machine and corpora.

```
Compression: ratio and throughput (MB/s of input, median)
------------------------------------------------------------------------------------
Dataset      level | ratio jl  ratio C |   MB/s jl    MB/s C | slowdown
------------------------------------------------------------------------------------
text 4MB         1 |    3.354    3.421 |     192.4     277.8 |     1.4x
text 4MB         3 |    3.767    3.783 |     138.0     159.2 |     1.2x
text 4MB         6 |    4.032    4.208 |      70.9      63.6 |     0.9x
text 4MB         9 |    4.333    4.350 |      19.8      41.3 |     2.1x
text 4MB        16 |    4.800    4.764 |       2.4       3.4 |     1.4x
text 4MB        19 |    4.859    4.868 |       2.1       2.1 |     1.0x
binary           1 |    2.705    2.669 |     204.8     297.9 |     1.5x
binary           3 |    2.981    2.985 |     130.4     179.4 |     1.4x
binary           6 |    3.112    3.188 |      49.6      65.0 |     1.3x
binary           9 |    3.126    3.222 |      20.0      43.5 |     2.2x
binary          16 |    3.471    3.455 |       1.9       4.4 |     2.3x
binary          19 |    3.627    3.720 |       1.8       2.5 |     1.4x
------------------------------------------------------------------------------------
```

### Notes
- Forward DP over up to 4096 positions with adaptive prices (literals, LL/ML/OF codes), repeat
  offsets tracked per DP state; binary-tree match finder (insertBt1 / getAllMatches).
- Level 19 before (lazy2): text 4.430, binary 3.182. Now 4.859 / 3.627 (libzstd 4.868 / 3.720).
- Levels 18-22 use minimum match length 3 (3-byte hash), as libzstd does.

---

## 2026-11-17 — New encoder (level strategies, entropy coding)

Script: `test/benchmark/compress_compare.jl`, same machine and corpora as the decoder entry below.

### Before (commit 5e71ef0)

```
Compression: ratio and throughput (MB/s of input, median)
------------------------------------------------------------------------------------
Dataset      level | ratio jl  ratio C |   MB/s jl    MB/s C | slowdown
------------------------------------------------------------------------------------
text 4MB         1 |    2.866    3.421 |      29.8     208.7 |     7.0x
text 4MB         3 |    3.029    3.783 |      13.3     136.0 |    10.2x
text 4MB         6 |    3.029    4.208 |      14.5      63.7 |     4.4x
text 4MB         9 |    3.029    4.350 |      12.0      34.6 |     2.9x
text 4MB        19 |    3.029    4.868 |      13.4       1.9 |     0.1x
binary           1 |    2.470    2.669 |      31.2     184.2 |     5.9x
binary           3 |    2.594    2.985 |      10.1     136.6 |    13.6x
binary           6 |    2.594    3.188 |      11.8      64.2 |     5.5x
binary           9 |    2.594    3.222 |       9.0      40.9 |     4.5x
binary          19 |    2.594    3.720 |      11.9       2.1 |     0.2x
------------------------------------------------------------------------------------
```

### After

```
Compression: ratio and throughput (MB/s of input, median)
------------------------------------------------------------------------------------
Dataset      level | ratio jl  ratio C |   MB/s jl    MB/s C | slowdown
------------------------------------------------------------------------------------
text 4MB         1 |    3.354    3.421 |     255.4     247.2 |     1.0x
text 4MB         3 |    3.767    3.783 |     150.9     157.2 |     1.0x
text 4MB         6 |    4.032    4.208 |      70.9      64.8 |     0.9x
text 4MB         9 |    4.333    4.350 |      24.6      44.9 |     1.8x
text 4MB        19 |    4.430    4.868 |       2.3       2.0 |     0.9x
binary           1 |    2.705    2.669 |     168.2     312.7 |     1.9x
binary           3 |    2.981    2.985 |     120.7     169.5 |     1.4x
binary           6 |    3.112    3.188 |      55.0      61.2 |     1.1x
binary           9 |    3.126    3.222 |      20.7      46.3 |     2.2x
binary          19 |    3.182    3.720 |       4.3       2.4 |     0.5x
------------------------------------------------------------------------------------
```

### Notes
- Level table after libzstd: fast (1-2, negative), dfast (3-4), greedy (5), lazy (6-7), lazy2 (8+).
- Repeat-offset checks before hash lookups; backward match extension; hash tables kept across blocks.
- Huffman: two-queue construction with exact length limiting, FSE-compressed weights (binary
  data now gets Huffman literals), treeless reuse; FSE: cost-based predefined/RLE/FSE/repeat.
- Levels 13+ lack libzstd's btopt/btultra parsers, hence the ratio gap at level 19.

---

## 2026-11-17 — Decoder rewrite (vs ZstdInflate.jl)

Script: `test/benchmark/inflate_compare.jl` (realistic corpora: Julia `base/` sources and
`libjulia-internal.so`, compressed by libzstd at the given level, or by Zstandard.jl for "jl").
Single thread, Julia 1.11.7, 4-core cloud VM. libzstd is measured through CodecZstd's
`transcode`, which includes TranscodingStreams buffering overhead.

### Before (commit 487e194)

```
Decompression throughput (MB/s of output, median), single thread
------------------------------------------------------------------------------
Dataset        |   ratio |    Zstd.jl  ZstdInflate    libzstd |  jl/Infl
------------------------------------------------------------------------------
text 64KB L3   |   3.15  |      145.4        486.1      653.5 |    3.34x
text 4MB L1    |   3.42  |      135.4        445.2      803.2 |    3.29x
text 4MB L3    |   3.78  |      127.7        416.6      650.7 |    3.26x
text 4MB L19   |   4.87  |      126.2        423.1      573.4 |    3.35x
binary L3      |   2.99  |       60.5        277.2      465.4 |    4.58x
```

### After

```
Decompression throughput (MB/s of output, median), single thread
------------------------------------------------------------------------------
Dataset        |   ratio |    Zstd.jl  ZstdInflate    libzstd |  jl/Infl
------------------------------------------------------------------------------
text 64KB L3   |   3.15  |      942.8        523.8      661.4 |    0.56x
text 4MB L1    |   3.42  |      876.2        439.5      708.4 |    0.50x
text 4MB L3    |   3.78  |      705.6        402.8      631.0 |    0.57x
text 4MB L19   |   4.87  |      666.3        366.6      562.8 |    0.55x
binary L3      |   2.99  |      567.7        268.8      508.7 |    0.47x
text 4MB jl    |   3.03  |      727.3        440.5      585.0 |    0.61x
------------------------------------------------------------------------------
```

### Notes
- New `Decoder` module: frames decoded straight from the input vector into one output buffer
  (no per-block IOBuffer/allocations, no history copies).
- libzstd-style backward bit reader (64-bit container, unaligned reloads) held in registers.
- Packed UInt64 FSE entries; 4-stream Huffman decoded in lockstep; fused sequence decode/execute
  with wildcopy.
- Corruption detection: offset 0/out of range, overruns, unconsumed bitstreams, content size and
  checksum mismatches all raise `ZstandardError` (previously-broken golden error tests now pass).

---

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
