using Documenter
using Zstandard

makedocs(
    sitename = "Zstandard.jl",
    format = Documenter.HTML(),
    modules = [Zstandard],
    pages = [
        "Home" => "index.md",
    ],
    remotes = nothing,
)

deploydocs(
    repo = "github.com/mkitti/Zstandard.jl.git",
)
