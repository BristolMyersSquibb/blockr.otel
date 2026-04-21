# Offline span analysis using the bundled otel_spans dataset.
# No live OTEL collector required.
library(blockr.core)
library(blockr.dock)
library(blockr.dag)
library(blockr.dplyr)
library(blockr.ggplot)
library(blockr.echarts)

serve(
  new_dock_board(
    extensions = new_dag_extension(),
    blocks = list(
      # -- Data source -------------------------------------------------------
      spans = new_dataset_block(
        dataset = "otel_spans",
        package = "blockr.otel"
      ),

      # -- Filter & arrange by duration ----------------------------------------
      spans_filter = new_filter_block(),
      spans_arrange = new_arrange_block(
        state = list(
          columns = list(
            list(column = "duration_ms", direction = "desc")
          )
        )
      ),

      # -- Summary by span name ----------------------------------------------
      spans_summary = new_summarize_block(
        state = list(
          summaries = list(
            list(
              type = "expr",
              name = "total_duration_ms",
              expr = "round(sum(duration_ms, na.rm = TRUE), 2)"
            ),
            list(type = "expr", name = "count", expr = "dplyr::n()"),
            list(
              type = "expr",
              name = "avg_duration_ms",
              expr = "round(mean(duration_ms, na.rm = TRUE), 2)"
            )
          ),
          by = list("name")
        )
      ),
      summary_arrange = new_arrange_block(
        state = list(
          columns = list(
            list(column = "total_duration_ms", direction = "desc")
          )
        )
      ),

      # -- Bar chart of top spans --------------------------------------------
      bar_plot = new_ggplot_block(
        type = "bar",
        x = "total_duration_ms",
        y = "name",
        visible = "outputs",
        block_name = "Span Duration"
      ),

      # -- Gantt timeline ----------------------------------------------------
      gantt_prep = new_mutate_block(
        state = list(
          mutations = list(
            list(
              name = "offset_start",
              expr = "(startTime - min(startTime, na.rm = TRUE)) / 1e6"
            ),
            list(name = "offset_end", expr = "offset_start + duration_ms")
          ),
          by = list()
        )
      ),
      gantt_chart = new_echart_gantt_block(
        start = "offset_start",
        end = "offset_end",
        name = "name",
        span_id = "spanID",
        parent_span_id = "parentSpanID",
        title = "Trace Timeline",
        visible = "outputs",
        block_name = "Trace Timeline"
      )
    ),
    links = list(
      new_link("spans", "spans_filter", "data"),
      new_link("spans_filter", "spans_arrange", "data"),
      # Summary branch
      new_link("spans_arrange", "spans_summary", "data"),
      new_link("spans_summary", "summary_arrange", "data"),
      new_link("summary_arrange", "bar_plot", "data"),
      # Gantt branch
      new_link("spans_arrange", "gantt_prep", "data"),
      new_link("gantt_prep", "gantt_chart", "data")
    ),
    stacks = list(
      new_stack(
        blocks = c("spans_summary", "summary_arrange", "bar_plot"),
        name = "Span Summary"
      ),
      new_stack(
        blocks = c("gantt_prep", "gantt_chart"),
        name = "Trace Timeline"
      )
    )
  )
)
