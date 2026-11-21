module Zstandard

# The core API is exported; the rest is public (`Zstandard.name`), so that
# `using Zstandard` brings in few names and does not clash with other packages
export compress, decompress, ZstandardError,
       ZstandardCompressorStream, ZstandardDecompressorStream,
       ZstandardCompressor, ZstandardDecompressor,
       ZstandardDictionary, ZstandardDictionarySet, parse_dictionary, train_dictionary,
       is_zstd_frame

# (`public` is Julia 1.11 syntax; on 1.10 these are simply unexported)
@static if VERSION >= v"1.11.0-DEV.469"
    eval(Expr(:public,
        # frame inspection and skippable frames
        :ZstandardFrameHeader, :frame_header, :frame_content_size, :frame_compressed_size, :frame_dict_id,
        :decompressed_size, :is_skippable_frame, :skippable_frame, :read_skippable_frame,
        # dictionaries
        :dictionary_id, :dictionary_content, :finalize_dictionary, :PreparedDictionary, :prepare_dictionary,
        # reusable contexts
        :ZstandardCompressionContext, :ZstandardDecompressionContext, :compress!, :decompress!,
        # seekable format
        :compress_seekable, :ZstandardSeekTable, :seek_table, :decompress_range,
        # sizes and progress
        :estimate_compression_memory, :estimate_decompression_memory, :compress_bound, :decompress_bound,
        :stream_progress,
        # sequence API (mirrors libzstd's experimental API)
        :ZstandardSequence, :generate_sequences, :compress_sequences))
end

include("xxhash.jl")

include("decoder.jl")
using .Decoder: ZstandardError, ZstandardDictionary, ZstandardDictionarySet, parse_dictionary,
                dictionary_id, dictionary_content, DecoderState, decompress_frames,
                DecodeDict, DictArg, decode_dict, positional_or_keyword_dict

include("frameinfo.jl")

include("encoder.jl")
using .Encoder: CompressionContext, compress_frame!, mt_layout, compress_job!, frame_header_bytes,
                train_dictionary, finalize_dictionary, PreparedDictionary, prepare_dictionary
using .XXHash: content_checksum, AbstractXXH64, NativeXXH64, XXH64_IMPLEMENTATION, with_xxh64_implementation

include("streaming.jl")
using .Streaming: ZstandardDecompressorStream, ZstandardCompressorStream, stream_progress

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
