import Foundation

/// What a developer tool keeps on disk. The kind decides the category: a cache comes back by itself, a download comes back after a download,
/// a version is something installed (a toolchain, an environment, an extension) that has to be installed again.
enum SweepToolKind: Sendable { case caches, downloads, versions }

struct SweepTool: Sendable {
    let name: String
    let kind: SweepToolKind
    /// Folders, with `~` for the home. Only the ones that exist on this Mac are offered, and a tool with none is not shown.
    let paths: [String]
}

/// The tools whose folders are known by name. The list is the whole allowlist: a folder that is not here is never offered.
/// Left out on purpose: anything with a login, a token, a history or a setting in it (`~/.aws`, `~/.docker`, `~/.kube/config`, the Google Cloud
/// folder, `~/.claude`, `~/.codex`, `~/.gemini`, Jupyter, IPython, the shell's history), the databases (`dvc`), Docker's disk image, the editors'
/// Application Support, and folders inside projects. What is directly in `~/Library/Caches` is the application caches' own category.
enum SweepTools {
    static let all: [SweepTool] = [
        // Python
        SweepTool(name: "pipx (cache)", kind: .caches, paths: ["~/.cache/pipx"]),
        SweepTool(name: "Pipenv", kind: .caches, paths: ["~/.cache/pipenv"]),
        SweepTool(name: "PDM", kind: .caches, paths: ["~/.cache/pdm"]),
        SweepTool(name: "Hatch", kind: .caches, paths: ["~/.cache/hatch"]),
        SweepTool(name: "virtualenv", kind: .caches, paths: ["~/.cache/virtualenv"]),
        SweepTool(name: "Python build", kind: .caches, paths: ["~/.cache/python-build"]),
        SweepTool(name: "setuptools", kind: .caches, paths: ["~/.cache/Python-Eggs"]),
        SweepTool(name: "Matplotlib", kind: .caches, paths: ["~/.cache/matplotlib"]),
        SweepTool(name: "tox", kind: .caches, paths: ["~/.cache/tox"]),
        SweepTool(name: "Nox", kind: .caches, paths: ["~/.cache/nox"]),
        SweepTool(name: "coverage.py", kind: .caches, paths: ["~/.cache/coverage"]),
        SweepTool(name: "mypy", kind: .caches, paths: ["~/.cache/mypy"]),
        SweepTool(name: "Pyright", kind: .caches, paths: ["~/.cache/pyright-python"]),
        SweepTool(name: "Ruff", kind: .caches, paths: ["~/.cache/ruff"]),
        SweepTool(name: "Black", kind: .caches, paths: ["~/.cache/black"]),
        SweepTool(name: "Flake8", kind: .caches, paths: ["~/.cache/flake8"]),
        SweepTool(name: "isort", kind: .caches, paths: ["~/.cache/isort"]),
        SweepTool(name: "pip-audit", kind: .caches, paths: ["~/.cache/pip-audit"]),
        SweepTool(name: "pre-commit", kind: .caches, paths: ["~/.cache/pre-commit"]),
        SweepTool(name: "Semgrep", kind: .caches, paths: ["~/.cache/semgrep"]),
        SweepTool(name: "Conda packages", kind: .downloads, paths: ["~/miniforge3/pkgs", "~/miniconda3/pkgs", "~/anaconda3/pkgs"]),
        SweepTool(name: "NLTK data", kind: .downloads, paths: ["~/nltk_data"]),
        // machine learning
        SweepTool(name: "Hugging Face (datasets, Diffusers and the rest)", kind: .downloads,
                  paths: ["~/.cache/huggingface/datasets", "~/.cache/huggingface/diffusers", "~/.cache/huggingface/evaluate", "~/.cache/huggingface/modules",
                          "~/.cache/huggingface/assets", "~/.cache/huggingface/accelerate", "~/.cache/huggingface/xet", "~/.cache/huggingface/transformers"]),
        SweepTool(name: "PyTorch", kind: .downloads, paths: ["~/.cache/torch"]),
        SweepTool(name: "TensorFlow", kind: .downloads, paths: ["~/.cache/tensorflow"]),
        SweepTool(name: "JAX", kind: .caches, paths: ["~/.cache/jax"]),
        SweepTool(name: "ONNX Runtime", kind: .downloads, paths: ["~/.cache/onnx"]),
        SweepTool(name: "Ultralytics YOLO", kind: .downloads, paths: ["~/.cache/ultralytics"]),
        SweepTool(name: "LangChain", kind: .caches, paths: ["~/.cache/langchain"]),
        SweepTool(name: "LiteLLM", kind: .caches, paths: ["~/.cache/litellm"]),
        SweepTool(name: "LlamaIndex", kind: .downloads, paths: ["~/.cache/llama_index"]),
        SweepTool(name: "llama.cpp", kind: .downloads, paths: ["~/.cache/llama.cpp"]),
        SweepTool(name: "LM Studio (cache)", kind: .caches, paths: ["~/.cache/lm-studio"]),
        SweepTool(name: "LM Studio (models)", kind: .downloads, paths: ["~/.lmstudio/models"]),
        SweepTool(name: "Ollama (models)", kind: .downloads, paths: ["~/.ollama/models"]),
        SweepTool(name: "vLLM", kind: .downloads, paths: ["~/.cache/vllm"]),
        SweepTool(name: "MLflow", kind: .caches, paths: ["~/.cache/mlflow"]),
        SweepTool(name: "Weights & Biases", kind: .caches, paths: ["~/.cache/wandb"]),
        SweepTool(name: "Kaggle Hub", kind: .downloads, paths: ["~/.cache/kagglehub"]),
        SweepTool(name: "ChromaDB (downloaded models)", kind: .downloads, paths: ["~/.cache/chroma"]),
        // compilers and build tools
        SweepTool(name: "Cargo (registry, git)", kind: .downloads, paths: ["~/.cargo/registry", "~/.cargo/git"]),
        SweepTool(name: "sccache", kind: .caches, paths: ["~/.cache/sccache"]),
        SweepTool(name: "ccache", kind: .caches, paths: ["~/.cache/ccache"]),
        SweepTool(name: "CMake", kind: .caches, paths: ["~/.cache/cmake"]),
        SweepTool(name: "Ninja", kind: .caches, paths: ["~/.cache/ninja"]),
        SweepTool(name: "clangd", kind: .caches, paths: ["~/.cache/clangd"]),
        SweepTool(name: "Bazel", kind: .downloads, paths: ["~/.cache/bazel"]),
        SweepTool(name: "Nix", kind: .caches, paths: ["~/.cache/nix"]),
        SweepTool(name: "Zig", kind: .caches, paths: ["~/.cache/zig"]),
        SweepTool(name: "Go modules", kind: .downloads, paths: ["~/go/pkg/mod"]),
        SweepTool(name: "Maven", kind: .downloads, paths: ["~/.m2/repository"]),
        SweepTool(name: "sbt", kind: .downloads, paths: ["~/.cache/sbt", "~/.sbt/boot"]),
        SweepTool(name: "Kotlin/Native", kind: .downloads, paths: ["~/.konan"]),
        SweepTool(name: "Cabal", kind: .downloads, paths: ["~/.cache/cabal", "~/.cabal/store"]),
        SweepTool(name: "rebar3", kind: .caches, paths: ["~/.cache/rebar3"]),
        SweepTool(name: "Hex", kind: .downloads, paths: ["~/.hex/cache"]),
        SweepTool(name: "NuGet", kind: .downloads, paths: ["~/.nuget/packages"]),
        SweepTool(name: "RubyGems (cache)", kind: .caches, paths: ["~/.cache/gem"]),
        SweepTool(name: "Bundler", kind: .downloads, paths: ["~/.bundle/cache"]),
        SweepTool(name: "mise (cache)", kind: .caches, paths: ["~/.cache/mise"]),
        // JavaScript
        SweepTool(name: "Bun", kind: .downloads, paths: ["~/.bun/install/cache"]),
        SweepTool(name: "Yarn Berry", kind: .downloads, paths: ["~/.yarn/berry/cache"]),
        SweepTool(name: "Babel", kind: .caches, paths: ["~/.cache/babel-loader"]),
        SweepTool(name: "Webpack", kind: .caches, paths: ["~/.cache/webpack"]),
        SweepTool(name: "Vite", kind: .caches, paths: ["~/.cache/vite"]),
        SweepTool(name: "Turborepo", kind: .caches, paths: ["~/.cache/turbo"]),
        SweepTool(name: "ESLint", kind: .caches, paths: ["~/.cache/eslint"]),
        SweepTool(name: "Tailwind CSS", kind: .caches, paths: ["~/.cache/tailwindcss"]),
        SweepTool(name: "Prisma", kind: .downloads, paths: ["~/.cache/prisma"]),
        SweepTool(name: "Selenium Manager", kind: .downloads, paths: ["~/.cache/selenium"]),
        SweepTool(name: "Expo", kind: .downloads, paths: ["~/.expo"]),
        // containers and cloud (the logins stay where they are)
        SweepTool(name: "kubectl (cache)", kind: .caches, paths: ["~/.kube/cache"]),
        SweepTool(name: "Terraform (plugins)", kind: .downloads, paths: ["~/.terraform.d/plugin-cache", "~/.terraform.d/plugins"]),
        SweepTool(name: "Pulumi (plugins)", kind: .downloads, paths: ["~/.pulumi/plugins"]),
        SweepTool(name: "Ansible (temporary)", kind: .caches, paths: ["~/.ansible/tmp"]),
        // editors and the command line
        SweepTool(name: "Neovim", kind: .caches, paths: ["~/.cache/nvim"]),
        SweepTool(name: "Vim", kind: .caches, paths: ["~/.cache/vim"]),
        SweepTool(name: "Git", kind: .caches, paths: ["~/.cache/git"]),
        SweepTool(name: "GitHub CLI", kind: .caches, paths: ["~/.cache/gh"]),
        SweepTool(name: "Alacritty", kind: .caches, paths: ["~/.cache/alacritty"]),
        SweepTool(name: "Kitty", kind: .caches, paths: ["~/.cache/kitty"]),
        SweepTool(name: "WezTerm", kind: .caches, paths: ["~/.cache/wezterm"]),
        SweepTool(name: "tmux", kind: .caches, paths: ["~/.cache/tmux"]),
        SweepTool(name: "Oh My Zsh", kind: .caches, paths: ["~/.zsh/cache"]),
        SweepTool(name: "Starship", kind: .caches, paths: ["~/.cache/starship"]),
        SweepTool(name: "fzf", kind: .caches, paths: ["~/.cache/fzf"]),
        SweepTool(name: "bat", kind: .caches, paths: ["~/.cache/bat"]),
        SweepTool(name: "tealdeer", kind: .caches, paths: ["~/.cache/tealdeer"]),
        SweepTool(name: "tldr", kind: .caches, paths: ["~/.cache/tldr"]),
        SweepTool(name: "yt-dlp", kind: .caches, paths: ["~/.cache/yt-dlp"]),
        // installed versions: they have to be installed again
        SweepTool(name: "pyenv (Python versions)", kind: .versions, paths: ["~/.pyenv/versions"]),
        SweepTool(name: "uv (Python versions and tools)", kind: .versions, paths: ["~/.local/share/uv"]),
        SweepTool(name: "pipx (installed tools)", kind: .versions, paths: ["~/.local/pipx"]),
        SweepTool(name: "Conda environments", kind: .versions, paths: ["~/miniforge3/envs", "~/miniconda3/envs", "~/anaconda3/envs"]),
        SweepTool(name: "rustup (toolchains)", kind: .versions, paths: ["~/.rustup"]),
        SweepTool(name: "rbenv (Ruby versions)", kind: .versions, paths: ["~/.rbenv/versions"]),
        SweepTool(name: "asdf (versions)", kind: .versions, paths: ["~/.asdf/installs"]),
        SweepTool(name: "GHCup (GHC versions)", kind: .versions, paths: ["~/.ghcup"]),
        SweepTool(name: "Haskell Stack", kind: .versions, paths: ["~/.stack"]),
        SweepTool(name: "Volta (tools)", kind: .versions, paths: ["~/.volta/tools"]),
        SweepTool(name: "opam", kind: .versions, paths: ["~/.opam"]),
        SweepTool(name: "Visual Studio Code (extensions)", kind: .versions, paths: ["~/.vscode/extensions"]),
        SweepTool(name: "Android SDK", kind: .versions, paths: ["~/Library/Android/sdk"]),
        SweepTool(name: "Minikube", kind: .versions, paths: ["~/.minikube"]),
        SweepTool(name: "Colima (virtual machines)", kind: .versions, paths: ["~/.colima"]),
        SweepTool(name: "Lima (virtual machines)", kind: .versions, paths: ["~/.lima"]),
        SweepTool(name: "Podman (images)", kind: .versions, paths: ["~/.local/share/containers"]),
        SweepTool(name: "Vagrant (boxes)", kind: .versions, paths: ["~/.vagrant.d/boxes", "~/.vagrant.d/data/gems"]),
    ]

    static func tools(_ kind: SweepToolKind) -> [SweepTool] { all.filter { $0.kind == kind } }

    /// Every folder of a kind: the roots the guard allows for its category.
    static func roots(_ kind: SweepToolKind) -> [String] { tools(kind).flatMap(\.paths) }

    /// Entries of `~/Library/Caches` that hold the caches of several applications of one maker: each is offered on its own, never the whole.
    static let umbrellaCaches: Set<String> = ["Google", "JetBrains", "BraveSoftware", "Microsoft"]
}
