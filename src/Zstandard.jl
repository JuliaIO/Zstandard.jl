module Zstandard

export decompress, compress, ZstdDecompressorStream, ZstdCompressorStream, ZstdDictionary, ZstdDictionarySet,
       parse_dictionary, ZstdError, ZstandardCompressor, ZstandardDecompressor,
       ZstdFrameHeader, frame_header, frame_content_size, frame_compressed_size, frame_dict_id,
       decompressed_size, is_zstd_frame, is_skippable_frame, skippable_frame, read_skippable_frame,
       train_dictionary, finalize_dictionary, PreparedDictionary, prepare_dictionary,
       ZstdCompressionContext, ZstdDecompressionContext, compress!, decompress!,
       compress_seekable, ZstdSeekTable, seek_table, decompress_range,
       estimate_compression_memory, estimate_decompression_memory, stream_progress,
       ZstdSequence, generate_sequences, compress_sequences, compress_bound, decompress_bound

# Swappable XXH64 implementation for frame checksums (see `Zstandard.XXHash`)
# (`public` is Julia 1.11 syntax; on 1.10 these are simply unexported)
@static if VERSION >= v"1.11.0-DEV.469"
    eval(Expr(:public, :XXHash, :AbstractXXH64, :NativeXXH64, :XXH64_IMPLEMENTATION, :with_xxh64_implementation))
end

include("xxhash.jl")

include("decoder.jl")
using .Decoder: ZstdError, ZstdDictionary, ZstdDictionarySet, parse_dictionary, DecoderState, decompress_frames,
                DecodeDict, DictArg, decode_dict

include("frameinfo.jl")

include("encoder.jl")
using .Encoder: CompressionContext, compress_frame!, mt_layout, compress_job!, frame_header_bytes,
                train_dictionary, finalize_dictionary, PreparedDictionary, prepare_dictionary
using .XXHash: content_checksum, AbstractXXH64, NativeXXH64, XXH64_IMPLEMENTATION, with_xxh64_implementation

include("streaming.jl")
using .Streaming: ZstdDecompressorStream, ZstdCompressorStream, stream_progress

include("codecs.jl")
include("pools.jl")
include("compress.jl")
include("decompress.jl")
include("context.jl")
include("seekable.jl")
include("estimate.jl")
include("sequences.jl")
include("precompile.jl")

end # module
