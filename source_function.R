# RIsyFun name-based loader, protocol 1.
# No credentials, function catalogue, or private implementation is stored here.
local({
  export_into <- parent.env(environment())
  state <- new.env(parent = emptyenv())
  state$cache <- new.env(parent = emptyenv())
  state$loading <- new.env(parent = emptyenv())
  state$registered <- new.env(parent = emptyenv())
  state$revision <- NULL
  state$source_revision <- NULL
  state$endpoint <- NULL
  state$downloads <- 0L

  # Authenticated legacy backend, consolidated from public source_github.R.
  source_github <- function(owner = NULL, repo = NULL, ref = "main", dir = NULL, file = NULL, path = NULL, fun = NULL, helpers_dir = NULL, ..., expose = NULL, export_env = .GlobalEnv, private_parent = .GlobalEnv) {
    # --- small helpers ----------------------------------------------------------
    nz <- function(x) is.character(x) && length(x) == 1 && nzchar(x)
  
    # Allow repo = "owner/repo" when owner = NULL
    if (is.null(owner) && nz(repo) && grepl("/", repo, fixed = TRUE)) {
      parts <- strsplit(repo, "/", fixed = TRUE)[[1]]
      if (length(parts) == 2) {
        owner <- parts[1]
        repo  <- parts[2]
      }
    }
  
    # Validate required args
    if (!nz(owner)) stop("`owner` must be a non-empty string (or provide `repo` as 'owner/repo').")
    if (!nz(repo)) stop("`repo` must be a non-empty string (e.g., 'xyz').")
    if (!nz(ref)) stop("`ref` must be a non-empty string (branch, tag, or commit SHA).")
    if (!is.environment(export_env)) stop("`export_env` must be an environment.")
    if (!is.environment(private_parent)) stop("`private_parent` must be an environment.")
  
    # Compose path if not given
    if (is.null(path)) {
      if (!nz(file)) stop("`file` must be a non-empty string when `path` is NULL.")
      if (!nz(dir))  stop("`dir` must be a non-empty string when `path` is NULL.")
      path <- file.path(dir, file)
    }
  
    # Ensure gh (and optional gitcreds) are available
    if (!requireNamespace("gh", quietly = TRUE)) utils::install.packages("gh")
    # Use PAT from gitcreds if we don't already have one (needed for private repos)
    if (!nzchar(Sys.getenv("GITHUB_PAT")) && requireNamespace("gitcreds", quietly = TRUE)) {
      tok <- tryCatch(gitcreds::gitcreds_get()$password, error = function(e) "")
      if (nzchar(tok)) Sys.setenv(GITHUB_PAT = tok)
    }
  
    # 1) Fetch the loader file (raw text)
    txt <- tryCatch(
      gh::gh("GET /repos/{owner}/{repo}/contents/{path}", owner = owner, repo = repo, path = path, ref = ref, .accept = "application/vnd.github.v3.raw"),
      error = function(e) {
        stop(
          "Failed to fetch loader file '", path, "' from ", owner, "/", repo,
          " (ref '", ref, "').\n• ", conditionMessage(e),
          "\n• Check the path/branch and that your token (if needed) has access."
        )
      }
    )
    src <- if (is.raw(txt)) rawToChar(txt) else as.character(txt)
  
    # 2) Evaluate loader in a sandbox, so nothing leaks into your session
    env <- new.env(parent = baseenv())
    con <- textConnection(src, encoding = "UTF-8")
    on.exit(close(con), add = TRUE)
    base::source(con, local = env, keep.source = FALSE)
  
    if (!exists(fun, envir = env, mode = "function")) {
      stop("The loader file '", path, "' did not define a function named '", fun, "()'.")
    }
    loader <- get(fun, envir = env, inherits = FALSE)
  
    # 3) Create PRIVATE env for all helpers + deps
    private <- new.env(parent = private_parent)
  
    # 4) Prepare args for the loader; force into = private, propagate owner/repo/ref/path if not supplied
    args <- list(...)
    args$into <- private
    if (is.null(args$scan_requires)) args$scan_requires <- TRUE
    if (is.null(args$owner)) args$owner <- owner
    if (is.null(args$repo)) args$repo <- repo
    if (is.null(args$ref)) args$ref <- ref
    # If the loader accepts a `path` argument: use explicit helpers_dir; otherwise infer from path or dir
    if (is.null(args$path)) {
      if (nz(helpers_dir)) {
        args$path <- helpers_dir
      } else {
        d <- dirname(path)
        if (identical(d, ".") || !nzchar(d)) d <- dir
        args$path <- d
      }
    }
  
    # 5) Call the loader (loads requested files + dependencies into 'private')
    do.call(loader, args)
  
    # 6) Decide what to expose (if not provided, infer from include by stripping ".R")
    if (is.null(expose) && !is.null(args$include)) {
      guess <- sub("\\.R$", "", unlist(args$include, use.names = FALSE))
      expose <- intersect(guess, ls(private, all.names = FALSE))
    }
  
    # 7) Expose selected symbols into export_env (dependencies remain hidden in 'private')
    if (length(expose)) {
      if (!is.character(expose)) stop("`expose` must be a character vector of function names to export.")
      invisible(lapply(expose, function(nm) {
        if (!exists(nm, envir = private, inherits = FALSE)) {
          warning(sprintf("'%s' not found in private env; available: %s", nm, paste(ls(private), collapse = ", ")))
        } else {
          assign(nm, get(nm, envir = private, inherits = FALSE), envir = export_env)
        }
      }))
    }
  
    # Return the private namespace (invisible) for advanced use
    invisible(private)
  }
  
  endpoint <- function() {
    value <- getOption("RIsyFun.gateway", "https://risyfun.chakrabarty.org")
    if (!is.character(value) || length(value) != 1L || is.na(value))
      stop("RIsyFun.gateway must be a single HTTPS address.", call. = FALSE)
    value <- sub("/+$", "", value)
    if (!grepl("^https://[^/?#@]+(?:/[^?#]*)?$", value, perl = TRUE) &&
        !grepl("^http://(?:127\\.0\\.0\\.1|localhost)(?::[0-9]+)?$", value, perl = TRUE))
      stop("The gateway must use HTTPS (or loopback HTTP for testing).", call. = FALSE)
    value
  }

  fetch_bytes <- function(path, limit = 16L * 1024L * 1024L) {
    if (!isTRUE(capabilities("libcurl")))
      stop("This R installation needs HTTPS/libcurl support.", call. = FALSE)
    old <- options(timeout = max(60, getOption("timeout", 60)))
    on.exit(options(old), add = TRUE)
    con <- base::url(paste0(state$endpoint, path), open = "", method = "libcurl")
    on.exit(try(close(con), silent = TRUE), add = TRUE)
    bytes <- tryCatch({
      suppressWarnings(open(con, "rb"))
      readBin(con, "raw", n = limit + 1L)
    }, error = function(e) {
      stop("RIsyFun download failed. The requested function/version may be unavailable, ",
           "the gateway may be offline, or the request may be rate-limited. ",
           "No local inputs were sent.", call. = FALSE)
    })
    if (!length(bytes) || length(bytes) > limit)
      stop("The gateway returned an empty or oversized response.", call. = FALSE)
    bytes
  }

  pin_revision <- function() {
    if (!is.null(state$revision)) return(invisible(state$revision))
    state$endpoint <- endpoint()
    revision <- trimws(rawToChar(fetch_bytes("/v1/version", 128L)))
    if (!grepl("^[0-9a-f]{40}$", revision))
      stop("The gateway returned an invalid distribution version.", call. = FALSE)
    state$revision <- revision
    invisible(revision)
  }

  get_implementation <- function(name) {
    if (exists(name, state$cache, inherits = FALSE))
      return(get(name, state$cache, inherits = FALSE))
    if (exists(name, state$loading, inherits = FALSE))
      stop("Recursive loading of the requested function was detected.", call. = FALSE)
    assign(name, TRUE, state$loading)
    on.exit(rm(list = name, envir = state$loading), add = TRUE)
    pin_revision()
    raw <- fetch_bytes(paste0("/v1/function/", state$revision, "/", name))
    bundle <- tryCatch(unserialize(memDecompress(raw, "gzip")),
                       error = function(e) stop("Invalid RIsyFun bundle.", call. = FALSE))
    if (!is.list(bundle) || !identical(bundle$protocol, 1L) ||
        !identical(bundle$name, name) || !is.list(bundle$code) ||
        !length(bundle$code) || !all(vapply(bundle$code, is.expression, logical(1))) ||
        !is.character(bundle$source_revision) || length(bundle$source_revision) != 1L ||
        !grepl("^[0-9a-f]{40}$", bundle$source_revision))
      stop("The requested bundle failed validation.", call. = FALSE)
    if (!is.null(state$source_revision) &&
        !identical(state$source_revision, bundle$source_revision))
      stop("Refusing to mix private source versions in one session.", call. = FALSE)
    if (!is.null(bundle$minimum_r) && getRversion() < package_version(bundle$minimum_r))
      stop("This bundle requires R ", bundle$minimum_r, " or newer.", call. = FALSE)
    private <- new.env(parent = .GlobalEnv)
    invisible(lapply(bundle$code, eval, envir = private))
    if (!exists(name, envir = private, inherits = FALSE, mode = "function"))
      stop("The bundle did not define the requested function.", call. = FALSE)
    implementation <- get(name, envir = private, inherits = FALSE)
    state$source_revision <- bundle$source_revision
    assign(name, implementation, state$cache)
    state$downloads <- state$downloads + 1L
    implementation
  }

  make_wrapper <- function(name) {
    force(name)
    wrapper <- function(...) {
      implementation <- get_implementation(name)
      invocation <- sys.call()
      invocation[[1L]] <- implementation
      eval(invocation, envir = parent.frame())
    }
    attr(wrapper, "RIsyFun.wrapper") <- name
    wrapper
  }

  target_environment <- function(attach_env) {
    if (!attach_env) return(.GlobalEnv)
    positions <- which(search() == "package:RIsyFun")
    if (!length(positions)) {
      suppressMessages(attach(NULL, name = "package:RIsyFun", warn.conflicts = FALSE))
      return(as.environment("package:RIsyFun"))
    }
    target <- as.environment(positions[[1L]])
    if (environmentIsLocked(target))
      stop("The attached RIsyFun environment is locked; use attach_env = FALSE.", call. = FALSE)
    if (length(positions) > 1L) {
      older <- lapply(positions[-1L], as.environment)
      invisible(lapply(older, function(env) {
        missing <- setdiff(ls(env, all.names = TRUE), ls(target, all.names = TRUE))
        if (length(missing)) list2env(mget(missing, env, inherits = FALSE), target)
        invisible(NULL)
      }))
      invisible(lapply(rev(positions[-1L]), function(pos) detach(pos = pos)))
    }
    target
  }

  source_function <- function(functions, attach_env = TRUE, cache = FALSE, force = FALSE, backend = getOption("RIsyFun.backend", "gateway")) {
    if (!is.character(functions) || anyNA(functions))
      stop("functions must be a character vector of exact function names.", call. = FALSE)
    check_flag <- function(x) is.logical(x) && length(x) == 1L && !is.na(x)
    if (!all(vapply(list(attach_env, cache, force), check_flag, logical(1))))
      stop("attach_env, cache, and force must each be TRUE or FALSE.", call. = FALSE)
    names <- unique(sub("\\.[Rr]$", "", functions))
    if (!length(names)) return(invisible(NULL))
    if (length(names) > 100L || any(!grepl("^[A-Za-z][A-Za-z0-9_.]{0,99}$", names)))
      stop("Use exact function names, optionally ending in .R; paths are not accepted.", call. = FALSE)
    if (!is.character(backend) || length(backend) != 1L || is.na(backend) ||
        !backend %in% c("gateway", "github"))
      stop("backend must be gateway or github.", call. = FALSE)
    target <- target_environment(attach_env)
    needed <- if (force) names else names[!vapply(names, exists, logical(1),
                                                envir = target, inherits = FALSE, mode = "function")]
    if (!length(needed)) return(invisible(NULL))
    if (identical(backend, "github")) {
      # The pre-existing public source_github() calls the original private RIsyFun.R.
      # The user must already hold their own GitHub credential; none is embedded here.
      source_github(owner = "souparna-chakrabarty", repo = "RIsyFun",
                    dir = "Functions", file = "RIsyFun.R", fun = "RIsyFun",
                    include = paste0(needed, ".R"), attach_env = FALSE,
                    cache = cache, expose = needed, export_env = target)
      invisible(lapply(needed, function(name) {
        assign(name, TRUE, envir = state$registered)
        invisible(NULL)
      }))
      return(invisible(NULL))
    }
    if (cache)
      warning("cache is retained for compatibility. Only in-memory caching is supported; ",
              "nothing is deliberately cached to disk.", call. = FALSE)
    invisible(lapply(needed, function(name) {
      assign(name, make_wrapper(name), envir = target)
      assign(name, TRUE, envir = state$registered)
      invisible(NULL)
    }))
    invisible(NULL)
  }

  clear_function_cache <- function(refresh = FALSE) {
    if (!is.logical(refresh) || length(refresh) != 1L || is.na(refresh))
      stop("refresh must be TRUE or FALSE.", call. = FALSE)
    if (length(ls(state$loading, all.names = TRUE)))
      stop("Cannot clear the cache while a function is being loaded.", call. = FALSE)
    rm(list = ls(state$cache, all.names = TRUE), envir = state$cache)
    if (refresh) {
      state$revision <- NULL
      state$source_revision <- NULL
      state$endpoint <- NULL
    }
    invisible(NULL)
  }

  source_function_status <- function() {
    list(protocol = 1L, gateway = if (is.null(state$endpoint)) endpoint() else state$endpoint,
         repository_revision = state$revision, distribution_revision = state$revision,
         source_revision = state$source_revision,
         registered_count = length(ls(state$registered, all.names = TRUE)),
         cached_count = length(ls(state$cache, all.names = TRUE)),
         bundle_downloads = state$downloads, disk_cache = FALSE)
  }

  assign("source_github", source_github, envir = export_into)
  assign("source_function", source_function, envir = export_into)
  assign("clear_function_cache", clear_function_cache, envir = export_into)
  assign("source_function_status", source_function_status, envir = export_into)
})
