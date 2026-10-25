# source_function

Unified public loader for functions in private `RIsyFun`. No public catalogue of function names.

## Standard usage

```r
source("https://raw.githubusercontent.com/souparna-chakrabarty/source_function/main/source_function.R", local = TRUE)
source_function("known_function.R")
```


A caller must already know the exact name. Accepts names with or without `.R`.
Registration creates a small forwarding wrapper, without downloading implementation.
At first execution, the loader requests one bundle containing its dependency closure
from the Hetzner gateway. This bundle is assembled by the **existing private**
`Functions/RIsyFun.R` dependency resolver at an immutable Git commit of `main`.
The function executes on the caller’s R session with local inputs and is held in
the session-memory cache. Subsequent calls do not download it again.
No original R source, function directory listing, GitHub credentials, inputs, or results
are sent through the public GitHub loader. The gateway sees the name and revision.

## Compatibility with the previous source_github loader

The same `source_function.R` file also defines `source_github()` using the API
of the older public `source_github` repository. No second public script is
required for callers of the unified loader.

```r
# For repository owners/collaborators who already possess GitHub access:
source_function("known_function.R", backend = "github", cache = FALSE)

# Existing general API remains available:
source_github(owner = "owner", repo = "repo", dir = "Functions",
              file = "RIsyFun.R", fun = "RIsyFun", include = "known_function.R")
```

`backend = "github"` delegates to the original `RIsyFun.R` with its normal
sourcing semantics. It requires private-repository credentials **on the caller’s
machine**. It is explicitly optional; regular clients use the default gateway.
Only `backend = "github"` preserves the original `cache = TRUE` disk-source cache.
For `backend = "gateway"`, the cache is memory-only and `cache = TRUE` merely warns.
No token is embedded in the public code. The separate public `source_github`
repository is left intact for existing scripts but is not needed by this loader.

## Controls

```r
source_function_status()
clear_function_cache()
clear_function_cache(refresh = TRUE)
source_function("known_function", attach_env = FALSE, force = TRUE)
```

Default `attach_env = TRUE` registers wrappers in `package:RIsyFun`;
`FALSE` registers in `.GlobalEnv`. A pre-existing object in `.GlobalEnv` can
shadow an attached wrapper; use a fresh session when migrating.
`force = TRUE` replaces a binding in the selected target environment.
`source_function_status()` includes `repository_revision` (the pinned private main
commit) and a deprecated `distribution_revision` alias for older code.

## Privacy, compatibility, and availability

No public listing or manifest endpoint exists. Name-based access **is not
authentication**: a function name may be guessed. Downloaded executable R objects
can be reconstructed and inspected by their recipients; this offers only casual
source concealment, not encryption or secure source-code protection.
Source comments and source references are omitted from gateway bundles.
Saving an R workspace may persist in-memory implementations.

R 4.1+ and libcurl/HTTPS are required for the gateway mode.
The first invocation requires that the gateway is reachable and its one
server-side GitHub credential is correctly configured. Already-loaded functions
can run even when the gateway is offline.
The gateway preserves one source revision per R session and resolves dependencies
through `Functions/RIsyFun.R`. No separate distribution branch is used.
The gateway service and SSL route must be activated before public users can
successfully download a private implementation.
