# API Reference

```@index
```

## Public API

```@autodocs
Modules = [Zstandard]
```

### Streams

```@docs
ZstandardCompressorStream
ZstandardDecompressorStream
Zstandard.stream_progress
```

### Dictionaries and errors

```@docs
ZstdDictionary
ZstdDictionarySet
parse_dictionary
ZstdError
```

## Internals

These are implementation details and may change without notice.

```@autodocs
Modules = [Zstandard.Decoder, Zstandard.Encoder, Zstandard.Streaming, Zstandard.XXHash]
Filter = t -> !(t in (Zstandard.ZstdDictionary, Zstandard.ZstdDictionarySet,
                      Zstandard.parse_dictionary, Zstandard.ZstdError,
                      Zstandard.ZstandardCompressorStream, Zstandard.ZstandardDecompressorStream,
                      Zstandard.stream_progress))
```
