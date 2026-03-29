using Documenter
using DocumenterVitepress
using Zstandard

makedocs(;
    sitename = "Zstandard.jl",
    modules = [Zstandard],
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/JuliaIO/Zstandard.jl",
        devbranch = "main",
        devurl = "dev",
    ),
    pages = [
        "Home" => "index.md",
        "API Reference" => "api.md",
    ],
    warnonly = true,
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/JuliaIO/Zstandard.jl",
    target = joinpath(@__DIR__, "build"),
    branch = "gh-pages",
    devbranch = "main",
    push_preview = true,
)
