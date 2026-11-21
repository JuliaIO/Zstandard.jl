# API Reference

```@index
```

## Public API

```@autodocs
Modules = [Zstandard]
```

### Dictionaries and errors

```@docs
ZstdDictionary
ZstdDictionarySet
parse_dictionary
ZstdError
```

## Streaming

```@autodocs
Modules = [Zstandard.Streaming]
```

## Internals

These are implementation details and may change without notice.

```@autodocs
Modules = [Zstandard.Decoder, Zstandard.Encoder, Zstandard.XXHash]
Filter = t -> !(t in (Zstandard.ZstdDictionary, Zstandard.ZstdDictionarySet,
                      Zstandard.parse_dictionary, Zstandard.ZstdError))
```
