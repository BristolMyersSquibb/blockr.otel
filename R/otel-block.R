#' OTel Orchestrator Block
#'
#' A data block that manages the full OpenTelemetry profiling lifecycle:
#' starts otel-desktop-viewer, launches Shiny apps via shinytest2, waits
#' for spans, fetches them via RPC, and cleans up all processes.
#'
#' Runs asynchronously using [ExtendedTask] and [mirai::mirai()] so the
#' Shiny session remains responsive during profiling.
#'
#' @param app_paths Character vector of paths to Shiny app directories
#' @param browser_port Web UI / JSON-RPC port for otel-desktop-viewer (default 8000)
#' @param http_port OTLP HTTP receiver port (default 4318)
#' @param grpc_port OTLP gRPC receiver port (default 4317)
#' @param ... Forwarded to [blockr.core::new_data_block()]
#'
#' @return A block object of class `otel_block`.
#' @export
new_otel_block <- function(
  app_paths = character(),
  browser_port = 8000L,
  http_port = 4318L,
  grpc_port = 4317L,
  ...
) {
  app_paths_init <- if (length(app_paths) == 0) "" else app_paths

  blockr.core::new_data_block(
    server = function(id) {
      moduleServer(
        id,
        function(input, output, session) {
          ns <- session$ns
          r_app_paths <- reactiveVal(app_paths)
          r_browser_port <- reactiveVal(browser_port)
          r_http_port <- reactiveVal(http_port)
          r_grpc_port <- reactiveVal(grpc_port)

          # Dynamic app path management
          r_path_count <- reactiveVal(max(1L, length(app_paths)))

          observeEvent(input$add_path, {
            n <- r_path_count() + 1L
            r_path_count(n)
            insertUI(
              selector = paste0("#", ns("path_list")),
              where = "beforeEnd",
              ui = div(
                id = ns(paste0("path_row_", n)),
                class = "otel-path-row",
                style = "display: flex; gap: 4px; margin-bottom: 4px;",
                textInput(
                  inputId = ns(paste0("app_path_", n)),
                  label = NULL,
                  value = "",
                  width = "100%",
                  placeholder = "/path/to/app"
                ),
                actionButton(
                  inputId = ns(paste0("rm_path_", n)),
                  label = "",
                  icon = icon("xmark"),
                  class = "btn-sm btn-outline-danger",
                  style = "margin-top: 0; height: 34px; flex-shrink: 0;"
                )
              )
            )
            observeEvent(
              input[[paste0("rm_path_", n)]],
              {
                removeUI(selector = paste0("#", ns(paste0("path_row_", n))))
              },
              once = TRUE
            )
          })

          collect_paths <- function() {
            paths <- character()
            for (i in seq_len(r_path_count())) {
              val <- input[[paste0("app_path_", i)]]
              if (!is.null(val) && nchar(trimws(val)) > 0) {
                paths <- c(paths, trimws(val))
              }
            }
            paths
          }

          observeEvent(
            input$browser_port,
            r_browser_port(as.integer(input$browser_port))
          )
          observeEvent(
            input$http_port,
            r_http_port(as.integer(input$http_port))
          )
          observeEvent(
            input$grpc_port,
            r_grpc_port(as.integer(input$grpc_port))
          )
          # ── Async profiling task via ExtendedTask + mirai ──────────────
          mirais <- list()

          run_task <- ExtendedTask$new(function(...) {
            mirais[["otel"]] <<- mirai::mirai(
              {
                .run(
                  app_paths = app_paths,
                  browser_port = browser_port,
                  http_port = http_port,
                  grpc_port = grpc_port
                )
              },
              ...
            )
          })

          bslib::bind_task_button(run_task, "run")

          # Trigger task on button click
          observe({
            paths <- collect_paths()
            r_app_paths(paths)

            run_task$invoke(
              app_paths = paths,
              browser_port = r_browser_port(),
              http_port = r_http_port(),
              grpc_port = r_grpc_port(),
              .run = run_otel_profiling
            )
          }) |>
            bindEvent(input$run)

          # Cancel handler
          observe({
            mirai::stop_mirai(mirais[["otel"]])
          }) |>
            bindEvent(input$cancel)

          # Enable/disable cancel button based on task status
          observe({
            shiny::updateActionButton(
              session,
              "cancel",
              disabled = run_task$status() != "running"
            )
          }) |>
            bindEvent(run_task$status())

          # Result reactive with status handling
          task_result <- reactive({
            tryCatch(
              bquote_extended_task(
                run_task$result(),
                "Profiling complete.",
                run_task$status()
              ),
              error = function(e) {
                status <- run_task$status()
                msg <- switch(
                  status,
                  "initial" = "Ready to profile.",
                  "running" = "Profiling in progress...",
                  "error" = sprintf("Error: %s", e$message),
                  "Error"
                )
                bquote_extended_task(data.frame(), msg, status)
              }
            )
          })

          list(
            expr = task_result,
            state = list(
              app_paths = r_app_paths,
              browser_port = r_browser_port,
              http_port = r_http_port,
              grpc_port = r_grpc_port
            )
          )
        }
      )
    },
    ui = function(id) {
      ns <- NS(id)

      tagList(
        div(
          style = "padding: 10px;",

          tags$h4("OTel Profiler"),

          tags$label("App paths"),
          div(
            id = ns("path_list"),
            lapply(seq_along(app_paths_init), function(i) {
              div(
                id = ns(paste0("path_row_", i)),
                class = "otel-path-row",
                style = "display: flex; gap: 4px; margin-bottom: 4px;",
                textInput(
                  inputId = ns(paste0("app_path_", i)),
                  label = NULL,
                  value = app_paths_init[i],
                  width = "100%",
                  placeholder = "/path/to/app"
                ),
                actionButton(
                  inputId = ns(paste0("rm_path_", i)),
                  label = "",
                  icon = icon("xmark"),
                  class = "btn-sm btn-outline-danger",
                  style = "margin-top: 0; height: 34px; flex-shrink: 0;"
                )
              )
            })
          ),
          actionButton(
            inputId = ns("add_path"),
            label = "Add app",
            icon = icon("plus"),
            class = "btn-sm btn-outline-secondary",
            style = "margin-bottom: 8px;"
          ),

          div(
            style = "display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px; margin-top: 8px;",
            numericInput(
              inputId = ns("browser_port"),
              label = "Browser port",
              value = browser_port,
              min = 1024,
              max = 65535,
              width = "100%"
            ),
            numericInput(
              inputId = ns("http_port"),
              label = "HTTP port",
              value = http_port,
              min = 1024,
              max = 65535,
              width = "100%"
            ),
            numericInput(
              inputId = ns("grpc_port"),
              label = "gRPC port",
              value = grpc_port,
              min = 1024,
              max = 65535,
              width = "100%"
            )
          ),

          div(
            class = "d-flex gap-2",
            style = "margin-top: 10px;",
            bslib::input_task_button(
              ns("run"),
              "Run Profiling",
              class = "btn-primary"
            ),
            actionButton(
              ns("cancel"),
              "Cancel",
              class = "btn-danger btn-sm"
            )
          )
        )
      )
    },
    class = c("otel_block", "async_block"),
    ...
  )
}

#' Wrap result with status metadata (for async blocks)
#' @param res The result data
#' @param msg Status message
#' @param status Task status string
#' @noRd
bquote_extended_task <- function(res, msg, status) {
  bquote(structure(.(res), msg = .(msg), status = .(status)))
}

#' Run the full OTel profiling pipeline (synchronous, called inside mirai)
#'
#' @param app_paths Character vector of app directory paths
#' @param browser_port otel-desktop-viewer browser port
#' @param http_port OTLP HTTP port
#' @param grpc_port OTLP gRPC port
#'
#' @return A data.frame of spans
#' @export
run_otel_profiling <- function(
  app_paths,
  browser_port = 8000L,
  http_port = 4318L,
  grpc_port = 4317L
) {
  if (length(app_paths) == 0) {
    stop("No app paths specified")
  }

  # Check Go is installed (inline to avoid closure issues in mirai)
  go_path <- tryCatch(
    trimws(system2("go", "env GOPATH", stdout = TRUE, stderr = TRUE)),
    error = function(e) NULL
  )
  if (is.null(go_path) || length(go_path) == 0) {
    stop("Go is not installed. Please install Go first: https://go.dev/dl/")
  }

  viewer_bin <- file.path(go_path, "bin", "otel-desktop-viewer")
  if (!file.exists(viewer_bin)) {
    stop(
      "otel-desktop-viewer not found at ",
      viewer_bin,
      ". Install with: go install github.com/nicktrav/otel-desktop-viewer@latest"
    )
  }

  # Start otel-desktop-viewer
  viewer_proc <- processx::process$new(
    command = viewer_bin,
    args = c(
      "--browser-port",
      as.character(browser_port),
      "--http",
      as.character(http_port),
      "--grpc",
      as.character(grpc_port)
    ),
    stdout = "|",
    stderr = "|"
  )
  on.exit(try(viewer_proc$kill(), silent = TRUE), add = TRUE)

  # RPC helper
  rpc <- function(method, params = list()) {
    httr2::request(paste0("http://localhost:", browser_port, "/rpc")) |>
      httr2::req_body_json(list(
        jsonrpc = "2.0",
        method = method,
        params = params,
        id = 1
      )) |>
      httr2::req_timeout(seconds = 5) |>
      httr2::req_retry(max_tries = 3, backoff = ~ 2) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
  }

  # Wait for viewer to be ready (retries connection-refused errors)
  for (i in seq_len(10)) {
    if (!viewer_proc$is_alive()) {
      stop("otel-desktop-viewer died: ", viewer_proc$read_all_error())
    }
    ready <- tryCatch(
      {
        rpc("getTraceSummaries")
        TRUE
      },
      error = function(e) FALSE
    )
    if (ready) break
    Sys.sleep(0.5)
  }
  if (!ready) {
    stop("otel-desktop-viewer did not become ready after 5s")
  }

  # Launch apps
  apps <- lapply(app_paths, function(path) {
    svc_name <- tools::file_path_sans_ext(basename(path))

    # shinytest2 requires app.R or ui.R/server.R naming
    app_dir <- if (file.info(path)$isdir) {
      path
    } else {
      tmp <- tempfile(pattern = svc_name)
      dir.create(tmp)
      file.copy(path, file.path(tmp, "app.R"))
      tmp
    }

    withr::with_envvar(
      c(
        OTEL_SERVICE_NAME = svc_name,
        OTEL_EXPORTER_OTLP_ENDPOINT = paste0("http://localhost:", http_port),
        OTEL_TRACES_EXPORTER = "otlp",
        OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
      ),
      shinytest2::AppDriver$new(
        app_dir = app_dir,
        name = svc_name
      )
    )
  })

  # Verify viewer is still alive before fetching
  if (!viewer_proc$is_alive()) {
    stop(
      "otel-desktop-viewer crashed during profiling: ",
      viewer_proc$read_all_error()
    )
  }

  # Debug: check viewer stderr for clues
  viewer_err <- viewer_proc$read_error()
  if (nchar(viewer_err) > 0) message("viewer stderr: ", viewer_err)

  # Fetch spans
  summaries <- rpc("getTraceSummaries")$result

  spans_list <- unlist(
    lapply(summaries, function(s) {
      trace <- rpc("getTraceByID", list(s$traceID))$result
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

  spans_df <- do.call(rbind, spans_list)

  # Stop apps after fetching spans
  lapply(apps, function(app) {
    try(app$stop(), silent = TRUE)
  })

  # Stop viewer (also handled by on.exit)
  try(viewer_proc$kill(), silent = TRUE)

  spans_df
}
