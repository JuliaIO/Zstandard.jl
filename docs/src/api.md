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
ZstandardDictionary
ZstandardDictionarySet
parse_dictionary
Zstandard.dictionary_id
Zstandard.dictionary_content
ZstandardError
```

## Internals

These are implementation details and may change without notice.

```@autodocs
Modules = [Zstandard.Decoder, Zstandard.Encoder, Zstandard.Streaming, Zstandard.XXHash]
Filter = t -> !(t in (Zstandard.ZstandardDictionary, Zstandard.ZstandardDictionarySet,
                      Zstandard.parse_dictionary, Zstandard.ZstandardError,
                      Zstandard.dictionary_id, Zstandard.dictionary_content,
                      Zstandard.ZstandardCompressorStream, Zstandard.ZstandardDecompressorStream,
                      Zstandard.stream_progress))
```
