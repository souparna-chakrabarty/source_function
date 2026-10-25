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

  source_function <- function(functions, attach_env = TRUE, cache = FALSE, force = FALSE) {
    if (!is.character(functions) || anyNA(functions))
      stop("functions must be a character vector of exact function names.", call. = FALSE)
    check_flag <- function(x) is.logical(x) && length(x) == 1L && !is.na(x)
    if (!all(vapply(list(attach_env, cache, force), check_flag, logical(1))))
      stop("attach_env, cache, and force must each be TRUE or FALSE.", call. = FALSE)
    names <- unique(sub("\\.[Rr]$", "", functions))
    if (!length(names)) return(invisible(NULL))
    if (length(names) > 100L || any(!grepl("^[A-Za-z][A-Za-z0-9_.]{0,99}$", names)))
      stop("Use exact function names, optionally ending in .R; paths are not accepted.", call. = FALSE)
    if (cache)
      warning("cache is retained for compatibility. Only in-memory caching is supported; ",
              "nothing is deliberately cached to disk.", call. = FALSE)
    target <- target_environment(attach_env)
    needed <- if (force) names else names[!vapply(names, exists, logical(1),
                                                envir = target, inherits = FALSE, mode = "function")]
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
         distribution_revision = state$revision, source_revision = state$source_revision,
         registered_count = length(ls(state$registered, all.names = TRUE)),
         cached_count = length(ls(state$cache, all.names = TRUE)),
         bundle_downloads = state$downloads, disk_cache = FALSE)
  }

  assign("source_function", source_function, envir = export_into)
  assign("clear_function_cache", clear_function_cache, envir = export_into)
  assign("source_function_status", source_function_status, envir = export_into)
})
