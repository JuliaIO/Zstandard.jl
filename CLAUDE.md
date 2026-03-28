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
julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tee temp/test_output.txt | grep -A1 -E "Test Summary|Pass|Error|Fail|tests passed|errored"
```

Add a grep after the tee if needed. Rather than rerunning the same tests to reexamine the output, grep `temp/test_output.txt` as needed.

## Temporary Scripts and Output

Use the `temp/` directory for temporary scripts or output rather than `/tmp` to keep file usage within this directory or subdirectories.

# Session Name

The current session name for work here is "expand-zstandard-compression"
