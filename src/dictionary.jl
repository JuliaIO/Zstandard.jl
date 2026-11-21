# Zstandard dictionaries for decoding: ZstandardDictionary (parse_dictionary),
# ZstandardDictionarySet, and choosing the dictionary for each frame.
# Included in module Decoder (uses its FSE and Huffman table builders).

# ---------------------------------------------------------------------------
# Dictionary
# ---------------------------------------------------------------------------

"""
    ZstandardDictionary

A parsed Zstandard dictionary (raw content or formatted with entropy tables).
Create with [`parse_dictionary`](@ref). Use [`dictionary_id`](@ref) and
[`dictionary_content`](@ref) to inspect it; its fields are internal.
"""
struct ZstandardDictionary
    id::UInt32
    huf::Vector{UInt16}       # decoding tables; empty if absent
    huf_log::Int
    ll::Vector{UInt64}
    ml::Vector{UInt64}
    of::Vector{UInt64}
    rep_offsets::NTuple{3,Int}
    content::Vector{UInt8}
    # entropy statistics, used to build matching encoding tables
    huf_weights::Vector{UInt8}
    ll_norm::Vector{Int16}
    ml_norm::Vector{Int16}
    of_norm::Vector{Int16}
end

"""
    ZstandardDictionary(content::AbstractVector{UInt8})

A raw-content dictionary (ID 0): `content` is used as history preceding the
data, without entropy tables. Same as `parse_dictionary` for data that does
not start with the dictionary magic number.
"""
ZstandardDictionary(content::AbstractVector{UInt8}) =
    ZstandardDictionary(UInt32(0), UInt16[], 0, UInt64[], UInt64[], UInt64[], (1, 4, 8),
                        Vector{UInt8}(content), UInt8[], Int16[], Int16[], Int16[])

"""
    dictionary_id(dict::ZstandardDictionary) -> UInt32

The dictionary's ID, as recorded in the frames compressed with it (libzstd's
`ZDICT_getDictID`); `0` for a raw-content dictionary. Compare with
[`frame_dict_id`](@ref Zstandard.frame_dict_id) to find the dictionary a frame needs.
"""
dictionary_id(d::ZstandardDictionary) = d.id

"""
    dictionary_content(dict::ZstandardDictionary) -> Vector{UInt8}

The dictionary's content: the bytes that precede each frame's data as match
history (for a formatted dictionary, what follows its entropy tables). The
returned vector is the dictionary's own and must not be modified.
"""
dictionary_content(d::ZstandardDictionary) = d.content

has_entropy(d::ZstandardDictionary) = !isempty(d.huf)

const DICT_MAGIC = 0xEC30A437

"""
    parse_dictionary(data::AbstractVector{UInt8}) -> ZstandardDictionary

Parse a Zstandard dictionary. Data starting with the dictionary magic number
`0xEC30A437` is parsed as a formatted dictionary (ID, entropy tables, repeat
offsets, content); anything else is treated as raw content with ID 0.
"""
function parse_dictionary(data::AbstractVector{UInt8})
    d = Vector{UInt8}(data)
    if length(d) >= 8 && ltoh(reinterpret(UInt32, view(d, 1:4))[1]) == DICT_MAGIC
        id = ltoh(reinterpret(UInt32, view(d, 5:8))[1])
        norm = zeros(Int16, 256); symnext = zeros(UInt16, 256); tabsym = zeros(UInt8, 4096)
        ws = zeros(UInt8, 256); wtable = UInt64[]
        huf = UInt16[]; ll = UInt64[]; ml = UInt64[]; of = UInt64[]
        pos = 9
        GC.@preserve d begin
            p = pointer(d)
            rem() = length(d) - pos + 1
            tl, n, nw = read_huf_table!(huf, ws, p + pos - 1, rem(), norm, symnext, tabsym, wtable)
            pos += n
            weights = ws[1:nw]
            nsym, al, n = read_fse_header!(norm, p + pos - 1, rem(), 32, OF_MAX_AL); pos += n
            build_fse_table!(of, norm, nsym, al, OF_BASE, OF_BITS, symnext, tabsym)
            of_norm = norm[1:nsym]
            nsym, al, n = read_fse_header!(norm, p + pos - 1, rem(), 53, ML_MAX_AL); pos += n
            build_fse_table!(ml, norm, nsym, al, ML_BASE, ML_BITS, symnext, tabsym)
            ml_norm = norm[1:nsym]
            nsym, al, n = read_fse_header!(norm, p + pos - 1, rem(), 36, LL_MAX_AL); pos += n
            build_fse_table!(ll, norm, nsym, al, LL_BASE, LL_BITS, symnext, tabsym)
            ll_norm = norm[1:nsym]
            rem() < 12 && zerr("truncated dictionary")
            r1 = Int(load32(p + pos - 1)); r2 = Int(load32(p + pos + 3)); r3 = Int(load32(p + pos + 7))
            pos += 12
        end
        content = d[pos:end]
        for r in (r1, r2, r3)
            (r == 0 || r > length(content)) && zerr("invalid dictionary repeat offset")
        end
        return ZstandardDictionary(id, huf, tl, ll, ml, of, (r1, r2, r3), content,
                              weights, ll_norm, ml_norm, of_norm)
    end
    return ZstandardDictionary(d)
end

"""
    ZstandardDictionarySet(dicts; default=nothing)
    ZstandardDictionarySet(dicts::ZstandardDictionary...; default=nothing)

Several dictionaries for decoding data whose frames use different dictionaries
(as libzstd's `ZSTD_d_refMultipleDDicts`). Each frame's dictionary is chosen
by the dictionary ID in its header:

- A frame with a nonzero ID uses the dictionary with that ID; if the set has
  none, decoding throws a [`ZstandardError`](@ref).
- A frame with ID 0 uses `default`, or no dictionary when `default` is
  `nothing`.

A frame header does not say whether an ID-0 frame was written without a
dictionary, with a raw-content dictionary, or with a formatted dictionary and
`dict_id=false`, so every ID-0 frame gets the same `default`. A raw-content
default is harmless for frames written without a dictionary. A formatted
default is not in general: frames are decoded starting from its repeat
offsets, so if those differ from the standard 1, 4, 8 (trained dictionaries
keep the standard ones), a frame written without a dictionary can decode to
wrong bytes. Use a formatted `default` only when the ID-0 frames in the data
were written with it.

A dictionary with ID 0 (raw content) among `dicts` becomes the default; at
most one default can be given. Two dictionaries with the same ID but different
contents throw an `ArgumentError`; repeating the same dictionary (or an equal
copy, such as the same file parsed twice) is allowed. A `default` with a
nonzero ID is also selected by its ID.

Anywhere a decoder accepts a `ZstandardDictionary` (`decompress`,
`ZstandardDecompressionContext`, `ZstandardDecompressorStream`, `ZstandardDecompressor`,
`decompress_range`), it also accepts a `ZstandardDictionarySet` or a vector of
dictionaries.

The set iterates over its dictionaries (the default included); `s[id]`
returns the dictionary a frame with dictionary ID `id` would use (`id = 0`:
the default), throwing a `KeyError` if there is none, and `haskey(s, id)`
tells whether there is one.

```julia
d1 = parse_dictionary(train_dictionary(samples1))
d2 = parse_dictionary(train_dictionary(samples2))
data = vcat(compress(a; dict=d1), compress(b; dict=d2))
decompress(data, ZstandardDictionarySet(d1, d2)) == vcat(a, b)
```
"""
struct ZstandardDictionarySet
    dicts::Dict{UInt32,ZstandardDictionary}
    default::Union{Nothing,ZstandardDictionary}
    all::Vector{ZstandardDictionary}      # each dictionary once, in the order given
    function ZstandardDictionarySet(dicts::Union{AbstractVector,Tuple}; default::Union{Nothing,ZstandardDictionary}=nothing)
        byid = Dict{UInt32,ZstandardDictionary}()
        all = ZstandardDictionary[]
        function add!(d)
            old = get(byid, d.id, nothing)
            if old === nothing
                byid[d.id] = d
                push!(all, d)
            elseif !same_dictionary(old, d)
                throw(ArgumentError("dictionary set has two different dictionaries with ID $(d.id)"))
            end
        end
        def = default
        if def !== nothing
            def.id == 0 ? push!(all, def) : add!(def)
        end
        for d in dicts
            d isa ZstandardDictionary ||
                throw(ArgumentError("dictionary set elements must be ZstandardDictionary, got $(typeof(d))"))
            if d.id != 0
                add!(d)
            elseif def === nothing
                def = d
                push!(all, d)
            elseif !(def.id == 0 && same_dictionary(def, d))
                throw(ArgumentError("dictionary set has more than one default (ID 0) dictionary"))
            end
        end
        return new(byid, def, all)
    end
end
ZstandardDictionarySet(dicts::ZstandardDictionary...; default::Union{Nothing,ZstandardDictionary}=nothing) =
    ZstandardDictionarySet(dicts; default)

# Equal contents decode identically, whether or not they are the same object
same_dictionary(a::ZstandardDictionary, b::ZstandardDictionary) =
    a === b || all(getfield(a, f) == getfield(b, f) for f in fieldnames(ZstandardDictionary))

Base.length(s::ZstandardDictionarySet) = length(s.all)
Base.eltype(::Type{ZstandardDictionarySet}) = ZstandardDictionary
Base.iterate(s::ZstandardDictionarySet, i::Int=1) = i > length(s.all) ? nothing : (s.all[i], i + 1)
Base.haskey(s::ZstandardDictionarySet, id::Integer) =
    id == 0 ? s.default !== nothing : (0 < id <= typemax(UInt32) && haskey(s.dicts, UInt32(id)))
function Base.getindex(s::ZstandardDictionarySet, id::Integer)
    haskey(s, id) || throw(KeyError(id))
    return id == 0 ? s.default : s.dicts[UInt32(id)]
end
Base.show(io::IO, s::ZstandardDictionarySet) =
    print(io, "ZstandardDictionarySet(", join(sort!(collect(keys(s.dicts))), ", "),
          s.default === nothing ? "" : "; default=$(s.default.id)", ")")

# What a decoder accepts as its dictionary argument (public entry points also
# take a vector of dictionaries, converted to a set by `decode_dict`)
const DecodeDict = Union{Nothing,ZstandardDictionary,ZstandardDictionarySet}

# A dictionary given positionally or as the `dict` keyword (not both)
function positional_or_keyword_dict(positional, keyword)
    positional === nothing && return keyword
    keyword === nothing ||
        throw(ArgumentError("give the dictionary either positionally or as the dict keyword, not both"))
    return positional
end
const DictArg = Union{DecodeDict,AbstractVector}
decode_dict(d::DecodeDict) = d
function decode_dict(v::AbstractVector)
    v isa AbstractVector{UInt8} &&
        throw(ArgumentError("a dictionary must be a ZstandardDictionary: use parse_dictionary(bytes)"))
    return ZstandardDictionarySet(v)
end

# The dictionary for a frame whose header has dictionary ID `id`
function frame_dict(dict::Nothing, id::UInt32)
    id != 0 && zerr("frame requires dictionary ID $id")
    return nothing
end
function frame_dict(dict::ZstandardDictionary, id::UInt32)
    (id != 0 && dict.id != 0 && dict.id != id) &&
        zerr("dictionary ID mismatch: frame requires $id, got $(dict.id)")
    return dict
end
function frame_dict(s::ZstandardDictionarySet, id::UInt32)
    id == 0 && return s.default
    d = get(s.dicts, id, nothing)
    d === nothing && zerr("frame requires dictionary ID $id, which is not in the dictionary set")
    return d
end
