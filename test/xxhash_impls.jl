# XXH64 implementations wrapped in Zstandard's `AbstractXXH64` interface.
# Shared by the tests (test/xxhash.jl) and the benchmark
# (test/benchmark/xxhash_compare.jl). Adding another implementation means
# defining a subtype and these four methods, then adding it to
# `XXH64_IMPLEMENTATIONS`.

using Zstandard
using Zstandard.XXHash: AbstractXXH64, NativeXXH64
import Zstandard.XXHash: xxh64, xxh64_init, xxh64_update!, xxh64_digest
import XXHashNative
import xxHash_jll

# --- XXHashNative.jl (pure Julia) --------------------------------------------

struct XXHashNativeXXH64 <: AbstractXXH64 end

xxh64(::XXHashNativeXXH64, p::Ptr{UInt8}, n::Int, seed::UInt64) =
    XXHashNative.xxh64(unsafe_wrap(Array, p, n), seed)
xxh64_init(::XXHashNativeXXH64, seed::UInt64) = XXHashNative.XXH64State(seed)
xxh64_update!(::XXHashNativeXXH64, st, p::Ptr{UInt8}, n::Int) =
    XXHashNative.update!(st, unsafe_wrap(Array, p, n))
xxh64_digest(::XXHashNativeXXH64, st) = XXHashNative.digest!(st)

# --- the reference C library (xxHash_jll), called directly -------------------
# (XXhash.jl's `xxh64(data, seed)` truncates the seed to 32 bits, so it is
# not used as a reference.)

struct LibXXH64 <: AbstractXXH64 end

const libxxhash = xxHash_jll.libxxhash

mutable struct LibXXH64State
    ptr::Ptr{Cvoid}
end

xxh64(::LibXXH64, p::Ptr{UInt8}, n::Int, seed::UInt64) =
    ccall((:XXH64, libxxhash), UInt64, (Ptr{UInt8}, Csize_t, UInt64), p, n, seed)

function xxh64_init(::LibXXH64, seed::UInt64)
    st = LibXXH64State(ccall((:XXH64_createState, libxxhash), Ptr{Cvoid}, ()))
    st.ptr == C_NULL && error("XXH64_createState failed")
    finalizer(s -> ccall((:XXH64_freeState, libxxhash), Cint, (Ptr{Cvoid},), s.ptr), st)
    ccall((:XXH64_reset, libxxhash), Cint, (Ptr{Cvoid}, UInt64), st.ptr, seed)
    return st
end

function xxh64_update!(::LibXXH64, st::LibXXH64State, p::Ptr{UInt8}, n::Int)
    ccall((:XXH64_update, libxxhash), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), st.ptr, p, n)
    return st
end

xxh64_digest(::LibXXH64, st::LibXXH64State) =
    ccall((:XXH64_digest, libxxhash), UInt64, (Ptr{Cvoid},), st.ptr)

# --- registry -----------------------------------------------------------------

const XXH64_IMPLEMENTATIONS = [
    "Zstandard.jl (native)" => NativeXXH64(),
    "XXHashNative.jl" => XXHashNativeXXH64(),
    "xxHash C library (xxHash_jll)" => LibXXH64(),
]

# Generic helpers over any implementation.
hash_oneshot(impl::AbstractXXH64, data::Vector{UInt8}, seed::UInt64=UInt64(0)) =
    GC.@preserve data xxh64(impl, pointer(data), length(data), seed)

"""Hash `data` in pieces whose sizes cycle through `steps`."""
function hash_streaming(impl::AbstractXXH64, data::Vector{UInt8}, steps, seed::UInt64=UInt64(0))
    st = xxh64_init(impl, seed)
    i = 1; k = 1
    GC.@preserve data while i <= length(data)
        n = min(steps[k], length(data) - i + 1)
        st = xxh64_update!(impl, st, pointer(data, i), n)
        i += n
        k = k % length(steps) + 1
    end
    return xxh64_digest(impl, st)
end
