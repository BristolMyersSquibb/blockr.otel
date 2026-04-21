#' Sample OpenTelemetry spans
#'
#' A dataset of 1,397 spans collected from a blockr application session
#' using the otel-desktop-viewer. Useful for experimenting with span
#' analysis workflows without running a live profiling session.
#'
#' @format A data frame with 1,397 rows and 11 columns:
#' \describe{
#'   \item{traceID}{Unique trace identifier}
#'   \item{spanID}{Unique span identifier}
#'   \item{parentSpanID}{Parent span ID (empty string for root spans)}
#'   \item{name}{Span name (e.g., reactive, observer, render)}
#'   \item{kind}{Span kind (e.g., Internal)}
#'   \item{statusCode}{Status code (e.g., Unset, Ok)}
#'   \item{startTime}{Start time in nanoseconds since epoch}
#'   \item{endTime}{End time in nanoseconds since epoch}
#'   \item{duration_ms}{Duration in milliseconds}
#'   \item{depth}{Nesting depth in the span tree}
#'   \item{session_id}{Shiny session identifier}
#' }
#' @examples
#' data(otel_spans)
#' head(otel_spans)
"otel_spans"
