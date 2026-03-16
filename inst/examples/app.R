library(blockr)
library(blockr.bi)
library(blockr.extra)
library(blockr.echarts)
library(blockr.otel)
library(mirai)

# For now, only works in the main process ...
# I suspect issues happen when shinytest2 is called
# within mirai...
daemons(5, sync = TRUE)
## automatically shutdown daemons when app exits
shiny::onStop(function() daemons(0))

serve(
  new_dock_board(
    extensions = new_dag_extension(),
    layout = list(
      list(
        "ext_panel-dag_extension"
      )
    ),
    blocks = list(
      # ══ Data Source ═══════════════════════════════════════════════════════════
      otel_profiler = new_otel_block(
        app_paths = "/Users/davidgranjon/david/Cynkra/athlyticz/workshop1",
        browser_port = 8000L,
        http_port = 4318L,
        grpc_port = 4317L,
        wait_seconds = 10L
      ),

      # ══ Duration Filter ════════════════════════════════════════════════════════
      spans_filter = new_filter_expr_block("duration_ms >= 100"),
      spans_arrange = new_arrange_block(
        columns = list(
          list(column = "duration_ms", direction = "desc")
        )
      ),

      # ══ Session Duration Summary ══════════════════════════════════════════════
      session_duration = new_summarize_expr_block(
        exprs = list(
          total_duration_ms = "sum(duration_ms, na.rm = TRUE)",
          n_spans = "dplyr::n()",
          min_start = "min(startTime, na.rm = TRUE)",
          max_end = "max(endTime, na.rm = TRUE)"
        ),
        by = "session_id"
      ),
      session_kpi = new_kpi_block(
        measures = c("total_duration_ms", "n_spans"),
        agg_fun = "sum",
        suffix = c("ms", ""),
        digits = "0",
        titles = c(
          total_duration_ms = "Total Duration",
          n_spans = "Total Spans"
        ),
        visible = "outputs",
        block_name = "Session KPIs"
      ),

      # ══ Spans Sorted by Duration ══════════════════════════════════════════════
      spans_select = new_select_block(
        columns = c("name", "duration_ms", "session_id", "depth", "statusCode")
      ),
      spans_head = new_head_block(n = 5),
      spans_table = new_summarize_expr_block(
        exprs = list(
          total_duration_ms = "round(sum(duration_ms, na.rm = TRUE), 2)",
          count = "dplyr::n()",
          avg_duration_ms = "round(mean(duration_ms, na.rm = TRUE), 2)"
        ),
        by = "name",
        visible = "outputs",
        block_name = "Spans by Duration"
      ),

      # ══ Duration Bar Chart ════════════════════════════════════════════════════
      top_spans_summary = new_summarize_expr_block(
        exprs = list(
          total_duration_ms = "round(sum(duration_ms, na.rm = TRUE), 2)"
        ),
        by = "name"
      ),
      top_spans_head = new_head_block(n = 5),
      duration_bar_plot = new_ggplot_block(
        type = "bar",
        x = "total_duration_ms",
        y = "name",
        visible = "outputs",
        block_name = "Span Duration Chart"
      ),

      # ══ Timeline (Gantt Chart) ═══════════════════════════════════════════════
      timeline_filter = new_filter_expr_block("duration_ms >= 50"),
      timeline_offsets = new_function_block(
        fn = "function(data) {
          d <- data[order(data$startTime), ]
          min_t <- min(d$startTime)
          d$offset_start <- (d$startTime - min_t) / 1e6
          d$offset_end <- d$offset_start + d$duration_ms
          d$span_label <- paste0(d$name, ' (', round(d$duration_ms, 1), 'ms)')
          d
        }"
      ),
      gantt_chart = new_echart_gantt_block(
        start = "offset_start",
        end = "offset_end",
        name = "span_label",
        color = "name",
        title = "Session Timeline",
        visible = "outputs",
        block_name = "Span Timeline"
      )
    ),
    links = list(
      # ── Duration filter + arrange ─────────────────────────────────────────
      new_link("otel_profiler", "spans_filter", "data"),
      new_link("spans_filter", "spans_arrange", "data"),
      # ── Session Summary chain ─────────────────────────────────────────────
      new_link("spans_arrange", "session_duration", "data"),
      new_link("session_duration", "session_kpi", "data"),
      # ── Spans sorted by duration ──────────────────────────────────────────
      new_link("spans_arrange", "spans_select", "data"),
      new_link("spans_select", "spans_head", "data"),
      new_link("spans_head", "spans_table", "data"),
      # ── Duration bar chart ────────────────────────────────────────────────
      new_link("spans_arrange", "top_spans_summary", "data"),
      new_link("top_spans_summary", "top_spans_head", "data"),
      new_link("top_spans_head", "duration_bar_plot", "data"),
      # ── Timeline (gantt chart) ────────────────────────────────────────────
      new_link("otel_profiler", "timeline_filter", "data"),
      new_link("timeline_filter", "timeline_offsets", "data"),
      new_link("timeline_offsets", "gantt_chart", "data")
    ),
    stacks = list(
      new_stack(
        blocks = c("session_duration", "session_kpi"),
        name = "Session Summary"
      ),
      new_stack(
        blocks = c("spans_select", "spans_head", "spans_table"),
        name = "Spans by Duration"
      ),
      new_stack(
        blocks = c(
          "top_spans_summary",
          "top_spans_head",
          "duration_bar_plot"
        ),
        name = "Span Duration Chart"
      ),
      new_stack(
        blocks = c("timeline_filter", "timeline_offsets", "gantt_chart"),
        name = "Span Timeline"
      )
    )
  )
)
