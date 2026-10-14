import Darwin
import Foundation

/// Why a folder is shown as one line.
enum FoldReason: UInt8, Equatable {
    case named = 1      // its name says it (node_modules, .git...)
    case besideMarker   // its name is also used for real content, but a file next to it says it is output
    case python         // it holds pyvenv.cfg
    case conda          // it holds conda-meta
    case cache          // it holds CACHEDIR.TAG
    case asked          // --fold
}

/// Folders that nobody reads: the table in this file, described in `docs/commands/neotree.md`.
enum TreeFold {
    private static let always: [String] = [
        "node_modules", "bower_components", "jspm_packages", ".git", ".hg", ".svn", "__pycache__", ".venv", "venv", ".tox", ".nox", ".mypy_cache", ".pytest_cache", ".ruff_cache",
        ".ipynb_checkpoints", ".eggs", "*.egg-info", ".gradle", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".pnpm-store", ".terraform", ".terragrunt-cache",
        ".serverless", ".dart_tool", ".stack-work", "dist-newstyle", "_build", ".build", "DerivedData", "Pods", "Carthage", ".bundle", "CMakeFiles", "cmake-build-*", ".idea", ".cache",
        ".sass-cache", ".nyc_output", "htmlcov", "__MACOSX", "xcuserdata", ".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100", ".TemporaryItems",
        // more of the web: Astro, Vite, Docusaurus, Expo, Vercel, Netlify, Nuxt, Meteor, Elm
        ".astro", ".vite", ".docusaurus", ".expo", ".vercel", ".netlify", ".output", ".yarn-cache", ".npm", ".rpt2_cache", ".rts2_cache_cjs", ".eslintcache", "elm-stuff", ".vuepress",
        // Python: PDM, pixi, hypothesis, type checkers
        "__pypackages__", ".pixi", ".hypothesis", ".pytype", ".pyre", ".pdm-build", ".direnv",
        // Zig, Nim, Crystal, Gleam, OCaml, PureScript, Clojure, Erlang, Elixir, R, Julia, Lua, Haskell
        "zig-cache", ".zig-cache", "zig-out", "nimcache", "nimblecache", ".shards", "_opam", ".spago", ".cpcache", ".shadow-cljs", ".rebar3", ".elixir_ls", ".Rproj.user", "renv", "packrat",
        ".luarocks", ".cabal-sandbox", ".ghc.environment", ".stack",
        // JVM and Android: Bloop, Metals, BSP, Kotlin native, the C++ side of Android
        ".bsp", ".bloop", ".metals", ".konan", ".cxx", ".externalNativeBuild", ".kotlin",
        // Apple: Swift Package Manager, Xcode, Carthage
        ".swiftpm", "SourcePackages", ".xcodebuild",
        // C and C++ tools, Bazel, Buck, Pants, Gradle wrappers' caches
        ".ccls-cache", ".clangd", "buck-out", "bazel-*", ".bazel", ".pants.d", "conan_build", ".conan",
        // game engines
        ".godot", ".import", ".unity",
        // editors and shells
        ".vs", ".vscode-test", ".history", ".ionide", ".fleet", ".eldev", ".emacs.d.cache",
        // other
        ".mise", ".asdf", ".nuget", ".dotnet", ".m2", ".ivy2", ".sbt", ".coursier", ".cargo", ".rustup", ".nvm", ".pyenv", ".rbenv", ".gem", ".bun", ".deno",
    ]

    /// A name that real content also has: folded only when one of these stands in the same folder.
    private static let beside: [(name: String, markers: [String])] = [
        ("target", ["Cargo.toml", "pom.xml", "build.sbt"]),
        ("build", ["package.json", "CMakeLists.txt", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pubspec.yaml", "setup.py", "pyproject.toml", "meson.build", "Makefile", "*.xcodeproj"]),
        ("dist", ["package.json", "setup.py", "pyproject.toml", "tsconfig.json"]),
        ("out", ["package.json", "build.gradle", "build.gradle.kts", "CMakeLists.txt", "tsconfig.json"]),
        ("coverage", ["package.json", "pyproject.toml"]),
        ("vendor", ["go.mod", "composer.json", "Gemfile"]),
        ("deps", ["mix.exs"]),
        ("bin", ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"]),
        ("obj", ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"]),
        ("packages", ["*.sln", "packages.config"]),
        ("TestResults", ["*.sln", "*.csproj"]),
        ("lib", ["shard.yml", "dune-project"]),
        ("node", ["pom.xml"]),
        ("output", ["spago.dhall", "spago.yaml", "packages.dhall"]),
        // Unity and Unreal
        ("Library", ["ProjectSettings", "Assets"]),
        ("Temp", ["ProjectSettings", "Assets"]),
        ("Obj", ["ProjectSettings", "Assets"]),
        ("Logs", ["ProjectSettings"]),
        ("Intermediate", ["*.uproject"]),
        ("Binaries", ["*.uproject"]),
        ("Saved", ["*.uproject"]),
        ("DerivedDataCache", ["*.uproject"]),
        // Gradle and Maven projects: build output next to a wrapper or a module file
        ("bin", ["build.gradle", "build.gradle.kts", "pom.xml"]),
        ("local", ["cpanfile", "Makefile.PL"]),
        ("result", ["flake.nix", "default.nix", "shell.nix"]),
        ("_site", ["_config.yml", "_config.yaml", "Gemfile"]),
        ("public", ["config.toml", "hugo.toml", "hugo.yaml", "gatsby-config.js"]),
        ("site", ["mkdocs.yml", "mkdocs.yaml"]),
        ("storybook-static", ["package.json"]),
        ("tmp", ["Gemfile", "package.json"]),
        ("log", ["Gemfile"]),
    ]

    private static func matches(_ pattern: String, _ name: String) -> Bool { fnmatch(pattern, name, 0) == 0 }

    /// `siblings`: the names in the folder that holds it (asked for only when a name could be real content); `insideHas`: whether the folder holds a name.
    static func reason(name: String, siblings: () -> [String], insideHas: (String) -> Bool, extra: [String]) -> FoldReason? {
        if extra.contains(where: { matches($0, name) }) { return .asked }
        if always.contains(where: { matches($0, name) }) { return .named }
        for rule in beside where rule.name == name {
            let around = siblings()
            if rule.markers.contains(where: { m in around.contains { matches(m, $0) } }) { return .besideMarker }
        }
        if insideHas("pyvenv.cfg") { return .python }
        if insideHas("conda-meta") { return .conda }
        if insideHas("CACHEDIR.TAG") { return .cache }
        return nil
    }

    /// Entries that are never listed.
    static func isJunk(_ name: String) -> Bool { name == ".DS_Store" || name == ".localized" || name.hasPrefix("._") }
}
