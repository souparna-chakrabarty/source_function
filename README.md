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
