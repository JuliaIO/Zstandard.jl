# Zstandard.jl Development Notes

## Testing Environment

Use `TestEnv` to activate the testing environment (gives access to `CodecZstd` and other test-only deps):

```julia
using TestEnv
TestEnv.activate()
```

Or equivalently, run Julia scripts with `julia --project=test`.

Do NOT use `Pkg.activate("test")` from a script located outside the project root, as paths will be relative to the script location.

## Running Tests

```julia
using Pkg; Pkg.test()
```

Or with output teed to a file:
```bash
julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tee /tmp/test_output.txt
```
