library(blockr)
library(blockr.bi)
library(blockr.extra)
library(blockr.echarts)
library(blockr.otel)
library(blockr.dplyr)
library(blockr.io)
library(mirai)

# ── Load app paths from config.yml ──────────────────────────────────────────
# Uses the config package (https://rstudio.github.io/config/).
# Copy config.yml.example to config.yml and edit app paths.
config_file <- "config.yml"
if (!file.exists(config_file)) {
  config_file <- system.file(
    "examples/otel-profiler/config.yml",
    package = "blockr.otel"
  )
}
if (!file.exists(config_file)) {
  stop(
    "config.yml not found. Copy config.yml.example to config.yml ",
    "and edit the app paths."
  )
}
apps <- config::get("apps", file = config_file)

# Async mode: span fetching runs in mirai workers,
# shinytest2 (chromote) runs in the main process.
daemons(5)
## automatically shutdown daemons when app exits
shiny::onStop(function() daemons(0))

# ── Build app driver blocks from config ─────────────────────────────────────
app_blocks <- lapply(names(apps), function(id) {
  a <- apps[[id]]
  new_app_driver_block(
    app_dir = a$app_dir,
    timeout = a$timeout %||% 15
  )
})
names(app_blocks) <- names(apps)

# ── Build per-app analysis branches ─────────────────────────────────────────
analysis_blocks <- list()
analysis_links <- list()
analysis_stacks <- list()

for (id in names(apps)) {
  svc <- apps[[id]]$service_name %||% id
  filter_id <- paste0("filter_", id)
  summary_id <- paste0(id, "_summary")
  arrange_id <- paste0(id, "_arrange")
  bar_id <- paste0(id, "_bar_plot")
  gantt_prep_id <- paste0(id, "_gantt_prep")
  gantt_id <- paste0(id, "_gantt_chart")

  analysis_blocks[[filter_id]] <- new_filter_block(
    state = list(
      conditions = list(
        list(
          type = "values",
          column = "service_name",
          values = svc,
          mode = "include"
        )
      ),
      operator = "&"
    )
  )
  analysis_blocks[[summary_id]] <- new_summarize_block(
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
  )
  analysis_blocks[[arrange_id]] <- new_arrange_block(
    state = list(
      columns = list(
        list(column = "total_duration_ms", direction = "desc")
      )
    )
  )
  analysis_blocks[[bar_id]] <- new_ggplot_block(
    type = "bar",
    x = "total_duration_ms",
    y = "name",
    visible = "outputs",
    block_name = paste(id, "Span Duration")
  )
  analysis_blocks[[gantt_prep_id]] <- new_mutate_block(
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
  )
  analysis_blocks[[gantt_id]] <- new_echart_gantt_block(
    start = "offset_start",
    end = "offset_end",
    name = "name",
    span_id = "spanID",
    parent_span_id = "parentSpanID",
    title = paste(id, "Trace Timeline"),
    visible = "outputs",
    block_name = paste(id, "Trace Timeline")
  )

  analysis_links <- c(analysis_links, list(
    new_link("spans_filter", filter_id, "data"),
    new_link(filter_id, summary_id, "data"),
    new_link(summary_id, arrange_id, "data"),
    new_link(arrange_id, bar_id, "data"),
    new_link(filter_id, gantt_prep_id, "data"),
    new_link(gantt_prep_id, gantt_id, "data")
  ))

  analysis_stacks <- c(analysis_stacks, list(
    new_stack(
      blocks = c(
        filter_id, summary_id, arrange_id, bar_id,
        gantt_prep_id, gantt_id
      ),
      name = paste(id, "Spans")
    )
  ))
}

# ── Assemble the board ──────────────────────────────────────────────────────
all_blocks <- c(
  app_blocks,
  list(
    otel_profiler = new_otel_block(browser_port = 8000L),
    otel_export = new_write_block(format = "parquet", filename = "spans"),
    spans_filter = new_filter_block(
      state = list(
        conditions = list(
          list(type = "expr", expr = "duration_ms >= 0")
        ),
        operator = "&"
      )
    )
  ),
  analysis_blocks
)

app_to_profiler_links <- lapply(names(apps), function(id) {
  new_link(id, "otel_profiler", "")
})

all_links <- c(
  app_to_profiler_links,
  list(
    new_link("otel_profiler", "otel_export", "data"),
    new_link("otel_profiler", "spans_filter", "data")
  ),
  analysis_links
)

serve(
  new_dock_board(
    extensions = new_dag_extension(),
    layout = list(
      list("ext_panel-dag_extension")
    ),
    blocks = all_blocks,
    links = all_links,
    stacks = analysis_stacks
  )
)
