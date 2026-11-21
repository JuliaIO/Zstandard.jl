# API Reference

```@index
```

## Public API

Exported names can be used after `using Zstandard`; the other public names are
used as `Zstandard.name`.

```@autodocs
Modules = [Zstandard, Zstandard.Decoder, Zstandard.Encoder, Zstandard.Streaming]
Filter = t -> begin
    n = try nameof(t) catch; nothing end
    n isa Symbol && Base.ispublic(Zstandard, n) && isdefined(Zstandard, n) && getfield(Zstandard, n) === t
end
```

```@docs
Base.parse(::Type{ZstandardDictionary}, ::AbstractVector{UInt8})
```

## Internals

These are implementation details and may change without notice.

```@autodocs
Modules = [Zstandard, Zstandard.Decoder, Zstandard.Encoder, Zstandard.Streaming, Zstandard.XXHash]
Filter = t -> begin
    n = try nameof(t) catch; nothing end
    t !== Base.parse &&
        !(n isa Symbol && Base.ispublic(Zstandard, n) && isdefined(Zstandard, n) && getfield(Zstandard, n) === t)
end
```
