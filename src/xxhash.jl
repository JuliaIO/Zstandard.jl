# XXH64 (https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md), the
# content checksum of the Zstandard format.
#
# The four accumulators stay in local variables (registers) and input words
# are read with unaligned 8-byte loads. XXH64's lanes are serial
# multiply/rotate chains, so 4-wide SIMD does not help: vector 64-bit
# multiplies (vpmullq) have far higher latency than scalar imul, and a loop
# LLVM packs into one vector runs about half as fast. LLVM's SLP vectorizer
# does that packing on its own in some contexts, so each lane passes through
# an empty inline-assembly barrier (`opaque`, zero cost) that keeps the
# stripe loop scalar everywhere.

module XXHash

export xxh64, XXH64State, update!, digest!

const P1 = 0x9E3779B185EBCA87
const P2 = 0xC2B2AE3D27D4EB4F
const P3 = 0x165667B19E3779F9
const P4 = 0x85EBCA77C2B2AE63
const P5 = 0x27D4EB2F165667C5

@inline rotl(x::UInt64, r::Int) = (x << r) | (x >> (64 - r))
@inline xround(acc::UInt64, lane::UInt64) = rotl(acc + lane * P2, 31) * P1
@inline xmerge(acc::UInt64, v::UInt64) = (acc ⊻ xround(UInt64(0), v)) * P1 + P4
@inline ld64(p::Ptr{UInt8}) = ltoh(unsafe_load(Ptr{UInt64}(p)))
# Identity that the optimizer cannot see through (no instructions emitted).
@inline opaque(x::UInt64) = Base.llvmcall("""
    %2 = call i64 asm "", "=r,0"(i64 %0)
    ret i64 %2""", UInt64, Tuple{UInt64}, x)
@inline ld32(p::Ptr{UInt8}) = ltoh(unsafe_load(Ptr{UInt32}(p)))

@inline function stripes(p::Ptr{UInt8}, n::Int, v1::UInt64, v2::UInt64, v3::UInt64, v4::UInt64)
    i = 0
    while i + 32 <= n
        v1 = opaque(xround(v1, ld64(p + i)))
        v2 = opaque(xround(v2, ld64(p + i + 8)))
        v3 = opaque(xround(v3, ld64(p + i + 16)))
        v4 = opaque(xround(v4, ld64(p + i + 24)))
        i += 32
    end
    return v1, v2, v3, v4, i
end

# Hash the final < 32 bytes at p and avalanche.
@inline function finish(h::UInt64, p::Ptr{UInt8}, n::Int)
    i = 0
    while i + 8 <= n
        h ⊻= xround(UInt64(0), ld64(p + i))
        h = rotl(h, 27) * P1 + P4
        i += 8
    end
    if i + 4 <= n
        h ⊻= UInt64(ld32(p + i)) * P1
        h = rotl(h, 23) * P2 + P3
        i += 4
    end
    while i < n
        h ⊻= UInt64(unsafe_load(p + i)) * P5
        h = rotl(h, 11) * P1
        i += 1
    end
    h ⊻= h >> 33; h *= P2
    h ⊻= h >> 29; h *= P3
    h ⊻= h >> 32
    return h
end

@inline converge(v1, v2, v3, v4) =
    xmerge(xmerge(xmerge(xmerge(rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18),
                                v1), v2), v3), v4)

"""
    xxh64(p::Ptr{UInt8}, n, seed=0) -> UInt64
    xxh64(data::AbstractVector{UInt8}, seed=0) -> UInt64

XXH64 hash of `n` bytes at `p`, or of `data`.
"""
function xxh64(p::Ptr{UInt8}, n::Integer, seed::UInt64=UInt64(0))
    n = Int(n)
    if n >= 32
        v1, v2, v3, v4, i = stripes(p, n, seed + P1 + P2, seed + P2, seed, seed - P1)
        h = converge(v1, v2, v3, v4)
    else
        h = seed + P5
        i = 0
    end
    return finish(h + UInt64(n), p + i, n - i)
end

function xxh64(data::AbstractVector{UInt8}, seed::UInt64=UInt64(0))
    if data isa Union{Vector{UInt8}, Base.FastContiguousSubArray{UInt8,1,Vector{UInt8}}}
        return GC.@preserve data xxh64(pointer(data), length(data), seed)
    end
    d = Vector{UInt8}(data)
    return GC.@preserve d xxh64(pointer(d), length(d), seed)
end
xxh64(s::AbstractString, seed::UInt64=UInt64(0)) = xxh64(codeunits(s), seed)

"""
    XXH64State(seed=0)

Incremental XXH64: feed data with `update!(state, data)` (or a pointer and
length), then get the hash with `digest!(state)`.
"""
mutable struct XXH64State
    v1::UInt64
    v2::UInt64
    v3::UInt64
    v4::UInt64
    total::UInt64
    buf::Vector{UInt8}      # partial stripe (< 32 bytes)
    buflen::Int
    seed::UInt64
end

XXH64State(seed::UInt64=UInt64(0)) =
    XXH64State(seed + P1 + P2, seed + P2, seed, seed - P1, 0, zeros(UInt8, 32), 0, seed)

function update!(st::XXH64State, p::Ptr{UInt8}, n::Integer)
    n = Int(n)
    st.total += n
    buf = st.buf
    GC.@preserve buf begin
        bp = pointer(buf)
        if st.buflen + n < 32
            unsafe_copyto!(bp + st.buflen, p, n)
            st.buflen += n
            return st
        end
        v1, v2, v3, v4 = st.v1, st.v2, st.v3, st.v4
        if st.buflen > 0
            k = 32 - st.buflen
            unsafe_copyto!(bp + st.buflen, p, k)
            v1, v2, v3, v4, _ = stripes(bp, 32, v1, v2, v3, v4)
            p += k; n -= k
            st.buflen = 0
        end
        v1, v2, v3, v4, i = stripes(p, n, v1, v2, v3, v4)
        st.v1 = v1; st.v2 = v2; st.v3 = v3; st.v4 = v4
        if i < n
            unsafe_copyto!(bp, p + i, n - i)
            st.buflen = n - i
        end
    end
    return st
end

function update!(st::XXH64State, data::AbstractVector{UInt8})
    if data isa Union{Vector{UInt8}, Base.FastContiguousSubArray{UInt8,1,Vector{UInt8}}}
        return GC.@preserve data update!(st, pointer(data), length(data))
    end
    d = Vector{UInt8}(data)
    return GC.@preserve d update!(st, pointer(d), length(d))
end

function digest!(st::XXH64State)
    h = st.total >= 32 ? converge(st.v1, st.v2, st.v3, st.v4) : st.seed + P5
    buf = st.buf
    return GC.@preserve buf finish(h + st.total, pointer(buf), st.buflen)
end

end # module
