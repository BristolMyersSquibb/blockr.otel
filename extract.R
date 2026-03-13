library(httr2)

rpc_call <- function(method, params = list()) {
  request("http://localhost:8000/rpc") |>
    req_body_json(list(
      jsonrpc = "2.0",
      method = method,
      params = params,
      id = 1
    )) |>
    req_perform() |>
    resp_body_json()
}

summaries <- rpc_call("getTraceSummaries")$result

spans_df <- do.call(
  rbind,
  unlist(
    lapply(summaries, function(s) {
      trace <- rpc_call("getTraceByID", list(s$traceID))$result
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
          session_id = d$attributes$session.id %||% NA_character_,
          stringsAsFactors = FALSE
        )
      })
    }),
    recursive = FALSE
  )
)
