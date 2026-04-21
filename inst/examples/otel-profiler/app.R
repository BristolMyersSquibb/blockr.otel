library(blockr)
library(blockr.bi)
library(blockr.extra)
library(blockr.echarts)
library(blockr.otel)
library(blockr.dplyr)
library(blockr.io)
library(mirai)

# Async mode: span fetching runs in mirai workers,
# shinytest2 (chromote) runs in the main process.
daemons(5)
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
      # ══ App Drivers ═════════════════════════════════════════════════════════
      app1 = new_app_driver_block(
        app_dir = "/Users/davidgranjon
/david/Sandbox/filter-cran",
        timeout = 15,
        #app_dir = "/Users/davidgranjon/david/Cynkra/athlyticz/workshop1"
      ),
      app2 = new_app_driver_block(
        app_dir = "/Users/davidgranjon
/david/Sandbox/filter-github",
        #app_dir = "/Users/davidgranjon/david/Cynkra/SAV-finance/blockr-demo-sav",
        timeout = 15
      ),

      app3 = new_app_driver_block(
        app_dir = "/Users/davidgranjon/david/Cynkra/BMS/blockr.dag/inst/examples/empty"
      ),

      # ══ OTel Profiler ═════════════════════════════════════════════════════════
      otel_profiler = new_otel_block(
        browser_port = 8000L
      ),

      # ══ Parquet Export ══════════════════════════════════════════════════════════
      otel_export = new_write_block(
        format = "parquet",
        filename = "spans"
      ),

      # ══ Duration Filter ════════════════════════════════════════════════════════
      spans_filter = new_filter_block(
        state = list(
          conditions = list(
            list(type = "expr", expr = "duration_ms >= 0")
          ),
          operator = "&"
        )
      ),
      # ══ App 1 branch ═══════════════════════════════════════════════════════
      filter_app1 = new_filter_block(
        state = list(
          conditions = list(
            list(
              type = "values",
              column = "service_name",
              values = "empty",
              mode = "include"
            )
          ),
          operator = "&"
        )
      ),
      app1_summary = new_summarize_block(
        state = list(
          summaries = list(
            list(
              type = "expr",
              name = "total_duration_ms",
              expr = "round(sum(duration_ms, na.rm = TRUE), 2)"
            )
          ),
          by = list("name")
        )
      ),
      app1_arrange = new_arrange_block(
        state = list(
          columns = list(
            list(column = "total_duration_ms", direction = "desc")
          )
        )
      ),
      app1_bar_plot = new_ggplot_block(
        type = "bar",
        x = "total_duration_ms",
        y = "name",
        visible = "outputs",
        block_name = "App 1 Span Duration"
      ),

      # ══ App 2 branch ═══════════════════════════════════════════════════════
      filter_app2 = new_filter_block(
        state = list(
          conditions = list(
            list(
              type = "values",
              column = "service_name",
              values = "blockr-demo-sav",
              mode = "include"
            )
          ),
          operator = "&"
        )
      ),
      app2_summary = new_summarize_block(
        state = list(
          summaries = list(
            list(
              type = "expr",
              name = "total_duration_ms",
              expr = "round(sum(duration_ms, na.rm = TRUE), 2)"
            )
          ),
          by = list("name")
        )
      ),
      app2_arrange = new_arrange_block(
        state = list(
          columns = list(
            list(column = "total_duration_ms", direction = "desc")
          )
        )
      ),
      app2_bar_plot = new_ggplot_block(
        type = "bar",
        x = "total_duration_ms",
        y = "name",
        visible = "outputs",
        block_name = "App 2 Span Duration"
      ),

      # ══ App 1 Trace Gantt Timeline ════════════════════════════════════════════
      app1_gantt_prep = new_mutate_block(
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
      app1_gantt_chart = new_echart_gantt_block(
        start = "offset_start",
        end = "offset_end",
        name = "name",
        span_id = "spanID",
        parent_span_id = "parentSpanID",
        title = "App 1 Trace Timeline",
        visible = "outputs",
        block_name = "App 1 Trace Timeline"
      ),

      # ══ App 2 Trace Gantt Timeline ════════════════════════════════════════════
      app2_gantt_prep = new_mutate_block(
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
      app2_gantt_chart = new_echart_gantt_block(
        start = "offset_start",
        end = "offset_end",
        name = "name",
        span_id = "spanID",
        parent_span_id = "parentSpanID",
        title = "App 2 Trace Timeline",
        visible = "outputs",
        block_name = "App 2 Trace Timeline"
      )
    ),
    links = list(
      # ── App drivers → OTel profiler (variadic) ────────────────────────────
      new_link("app1", "otel_profiler", ""),
      new_link("app2", "otel_profiler", ""),
      new_link("app3", "otel_profiler", ""),
      # ── OTel profiler → downstream ────────────────────────────────────────
      new_link("otel_profiler", "otel_export", "data"),
      new_link("otel_profiler", "spans_filter", "data"),
      # ── App 1 branch ──────────────────────────────────────────────────────
      new_link("spans_filter", "filter_app1", "data"),
      new_link("filter_app1", "app1_summary", "data"),
      new_link("app1_summary", "app1_arrange", "data"),
      new_link("app1_arrange", "app1_bar_plot", "data"),
      # ── App 2 branch ──────────────────────────────────────────────────────
      new_link("spans_filter", "filter_app2", "data"),
      new_link("filter_app2", "app2_summary", "data"),
      new_link("app2_summary", "app2_arrange", "data"),
      new_link("app2_arrange", "app2_bar_plot", "data"),
      # ── App 1 trace gantt timeline ─────────────────────────────────────────
      new_link("filter_app1", "app1_gantt_prep", "data"),
      new_link("app1_gantt_prep", "app1_gantt_chart", "data"),
      # ── App 2 trace gantt timeline ─────────────────────────────────────────
      new_link("filter_app2", "app2_gantt_prep", "data"),
      new_link("app2_gantt_prep", "app2_gantt_chart", "data")
    ),
    stacks = list(
      new_stack(
        blocks = c(
          "filter_app1",
          "app1_summary",
          "app1_arrange",
          "app1_bar_plot",
          "app1_gantt_prep",
          "app1_gantt_chart"
        ),
        name = "App 1 Spans"
      ),
      new_stack(
        blocks = c(
          "filter_app2",
          "app2_summary",
          "app2_arrange",
          "app2_bar_plot",
          "app2_gantt_prep",
          "app2_gantt_chart"
        ),
        name = "App 2 Spans"
      )
    )
  )
)
