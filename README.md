# source_function

A name-based loader for privately hosted R helpers. There is no public function catalogue.
You must already know the exact name of a function approved for distribution.

## Usage

```r
source("https://raw.githubusercontent.com/souparna-chakrabarty/source_function/main/source_function.R", local = TRUE)
source_function("known_function.R")  # Replace with a name supplied to you privately.
# Then call that function normally with your local inputs.
```

Names with and without `.R` are accepted. Register several with a character vector.
`attach_env = TRUE` exposes wrappers in `package:RIsyFun`; `FALSE` puts them in `.GlobalEnv`.
`force = TRUE` explicitly replaces a pre-existing binding in the selected environment.
A pre-existing `.GlobalEnv` object still takes precedence over an attached environment;
start a fresh R session or deliberately use `attach_env = FALSE, force = TRUE` when migrating.

Registration does not download the implementation. Its first invocation downloads a
version-pinned binary bundle, including its declared helpers. Subsequent invocations
reuse the implementation in the current R session. All computation runs locally;
function arguments and results are never sent to the gateway. The gateway sees the
requested function name, distribution version, and network-level connection metadata.

The client requires R 4.1 or newer with HTTPS/libcurl support. Individual functions may
need packages or a newer R version; their existing dependency installation behaviour is retained.

```r
source_function_status()              # Counts and versions; not an available-function list.
clear_function_cache()                # Release cached implementations, retain pinned version.
clear_function_cache(refresh = TRUE)  # Next invocation selects the latest published version.
```

`cache` is retained only for calling compatibility. Both its values use session-only
caching, and `cache = TRUE` emits an explanatory warning. No implementation is
deliberately written to a disk cache. Saving an R workspace or explicitly serializing
objects can persist cached code. Clearing references is not secure memory erasure.

## Security and availability

No GitHub credential is distributed to clients. Original source and the distribution
index remain in a private repository. Only exact approved names can be requested;
there is no listing endpoint. Names can still be guessed. This is **not authentication**.

Binary packaging, omitted comments/source references, and small forwarding wrappers
make casual browsing less convenient. They are **not encryption or copy protection**:
someone controlling their R session can retain or inspect downloaded implementations.
Only use this loader when you trust its publisher, just as with `source()`.

A function's first invocation needs the gateway and GitHub to be reachable. Already
cached functions do not. Unknown names fail when first invoked, not at registration.
Each session pins one immutable distribution commit. New functions are published only
when explicitly included in the private allowlist; there is no automatic directory exposure.

## Consolidated loader and migration compatibility

The same public `source_function.R` now contains both the previously separate
generic `source_github()` API and the `source_function()` convenience API.
No external `source_github` bootstrap is required to use the consolidated script.

```r
source("https://raw.githubusercontent.com/souparna-chakrabarty/source_function/main/source_function.R", local = TRUE)
source_function("known_function.R")                # Gateway mode (default); no GitHub token needed
source_function("known_function.R", backend = "github")  # Explicit authenticated legacy mode
```

`backend = "github"` delegates **unchanged dependency sourcing** to the
existing private `Functions/RIsyFun.R`. It requires the calling user to have
their **own** GitHub access to that private repository, obtained through the
existing `gh`/`gitcreds` workflow; the public file never contains a credential.
It retains the original `cache` flag: `cache = TRUE` uses the existing local
RIsyFun disk cache, while `cache = FALSE` sources directly into memory.

`backend = "gateway"` retains the name-based, first-use remote retrieval and
session-only cache. At the time of consolidation, this still uses the
temporary private distribution branch; it is not yet the unified production
path. A later stage will attach this mode to the original private `RIsyFun.R`
and retire the distribution branch after end-to-end verification.

The standalone public `source_github` repository remains intact for callers
that already source it. Its API is now also available by sourcing this script.

**Mixed-session caution:** do not load both backends into the same target
environment for the same function without deliberate `force = TRUE`; run in a
fresh R session while migrating.
