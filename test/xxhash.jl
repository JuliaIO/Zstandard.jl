using Zstandard
using Test
using CodecZstd
using TranscodingStreams
using Zstd_jll

include("xxhash_impls.jl")

const XX = Zstandard.XXHash

# Reference vectors. Those for "ab" ... "abcd"^600 are the ones in
# XXHashNative.jl's test suite; the rest are from the xxHash spec /
# python-xxhash. Each is (input, seed, expected).
const XXH64_VECTORS = [
    (UInt8[], 0, 0xef46db3751d8e999),
    (codeunits("ab"), 0, 0x65f708ca92d04a61),
    (codeunits("abc"), 0, 0x44bc2cf5ad770999),
    (codeunits("abcde"), 0, 0x07e3670c0c8dc7eb),
    (codeunits("abcdefghijklm"), 0, 0x934adbc0ebc51325),
    (codeunits("abcdefghijklmnopqrstuvwxyz"), 0, 0xcfe1f278fa89835c),
    (codeunits(repeat("abcdefghijklmnopqrstuvwxyz", 8)), 0, 0xea1e82fca403bfab),
    (codeunits(repeat("abcdefghijklmnopqrstuvwxyz", 64)), 0, 0xe5f9c4bfb7047c1a),
    (codeunits(repeat("abcd", 100)), 0, 0xd43294be5ee68f13),   # < 1024 bytes
    (codeunits(repeat("abcd", 256)), 0, 0xf48efa325cbf8d2f),   # exactly 1024
    (codeunits(repeat("abcd", 300)), 0, 0x8f7f794247c25ab7),
    (codeunits(repeat("abcd", 512)), 0, 0x06dc34a3a4b9b3e3),   # exactly 2048
    (codeunits(repeat("abcd", 600)), 0, 0xa2779f6bd7a05689),
    (codeunits("Nobody inspects the spammish repetition"), 0, 0xfbcea83c8a378bf1),
    (Vector{UInt8}(0:255), 0, 0x1facbe8406cd904b),
    (Vector{UInt8}(0:255), 42, 0xe212741fa701583d),
]

pattern(n) = UInt8[(i * 31 + (i >> 5) + 7) % 256 for i in 0:n-1]

@testset "XXH64 reference vectors ($name)" for (name, impl) in XXH64_IMPLEMENTATIONS
    for (input, seed, expected) in XXH64_VECTORS
        data = Vector{UInt8}(input)
        @test hash_oneshot(impl, data, UInt64(seed)) == expected
        @test hash_streaming(impl, data, (length(data) + 1,), UInt64(seed)) == expected
        @test hash_streaming(impl, data, (1, 7, 32, 33), UInt64(seed)) == expected
    end
    # empty stream
    @test xxh64_digest(impl, xxh64_init(impl, UInt64(0))) == 0xef46db3751d8e999
end

@testset "XXH64 convenience API (native)" begin
    # as in XXHashNative.jl: vectors, strings, views
    for (input, seed, expected) in XXH64_VECTORS
        @test XX.xxh64(input, UInt64(seed)) == expected
        @test XX.digest!(XX.update!(XX.XXH64State(UInt64(seed)), input)) == expected
    end
    a = repeat("abcd", 300)
    @test XX.xxh64(a) == 0x8f7f794247c25ab7
    @test XX.xxh64(@view codeunits(a)[begin+4:1024+4]) == 0xf48efa325cbf8d2f
    # non-contiguous input (copied) and SubString
    x = pattern(1000)
    @test XX.xxh64(view(x, 1:2:999)) == XX.xxh64(x[1:2:999])
    @test XX.xxh64(view(x, 1000:-1:1)) == XX.xxh64(reverse(x))
    s = "The quick brown fox jumps over the lazy dog. "^9
    @test XX.xxh64(SubString(s, 3, 300)) == XX.xxh64(Vector{UInt8}(s[3:300]))
    # digest! does not modify the state
    st = XX.XXH64State(UInt64(7))
    XX.update!(st, "hello ")
    @test XX.digest!(st) == XX.digest!(st) == XX.xxh64("hello ", UInt64(7))
    XX.update!(st, "world, this message is longer than one stripe")
    @test XX.digest!(st) == XX.xxh64("hello world, this message is longer than one stripe", UInt64(7))
end

# A minimal AbstractVector with offset indices (exercises the in-place
# indexed path with firstindex != 1), as in XXHashNative.jl's tests.
struct OffsetBytes <: AbstractVector{UInt8}
    data::Vector{UInt8}
end
Base.size(v::OffsetBytes) = size(v.data)
Base.axes(v::OffsetBytes) = (0:length(v.data)-1,)
Base.getindex(v::OffsetBytes, i::Int) = v.data[i + 1]
Base.IndexStyle(::Type{OffsetBytes}) = IndexLinear()

@testset "XXH64 non-contiguous input (read in place)" begin
    for n in vcat(0:130, [255, 256, 257, 1000, 4096, 10_007])
        x = pattern(n)
        ref = XX.xxh64(x)
        seed = UInt64(n) * 0x9E3779B97F4A7C15
        for v in (OffsetBytes(x), view(x, 1:1:n))
            @test XX.xxh64(v) == ref
            @test XX.xxh64(v, seed) == XX.xxh64(x, seed)
        end
        @test XX.xxh64(view(x, n:-1:1)) == XX.xxh64(reverse(x))
        @test XX.xxh64(view(x, 1:2:n)) == XX.xxh64(x[1:2:n])
        # streaming with uneven pieces of a non-contiguous input
        for step in (1, 7, 31, 32, 33, 100)
            st = XX.XXH64State()
            i = 0
            while i < n
                k = min(step, n - i)
                XX.update!(st, OffsetBytes(x[i+1:i+k]))
                i += k
            end
            @test XX.digest!(st) == ref
        end
    end
    # the checksum helpers feed non-contiguous input to any implementation in chunks
    x = pattern(20_000)
    strided = view(x, 1:3:20_000)
    for (name, impl) in XXH64_IMPLEMENTATIONS
        Zstandard.with_xxh64_implementation(impl) do
            @test XX.content_checksum(strided) == XX.xxh64(x[1:3:20_000]) % UInt32
            @test XX.content_checksum(OffsetBytes(x)) == XX.xxh64(x) % UInt32
            c = XX.ChecksumState()
            XX.checksum_update!(c, view(x, 1:2:9_999))
            XX.checksum_update!(c, OffsetBytes(x[10_000:end]))
            @test XX.checksum_digest(c) == XX.xxh64(vcat(x[1:2:9_999], x[10_000:end])) % UInt32
        end
    end
end

@testset "XXH64 implementations agree" begin
    ref = LibXXH64()
    others = [(name, impl) for (name, impl) in XXH64_IMPLEMENTATIONS if !(impl isa LibXXH64)]
    seeds(n) = (UInt64(0), UInt64(1), UInt64(0xdeadbeef), UInt64(1) << 32, UInt64(n) * 0x9E3779B97F4A7C15)
    for n in vcat(0:300, [511, 512, 513, 1023, 1024, 4096, 65_537, 1 << 20])
        x = pattern(n)
        for seed in seeds(n)
            expected = hash_oneshot(ref, x, seed)
            @test hash_streaming(ref, x, (13, 1, 64), seed) == expected
            for (name, impl) in others
                @test hash_oneshot(impl, x, seed) == expected
                n <= 300 && @test hash_streaming(impl, x, (1, 7, 31, 32, 33, 100), seed) == expected
            end
        end
    end
    # streaming multi-chunk, as in XXHashNative.jl: split at every point
    combined = Vector{UInt8}(repeat("abcdefghijklmnopqrstuvwxyz", 3))
    expected = hash_oneshot(ref, combined)
    for (name, impl) in XXH64_IMPLEMENTATIONS, split in 0:length(combined)
        st = xxh64_init(impl, UInt64(0))
        GC.@preserve combined begin
            st = xxh64_update!(impl, st, pointer(combined), split)
            st = xxh64_update!(impl, st, pointer(combined) + split, length(combined) - split)
        end
        @test xxh64_digest(impl, st) == expected
    end
end

frame_trailer(frame) = ltoh(only(reinterpret(UInt32, frame[end-3:end])))

@testset "XXH64 vs Zstandard frame checksum" begin
    # Frames store the low 32 bits of XXH64(content) little-endian at the end.
    inputs = ["", "hello world", "abcde", "abcdefghijklmnopqrstuvwxyz", repeat("abcd", 100),
              repeat("abcd", 256), repeat("abcd", 300), repeat("abcd", 512), repeat("abcd", 600),
              String(pattern(300_000))]
    for input in inputs
        src = Vector{UInt8}(input)
        f = tempname(); write(f, src)
        frame = read(`$(Zstd_jll.zstd()) -q -3 --check -c $f`)        # libzstd
        stored = frame_trailer(frame)
        @test frame_trailer(compress(src; checksum=true)) == stored
        for (name, impl) in XXH64_IMPLEMENTATIONS
            @test hash_oneshot(impl, src) % UInt32 == stored
        end
    end
end

# A deliberately wrong implementation, to prove the codec uses the selected one.
struct ZeroXXH64 <: AbstractXXH64 end
xxh64(::ZeroXXH64, p::Ptr{UInt8}, n::Int, seed::UInt64) = UInt64(0)
xxh64_init(::ZeroXXH64, seed::UInt64) = nothing
xxh64_update!(::ZeroXXH64, st, p::Ptr{UInt8}, n::Int) = st
xxh64_digest(::ZeroXXH64, st) = UInt64(0)

@testset "Swappable checksum implementation" begin
    data = pattern(700_000)
    big = repeat(data, 3)
    ref_frame = compress(data; checksum=true)
    ref_mt = compress(big; checksum=true, nthreads=2, level=1)
    multi = vcat(ref_frame, compress(data[1:200_000]; checksum=true), ref_frame)
    for (name, impl) in XXH64_IMPLEMENTATIONS
        Zstandard.with_xxh64_implementation(impl) do
            @test Zstandard.XXH64_IMPLEMENTATION[] === impl
            # compression: identical frames whichever implementation computes the checksum
            @test compress(data; checksum=true) == ref_frame
            @test compress(big; checksum=true, nthreads=2, level=1) == ref_mt
            buf = IOBuffer()
            s = Zstandard.ZstdCompressorStream(buf; checksum=true, close_io=false)
            write(s, data); close(s)
            sc = take!(buf)
            @test transcode(CodecZstd.ZstdDecompressor, sc) == data
            # decompression verifies with the selected implementation
            @test decompress(ref_frame) == data
            @test decompress(multi; nthreads=4) == vcat(data, data[1:200_000], data)
            @test read(Zstandard.ZstdDecompressorStream(IOBuffer(sc))) == data
            @test transcode(ZstandardDecompressor(), ref_frame) == data
        end
    end
    @test Zstandard.XXH64_IMPLEMENTATION[] isa NativeXXH64   # scope restored

    # the selected implementation really is the one in use
    Zstandard.with_xxh64_implementation(ZeroXXH64()) do
        @test_throws ZstdError decompress(ref_frame)
        @test_throws ZstdError decompress(multi; nthreads=4)
        @test_throws ZstdError read(Zstandard.ZstdDecompressorStream(IOBuffer(ref_frame)))
        bad = compress(data; checksum=true)
        @test bad[end-3:end] == zeros(UInt8, 4)
        @test decompress(compress(data)) == data          # no checksum: unaffected
    end
    @test_throws ZstdError decompress(Zstandard.with_xxh64_implementation(() -> compress(data; checksum=true), ZeroXXH64()))
end
