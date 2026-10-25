# RIsyFun name-based loader

local({
  export_into <- parent.env(environment())
  state <- new.env(parent = emptyenv())
  state$cache <- new.env(parent = emptyenv())
  state$loading <- new.env(parent = emptyenv())
  state$displaced <- new.env(parent = emptyenv())
  state$revision <- NULL
  state$endpoint <- NULL

  fetch_bytes <- function(path, limit = 16L * 1024L * 1024L) {
    if (!capabilities("libcurl")) stop("This R installation needs HTTPS/libcurl support.", call. = FALSE)

    old <- options(timeout = max(60, getOption("timeout", 60)))
    on.exit(options(old), add = TRUE)

    con <- url(paste0(state$endpoint, path), open = "", method = "libcurl")
    on.exit(try(close(con), silent = TRUE), add = TRUE)

    bytes <- tryCatch({
      suppressWarnings(open(con, "rb"))
      readBin(con, "raw", n = limit + 1L)
    }, error = function(e) {
      stop("RIsyFun download failed. The requested function/version may be unavailable, the gateway may be offline, or the request may be rate-limited. No local inputs were sent.", call. = FALSE)
    })

    if (!length(bytes) || length(bytes) > limit) stop("The gateway returned an empty or oversized response.", call. = FALSE)

    bytes
  }

  source_function <- function(functions, refresh = FALSE) {
    if (!is.character(functions) || anyNA(functions)) stop("functions must be a character vector of exact function names.", call. = FALSE)

    names <- unique(sub("\\.[Rr]$", "", functions))

    if (length(names) > 100L || any(!grepl("^[A-Za-z][A-Za-z0-9_.]{0,99}$", names)))
      stop("Use exact function names, paths are not accepted.", call. = FALSE)

    if (!is.logical(refresh) || length(refresh) != 1L || is.na(refresh))
      stop("refresh must be TRUE or FALSE.", call. = FALSE)

    # A .GlobalEnv binding takes precedence over an attached RIsyFun wrapper.
    global_conflicts <- names[vapply(names, exists, logical(1), envir = .GlobalEnv, inherits = FALSE)]
    foreign_conflicts <- global_conflicts[!vapply(global_conflicts, function(nm) {
      value <- get(nm, envir = .GlobalEnv, inherits = FALSE)
      is.function(value) && identical(attr(value, "RIsyFun.wrapper"), nm) &&
        identical(get0("state", envir = environment(value), inherits = TRUE), state)
    }, logical(1))]

    # Preserve displaced global bindings; RIsyFun wrappers take precedence.
    if ("source_function" %in% names)
      stop("Cannot register the loader itself as a private function.", call. = FALSE)
    protected <- foreign_conflicts[vapply(foreign_conflicts, function(nm) {
      bindingIsLocked(nm, .GlobalEnv) || bindingIsActive(nm, .GlobalEnv)
    }, logical(1))]
    if (length(protected))
      stop("Cannot replace locked or active global binding(s): ",
           paste(protected, collapse = ", "), call. = FALSE)

    if (refresh) {
      if (length(ls(state$loading, all.names = TRUE))) stop("Cannot refresh while a function is loading.", call. = FALSE)
      cached <- ls(state$cache, all.names = TRUE)
      if (length(cached)) rm(list = cached, envir = state$cache)
      state$revision <- NULL
      state$endpoint <- NULL
    }
    if (!length(names)) return(invisible(NULL))

    positions <- which(search() == "package:RIsyFun")
    if (!length(positions)) {
      suppressMessages(attach(NULL, name = "package:RIsyFun", warn.conflicts = FALSE))
      target <- as.environment("package:RIsyFun")
    } else {
      target <- as.environment(positions[[1L]])
    }

    if (environmentIsLocked(target)) stop("The attached RIsyFun environment is locked; detach it or restart R before registering functions.", call. = FALSE)

    if (length(positions) > 1L) {
      older <- lapply(positions[-1L], as.environment)

      invisible(lapply(older, function(env) {
        missing <- setdiff(ls(env, all.names = TRUE), ls(target, all.names = TRUE))
        if (length(missing)) list2env(mget(missing, env, inherits = FALSE), target)
        invisible(NULL)
      }))

      invisible(lapply(rev(positions[-1L]), function(pos) detach(pos = pos)))
    }

    # Explicit registration replaces stale wrappers from earlier loader instances.
    current_wrapper <- function(nm) {
      if (!exists(nm, envir = target, inherits = FALSE, mode = "function"))
        return(FALSE)
      value <- get(nm, envir = target, inherits = FALSE)
      identical(attr(value, "RIsyFun.wrapper"), nm) &&
        identical(get0("state", envir = environment(value), inherits = TRUE), state)
    }
    needed <- names[!vapply(names, current_wrapper, logical(1))]

    wrapper_function <- function(name) {
      force(name)
      wrapper <- function(...) {
        if (exists(name, state$cache, inherits = FALSE)) {
          implementation <- get(name, state$cache, inherits = FALSE)
        } else {
          if (exists(name, state$loading, inherits = FALSE))
            stop("Recursive loading of the requested function was detected.", call. = FALSE)

          assign(name, TRUE, state$loading)
          on.exit(rm(list = name, envir = state$loading), add = TRUE)

          # Initialize gateway and pin GitHub revision only once
          if (is.null(state$revision)) {
            value <- getOption("RIsyFun.gateway", "https://risyfun.chakrabarty.org")

            if (!is.character(value) || length(value) != 1L || is.na(value))
              stop("RIsyFun.gateway must be a single HTTPS address.", call. = FALSE)

            value <- sub("/+$", "", value)

            if (!grepl("^https://[^/?#@]+(?:/[^?#]*)?$", value, perl = TRUE) &&
                !grepl("^http://(?:127[.]0[.]0[.]1|localhost)(?::[0-9]+)?$", value, perl = TRUE))
              stop("The gateway must use HTTPS (or loopback HTTP for testing).", call. = FALSE)

            state$endpoint <- value

            revision <- trimws(rawToChar(fetch_bytes("/v1/version", 128L)))

            if (!grepl("^[0-9a-f]{40}$", revision))
              stop("The gateway returned an invalid repository revision.", call. = FALSE)

            state$revision <- revision
          }

          # Download requested implementation
          raw <- fetch_bytes(paste0("/v1/function/", state$revision, "/", name))

          bundle <- tryCatch(
            unserialize(memDecompress(raw, "gzip")),
            error = function(e) stop("Invalid RIsyFun bundle.", call. = FALSE)
          )

          # Validate bundle and pinned source revision
          if (!is.list(bundle) ||
              !identical(bundle$protocol, 1L) ||
              !identical(bundle$name, name) ||
              !is.list(bundle$code) ||
              !length(bundle$code) ||
              !all(vapply(bundle$code, is.expression, logical(1))) ||
              !is.character(bundle$source_revision) ||
              length(bundle$source_revision) != 1L ||
              !identical(bundle$source_revision, state$revision))
            stop("The requested bundle failed validation or does not match the pinned revision.", call. = FALSE)

          if (!is.null(bundle$minimum_r) && getRversion() < package_version(bundle$minimum_r))
            stop("This bundle requires R ", bundle$minimum_r, " or newer.", call. = FALSE)

          # Reconstruct locally
          private <- new.env(parent = .GlobalEnv)
          invisible(lapply(bundle$code, eval, envir = private))

          if (!exists(name, envir = private, inherits = FALSE, mode = "function"))
            stop("The bundle did not define the requested function.", call. = FALSE)

          implementation <- get(name, envir = private, inherits = FALSE)
          assign(name, implementation, state$cache)
        }

        # Execute in the original caller's environment
        invocation <- sys.call()
        invocation[[1L]] <- implementation
        eval(invocation, envir = parent.frame())
      }
      attr(wrapper, "RIsyFun.wrapper") <- name
      wrapper
    }

    invisible(lapply(needed, function(name) {
      assign(name, wrapper_function(name), envir = target)
      invisible(NULL)
    }))
    if (length(foreign_conflicts)) {
      invisible(lapply(foreign_conflicts, function(nm) {
        if (!exists(nm, envir = state$displaced, inherits = FALSE))
          assign(nm, get(nm, envir = .GlobalEnv, inherits = FALSE),
                 envir = state$displaced)
        assign(nm, get(nm, envir = target, inherits = FALSE), envir = .GlobalEnv)
        invisible(NULL)
      }))
      warning("RIsyFun takes precedence over .GlobalEnv binding(s): ",
              paste(foreign_conflicts, collapse = ", "),
              ". Original binding(s) preserved in the loader state.", call. = FALSE)
    }
    invisible(NULL)
  }

  assign("source_function", source_function, envir = export_into)
})
