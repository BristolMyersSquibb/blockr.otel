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

  spans_list <- unlist(
    lapply(summaries, function(s) {
      trace <- rpc_call("getTraceByID", list(s$traceID), port = port)$result
      svc <- s$rootServiceName
      lapply(trace$spans, function(sp) {
        d <- sp$spanData
        data.frame(
          traceID = d$traceID,
          spanID = d$spanID,
          parentSpanID = d$parentSpanID,
          name = d$name,
          kind = d$kind,
          statusCode = d$statusCode,
          startTime = as.numeric(d$startTime),
          endTime = as.numeric(d$endTime),
          duration_ms = (as.numeric(d$endTime) - as.numeric(d$startTime)) / 1e6,
          depth = sp$depth,
          service_name = svc %||% NA_character_,
          session_id = d$attributes$session.id %||% NA_character_,
          stringsAsFactors = FALSE
        )
      })
    }),
    recursive = FALSE
  )

  do.call(rbind, spans_list)
}
