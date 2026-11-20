# TranscodingStreams codec stubs (defined by the package extension) and error hints.
# Included in module Zstandard.

"""
    ZstandardCompressor(; level=3, checksum=false, dict=nothing, window_log=nothing, ...)

A [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl) codec
compressing to the Zstandard format, for use with `transcode`,
`TranscodingStream`, etc. Available once `TranscodingStreams` is loaded.
Accepts the parameter and frame keywords of [`compress`](@ref) (`window_log`,
..., `content_size`, `dict_id`, `magicless`), and `size_hint` (see
`ZstdCompressorStream`) for streams whose size is not pledged, and `long` and
`nthreads` as for `ZstdCompressorStream`.

TranscodingStreams does not pass `flush` on to codecs, so flushing a
`TranscodingStream` does not make the data written so far decodable; write
`TranscodingStreams.TOKEN_END` to end the frame, or use `ZstdCompressorStream`,
whose `flush` emits a block that decoders can read before the frame ends.

```julia
using Zstandard, TranscodingStreams
compressed = transcode(ZstandardCompressor(level=5), data)
stream = TranscodingStream(ZstandardCompressor(), open("out.zst", "w"))
```
"""
function ZstandardCompressor end

"""
    ZstandardDecompressor(; dict=nothing, max_window_size=128 MiB, magicless=false)

A [TranscodingStreams.jl](https://github.com/JuliaIO/TranscodingStreams.jl) codec
decoding Zstandard data (concatenated and skippable frames included). Frames
with a window larger than `max_window_size` are rejected (see
`ZstdDecompressorStream`). With `magicless=true`, frames have no magic
numbers (see `compress`).
Available once `TranscodingStreams` is loaded.
"""
function ZstandardDecompressor end

function __init__()
    if isdefined(Base.Experimental, :register_error_hint)
        Base.Experimental.register_error_hint(MethodError) do io, exc, argtypes, kwargs
            if (exc.f === ZstandardCompressor || exc.f === ZstandardDecompressor) &&
               Base.get_extension(@__MODULE__, :ZstandardTranscodingStreamsExt) === nothing
                print(io, "\n$(exc.f) requires TranscodingStreams.jl; run `using TranscodingStreams` first.")
            end
        end
    end
end
