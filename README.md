# source_function

Public, name-based R loader for approved functions stored in the private `souparna-chakrabarty/RIsyFun` repository. Function names are not enumerated publicly.

## Usage

```r
source("https://raw.githubusercontent.com/souparna-chakrabarty/source_function/main/source_function.R", local = TRUE)
source_function("known_function.R")
# Then invoke that known function normally in the same R session.
```

The loader accepts a function name with or without `.R`. Multiple known names may be registered as a character vector. Registration is lazy: it creates lightweight wrappers but does not download implementation code.

On first invocation, a wrapper requests its approved, version-pinned bundle via Hetzner from private GitHub. The private `Functions/RIsyFun.R` resolves dependencies, and the implementation executes locally. Subsequent calls reuse the implementation cached **in memory**. Function arguments and results are not sent to Hetzner.

## Refresh

```r
source_function("known_function.R", refresh = TRUE)
source_function(character(0), refresh = TRUE) # Refresh registered wrappers without specifying names.
```

`refresh = TRUE` invalidates the loader's entire memory cache and pinned revision. The next invocation retrieves the latest private GitHub revision. Existing wrappers remain registered and download new implementations on demand. Previously copied or returned function objects cannot be updated retroactively.

## Precedence and collision warnings

When a requested name already exists in `.GlobalEnv`, RIsyFun takes precedence. The loader preserves the original global value privately, installs its RIsyFun wrapper into `.GlobalEnv`, and emits a warning listing the displaced names. Locked or active global bindings cannot be replaced. Registering the same wrapper again does not cause repeated warnings.

Because `.GlobalEnv` is searched before attached environments, replacing the binding is necessary to guarantee precedence. Be cautious when registering a name that also identifies a global data object. The loader reserves the name `source_function` for itself.

## Privacy and availability

There is no public function catalogue or listing endpoint. Access is by exact name, not identity; names can be guessed. Hetzner uses one **server-only**, read-only private GitHub credential; the user needs none.

The client receives source-stripped R bundles instead of plaintext `.R` files. This is a barrier to casual inspection, **not** a guarantee of secrecy: anyone controlling their own R session can capture or inspect an implementation.

The first invocation requires Hetzner and private GitHub to be reachable. Already cached functions can run while the gateway is unavailable. The loader does not intentionally cache bundles on disk, although saved R workspaces can preserve implementations. Requires R 4.1+ with libcurl/HTTPS support.

The separate public `source_github` repository remains unchanged for callers who need direct authenticated GitHub sourcing. This public `source_function.R` contains only the gateway client.

## Deployment

Function retrieval requires one restricted GitHub credential installed privately on Hetzner and a functional HTTPS gateway at `https://risyfun.chakrabarty.org`. The server code is maintained in the private `RIsyFun` repository.
