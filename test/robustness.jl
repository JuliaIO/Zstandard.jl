using Zstandard
using Test

# Robustness beyond the bug fixes in test/regressions.jl.

@testset "Streaming decoder errors are sticky" begin
    x = UInt64(2)
    data = UInt8[(x = x * 6364136223846793005 + 1442695040888963407; (x >> 60) % UInt8) for _ in 1:1000]
    bad = compress(data; checksum=true); bad[end] ⊻= 0x01
    s = Zstandard.ZstdDecompressorStream(IOBuffer(bad))
    e1 = try read(s) catch e; e end
    e2 = try read(s) catch e; e end
    @test e1 isa ZstdError
    @test e2 === e1                    # the original error, not an unrelated one
    @test_throws ZstdError eof(s)
end
