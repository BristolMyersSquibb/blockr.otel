#' Get the OTLP HTTP port from environment
#'
#' Reads `OTEL_EXPORTER_OTLP_PORT` env var, defaulting to 4318.
#'
#' @return An integer port number.
#' @export
otel_http_port <- function() {
  as.integer(Sys.getenv("OTEL_EXPORTER_OTLP_PORT", "4318"))
}

#' Get the OTLP gRPC port from environment
#'
#' Reads `OTEL_EXPORTER_OTLP_GRPC_PORT` env var, defaulting to 4317.
#'
#' @return An integer port number.
#' @export
otel_grpc_port <- function() {
  as.integer(Sys.getenv("OTEL_EXPORTER_OTLP_GRPC_PORT", "4317"))
}

#' Call an RPC method on otel-desktop-viewer
#'
#' Sends a JSON-RPC 2.0 request to the otel-desktop-viewer web UI.
#'
#' @param method RPC method name (e.g., `"getTraceSummaries"`, `"getTraceByID"`)
#' @param params List of parameters for the method
#' @param port The browser/web-UI port of otel-desktop-viewer (default 8000)
#'
#' @return Parsed JSON response
#' @export
rpc_call <- function(method, params = list(), port = 8000) {
  httr2::request(paste0("http://localhost:", port, "/rpc")) |>
    httr2::req_body_json(list(
      jsonrpc = "2.0",
      method = method,
      params = params,
      id = 1
    )) |>
    httr2::req_timeout(seconds = 5) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
}

#' Fetch all spans from otel-desktop-viewer
#'
#' Retrieves all trace summaries and fetches full span data for each trace,
#' returning a consolidated data.frame.
#'
#' @param port The browser/web-UI port of otel-desktop-viewer (default 8000)
#'
#' @return A data.frame with columns: traceID, spanID, parentSpanID, name,
#'   kind, statusCode, startTime, endTime, duration_ms, depth, session_id
#' @export
fetch_spans <- function(port = 8000) {
  summaries <- rpc_call("getTraceSummaries", port = port)$result

  empty_df <- data.frame(
    traceID = character(), spanID = character(),
    parentSpanID = character(), name = character(),
    kind = character(), statusCode = character(),
    startTime = numeric(), endTime = numeric(),
    duration_ms = numeric(), depth = integer(),
    service_name = character(), session_id = character(),
    stringsAsFactors = FALSE
  )
  if (length(summaries) == 0) return(empty_df)

  # Fetch all traces in parallel
  base_url <- paste0("http://localhost:", port, "/rpc")
  reqs <- lapply(summaries, function(s) {
    httr2::request(base_url) |>
      httr2::req_body_json(list(
        jsonrpc = "2.0",
        method = "getTraceByID",
        params = list(s$traceID),
        id = 1
      )) |>
      httr2::req_timeout(seconds = 5)
  })
  resps <- httr2::req_perform_parallel(reqs, on_error = "continue")

  traces <- lapply(resps, function(r) {
    tryCatch(httr2::resp_body_json(r)$result, error = function(e) NULL)
  })
  n_total <- sum(vapply(
    traces,
    function(t) if (is.null(t)) 0L else length(t$spans),
    integer(1)
  ))
  if (n_total == 0) return(empty_df)

  # Pre-allocate vectors
  v_traceID <- character(n_total)
  v_spanID <- character(n_total)
  v_parentSpanID <- character(n_total)
  v_name <- character(n_total)
  v_kind <- character(n_total)
  v_statusCode <- character(n_total)
  v_startTime <- numeric(n_total)
  v_endTime <- numeric(n_total)
  v_depth <- integer(n_total)
  v_service_name <- character(n_total)
  v_session_id <- character(n_total)

  idx <- 0L
  for (trace in traces) {
    if (is.null(trace)) next
    for (sp in trace$spans) {
      idx <- idx + 1L
      d <- sp$spanData
      v_traceID[idx] <- d$traceID %||% NA_character_
      v_spanID[idx] <- d$spanID %||% NA_character_
      v_parentSpanID[idx] <- d$parentSpanID %||% NA_character_
      v_name[idx] <- d$name %||% NA_character_
      v_kind[idx] <- d$kind %||% NA_character_
      v_statusCode[idx] <- d$statusCode %||% NA_character_
      v_startTime[idx] <- as.numeric(d$startTime)
      v_endTime[idx] <- as.numeric(d$endTime)
      v_depth[idx] <- sp$depth %||% 0L
      svc <- d$resource$attributes$service.name
      v_service_name[idx] <- if (
        is.null(svc) || !nzchar(svc)
      ) NA_character_ else svc
      v_session_id[idx] <- d$attributes$session.id %||% NA_character_
    }
  }

  data.frame(
    traceID = v_traceID, spanID = v_spanID,
    parentSpanID = v_parentSpanID, name = v_name,
    kind = v_kind, statusCode = v_statusCode,
    startTime = v_startTime, endTime = v_endTime,
    duration_ms = (v_endTime - v_startTime) / 1e6,
    depth = v_depth, service_name = v_service_name,
    session_id = v_session_id, stringsAsFactors = FALSE
  )
}
