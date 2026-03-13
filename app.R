library(blockr)
library(blockr.bi)
library(blockr.extra)

spans_path <- normalizePath("spans.rds")

serve(
  new_dock_board(
    extensions = new_dag_extension(),
    layout = list(
      list(
        "ext_panel-dag_extension",
        list("session_kpi", "spans_table")
      ),
      list(
        list("duration_bar_plot", "timeline_plot")
      )
    ),
    blocks = list(
      # ══ Data Source ═══════════════════════════════════════════════════════════
      spans_read = new_read_block(path = spans_path),

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

      # ══ Timeline Plot ═════════════════════════════════════════════════════════
      timeline_filter = new_filter_expr_block("duration_ms >= 50"),
      timeline_plot = new_function_block(
        fn = "function(data) {
          d <- data[order(data$startTime), ]
          min_t <- min(d$startTime)
          d$offset_start <- (d$startTime - min_t) / 1e6
          d$offset_end <- d$offset_start + d$duration_ms
          d$span_label <- paste0(seq_len(nrow(d)), '. ', d$name, ' (', round(d$duration_ms, 1), 'ms)')
          d$y <- seq_len(nrow(d))
          # Scale height to number of spans (min 600px equivalent)
          n <- nrow(d)
          row_h <- 0.4
          ggplot2::ggplot(d) +
            ggplot2::geom_segment(
              ggplot2::aes(
                x = offset_start, xend = offset_end,
                y = stats::reorder(span_label, -y),
                yend = stats::reorder(span_label, -y),
                color = name
              ),
              linewidth = 3
            ) +
            ggplot2::labs(x = 'Time since session start (ms)', y = NULL, title = 'Session Timeline') +
            ggplot2::theme_minimal() +
            ggplot2::theme(
              legend.position = 'none',
              axis.text.y = ggplot2::element_text(size = 7),
              plot.margin = ggplot2::margin(5, 10, 5, 5)
            ) +
            ggplot2::coord_cartesian(clip = 'off')
        }",
        visible = "outputs",
        block_name = "Span Timeline"
      )
    ),
    links = list(
      # ── Duration filter + arrange ─────────────────────────────────────────
      new_link("spans_read", "spans_filter", "data"),
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

      # ── Timeline (full session, filtered for readability) ────────────────
      new_link("spans_read", "timeline_filter", "data"),
      new_link("timeline_filter", "timeline_plot", "data")
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
        blocks = c("timeline_filter", "timeline_plot"),
        name = "Span Timeline"
      )
    )
  )
)
