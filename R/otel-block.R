#' OTel Profiler Block
#'
#' A variadic transform block that starts otel-desktop-viewer, collects
#' spans from upstream [new_app_driver_block] apps, and returns a
#' consolidated spans data.frame.
#'
#' Connects to one or more `app_driver_block`s via the `...args` variadic
#' input. Port configuration is resolved from environment variables
#' (see [otel_http_port()], [otel_grpc_port()]).
#'
#' @param browser_port Web UI / JSON-RPC port for otel-desktop-viewer
#'   (default 8000)
#' @param ... Forwarded to [blockr.core::new_transform_block()]
#'
#' @return A block object of class `otel_block`.
#' @export
new_otel_block <- function(
  browser_port = 8000L,
  ...
) {
  blockr.core::new_transform_block(
    server = function(id, ...args) {
      moduleServer(
        id,
        function(input, output, session) {
          ns <- session$ns
          r_browser_port <- reactiveVal(browser_port)
          r_viewer_pid <- reactiveVal(NULL)

          observeEvent(
            input$browser_port,
            r_browser_port(as.integer(input$browser_port))
          )

          # ── Check if any upstream app is running ──────────────────
          any_app_running <- reactive({
            args_list <- reactiveValuesToList(...args)
            if (length(args_list) == 0) {
              return(FALSE)
            }
            any(vapply(
              args_list,
              function(x) {
                if (is.null(x)) {
                  return(FALSE)
                }
                if (!is.data.frame(x)) {
                  return(FALSE)
                }
                nrow(x) > 0 && "app_url" %in% names(x) && !is.na(x$app_url[1])
              },
              logical(1)
            ))
          })

          r_viewer_status <- reactiveVal("unknown")

          # ── Start/stop viewer helpers ────────────────────────────────
          do_start_viewer <- function() {
            http_port <- otel_http_port()
            grpc_port <- otel_grpc_port()
            viewer_info <- start_otel_viewer(
              r_browser_port(),
              http_port,
              grpc_port
            )
            r_viewer_pid(viewer_info$pid)
            r_viewer_status("healthy")
          }

          do_stop_viewer <- function() {
            pid <- r_viewer_pid()
            if (!is.null(pid)) {
              try(tools::pskill(pid), silent = TRUE)
            } else {
              try(kill_viewer_by_port(r_browser_port()), silent = TRUE)
            }
            r_viewer_pid(NULL)
            r_viewer_status("error")
          }

          # Auto-start on init; clean up on session end
          observe({
            do_start_viewer()
          }) |>
            bindEvent(TRUE) # runs once at init

          session$onSessionEnded(function() {
            pid <- isolate(r_viewer_pid())
            port <- isolate(r_browser_port())
            if (!is.null(pid)) {
              try(tools::pskill(pid), silent = TRUE)
            } else {
              try(kill_viewer_by_port(port), silent = TRUE)
            }
          })

          # Start/Stop buttons
          observeEvent(input$start_viewer, do_start_viewer())
          observeEvent(input$stop_viewer, do_stop_viewer())

          # ── Health polling ──────────────────────────────────────────
          poll <- reactiveTimer(5000)
          observe({
            poll()
            alive <- tryCatch({
              rpc_call("getTraceSummaries", port = r_browser_port())
              TRUE
            }, error = function(e) FALSE)
            r_viewer_status(if (alive) "healthy" else "error")
            if (alive) {
              shinyjs::disable("start_viewer")
              shinyjs::enable("stop_viewer")
            } else {
              shinyjs::enable("start_viewer")
              shinyjs::disable("stop_viewer")
            }
          })

          # ── Viewer status output ────────────────────────────────────
          output$viewer_status <- renderUI({
            status <- r_viewer_status()
            color <- if (status == "healthy") "#16a34a" else "#dc2626"
            fill <- if (status == "healthy") "#dcfce7" else "#fee2e2"
            label <- if (status == "healthy") "Running" else "Down"
            tags$div(
              class = "d-flex align-items-center gap-2",
              style = "margin-bottom: 8px;",
              tags$span(
                class = "badge",
                style = sprintf(
                  "background-color:%s;color:%s;border:1px solid %s;",
                  fill, color, color
                ),
                label
              ),
              if (status == "healthy") {
                tags$a(
                  href = sprintf("http://localhost:%s/", r_browser_port()),
                  target = "_blank",
                  class = "small",
                  icon("external-link-alt"),
                  " Viewer UI"
                )
              }
            )
          })

          # ── Async span fetching (viewer already running) ───────────
          run_task <- ExtendedTask$new(function(browser_port) {
            # Fetch spans from already-running viewer (mirai worker, async)
            # All functions inlined to avoid namespace resolution issues
            # in the worker process (devtools::load_all doesn't serialize).
            m <- mirai::mirai(
              {
                base_url <- paste0(
                  "http://localhost:",
                  browser_port,
                  "/rpc"
                )

                rpc <- function(method, params = list()) {
                  httr2::request(base_url) |>
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

                empty_df <- data.frame(
                  traceID = character(),
                  spanID = character(),
                  parentSpanID = character(),
                  name = character(),
                  kind = character(),
                  statusCode = character(),
                  startTime = numeric(),
                  endTime = numeric(),
                  duration_ms = numeric(),
                  depth = integer(),
                  service_name = character(),
                  session_id = character(),
                  stringsAsFactors = FALSE
                )

                summaries <- rpc("getTraceSummaries")$result
                if (length(summaries) == 0) {
                  return(empty_df)
                }

                # Fetch all traces in parallel
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
                resps <- httr2::req_perform_parallel(
                  reqs,
                  on_error = "continue"
                )

                # Count total spans for pre-allocation
                traces <- lapply(resps, function(r) {
                  tryCatch(
                    httr2::resp_body_json(r)$result,
                    error = function(e) NULL
                  )
                })
                n_total <- sum(vapply(
                  traces,
                  function(t) if (is.null(t)) 0L else length(t$spans),
                  integer(1)
                ))
                if (n_total == 0) {
                  return(empty_df)
                }

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
                  if (is.null(trace)) {
                    next
                  }
                  for (sp in trace$spans) {
                    idx <- idx + 1L
                    d <- sp$spanData
                    v_traceID[idx] <- d$traceID %||% NA_character_
                    v_spanID[idx] <- d$spanID %||% NA_character_
                    v_parentSpanID[idx] <- d$parentSpanID %||%
                      NA_character_
                    v_name[idx] <- d$name %||% NA_character_
                    v_kind[idx] <- d$kind %||% NA_character_
                    v_statusCode[idx] <- d$statusCode %||% NA_character_
                    v_startTime[idx] <- as.numeric(d$startTime)
                    v_endTime[idx] <- as.numeric(d$endTime)
                    v_depth[idx] <- sp$depth %||% 0L
                    svc <- d$resource$attributes$service.name
                    v_service_name[idx] <- if (is.null(svc) || !nzchar(svc)) {
                      NA_character_
                    } else {
                      svc
                    }
                    sid <- d$attributes$session.id
                    v_session_id[idx] <- sid %||% NA_character_
                  }
                }

                data.frame(
                  traceID = v_traceID,
                  spanID = v_spanID,
                  parentSpanID = v_parentSpanID,
                  name = v_name,
                  kind = v_kind,
                  statusCode = v_statusCode,
                  startTime = v_startTime,
                  endTime = v_endTime,
                  duration_ms = (v_endTime - v_startTime) / 1e6,
                  depth = v_depth,
                  service_name = v_service_name,
                  session_id = v_session_id,
                  stringsAsFactors = FALSE
                )
              },
              browser_port = browser_port
            )
            promises::as.promise(m)
          })

          bslib::bind_task_button(run_task, "run")

          # Overridden by clear button
          r_cleared <- reactiveVal(FALSE)
          r_has_data <- reactiveVal(FALSE)

          # ── Toggle buttons based on app/data status ─────────────────
          observe({
            if (any_app_running()) {
              shinyjs::enable("run")
            } else {
              shinyjs::disable("run")
            }
            if (any_app_running() && r_has_data()) {
              shinyjs::enable("clear")
            } else {
              shinyjs::disable("clear")
            }
          })

          # Trigger task on button click
          observe({
            r_cleared(FALSE)
            run_task$invoke(
              browser_port = r_browser_port()
            )
          }) |>
            bindEvent(input$run)

          # Track when data is available
          observe({
            result <- run_task$result()
            r_has_data(is.data.frame(result) && nrow(result) > 0)
          })

          # Result reactive with status handling
          task_result <- reactive({
            if (r_cleared()) {
              return(bquote_extended_task(
                data.frame(),
                "Traces cleared.",
                "initial"
              ))
            }
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

          # ── App status display ──────────────────────────────────
          output$app_status <- renderUI({
            args_list <- reactiveValuesToList(...args)
            running <- Filter(
              function(x) {
                is.data.frame(x) &&
                  nrow(x) > 0 &&
                  "app_url" %in% names(x) &&
                  !is.na(x$app_url[1])
              },
              args_list
            )
            n <- length(running)
            if (n == 0) {
              tags$p(
                class = "text-warning",
                style = "margin-top: 5px; font-size: 0.85em;",
                icon("exclamation-triangle"),
                " No apps running"
              )
            } else {
              names_list <- vapply(running, function(x) x$name[1], character(1))
              tags$p(
                class = "text-success",
                style = "margin-top: 5px; font-size: 0.85em;",
                icon("check-circle"),
                sprintf(
                  " %d app(s) running: %s",
                  n,
                  paste(names_list, collapse = ", ")
                )
              )
            }
          })

          # ── Clear spans ─────────────────────────────────────────
          observeEvent(input$clear, {
            tryCatch(
              {
                rpc_call("clearTraces", port = r_browser_port())
                r_cleared(TRUE)
                r_has_data(FALSE)
                showNotification(
                  "Traces cleared.",
                  type = "message",
                  duration = 3
                )
              },
              error = function(e) {
                showNotification(
                  paste("Clear failed:", e$message),
                  type = "error",
                  duration = 5
                )
              }
            )
          })

          list(
            expr = task_result,
            state = list(
              browser_port = r_browser_port,
              viewer_status = r_viewer_status,
              viewer_pid = r_viewer_pid
            )
          )
        }
      )
    },
    ui = function(id) {
      ns <- NS(id)

      tagList(
        shinyjs::useShinyjs(),
        div(
          style = "padding: 10px;",
          tags$h4(icon("chart-line"), " OTel Profiler"),
          uiOutput(ns("viewer_status")),
          div(
            class = "d-flex gap-2 flex-wrap",
            style = "margin-bottom: 10px;",
            actionButton(
              ns("start_viewer"),
              "Start",
              icon = icon("play"),
              class = "btn-success btn-sm"
            ),
            actionButton(
              ns("stop_viewer"),
              "Stop",
              icon = icon("stop"),
              class = "btn-danger btn-sm"
            ),
            bslib::input_task_button(
              ns("run"),
              "Fetch Spans",
              class = "btn-primary btn-sm"
            ),
            actionButton(
              ns("clear"),
              "Clear Spans",
              icon = icon("trash"),
              class = "btn-secondary btn-sm"
            )
          ),
          uiOutput(ns("app_status"))
        )
      )
    },
    dat_valid = function(...args) {
      stopifnot(length(...args) >= 1L)
      has_running <- any(vapply(
        ...args,
        function(x) {
          is.data.frame(x) &&
            nrow(x) > 0 &&
            "app_url" %in% names(x) &&
            !is.na(x$app_url[1])
        },
        logical(1)
      ))
      if (!has_running) {
        stop("No app running. Click Start to launch in App block.")
      }
    },
    allow_empty_state = TRUE,
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

#' Kill otel-desktop-viewer by browser port
#'
#' Finds the process listening on the given port and kills it.
#' Used for cleanup when we reused an existing viewer (pid unknown).
#'
#' @param port Browser port the viewer is listening on
#' @noRd
kill_viewer_by_port <- function(port) {
  # Use lsof to find the PID listening on the port
  out <- tryCatch(
    system2("lsof", c("-ti", paste0(":", port)), stdout = TRUE, stderr = FALSE),
    error = function(e) character(0)
  )
  pids <- as.integer(out[nzchar(out)])
  pids <- pids[!is.na(pids)]
  for (pid in pids) {
    try(tools::pskill(pid), silent = TRUE)
  }
}

#' Start otel-desktop-viewer and wait for it to be ready
#'
#' Starts the viewer process with `cleanup = FALSE` so it survives
#' independently, then polls until the RPC endpoint responds.
#'
#' @param browser_port otel-desktop-viewer browser port
#' @param http_port OTLP HTTP port
#' @param grpc_port OTLP gRPC port
#' @param bind Host address to bind to. Reads `OTEL_VIEWER_BIND` env var.
#'   Set to `"0.0.0.0"` to listen on all interfaces (needed for Docker).
#'
#' @return A list with `pid`, `browser_port`, `http_port`, `grpc_port`.
#' @export
start_otel_viewer <- function(
  browser_port = 8000L,
  http_port = 4318L,
  grpc_port = 4317L,
  bind = Sys.getenv("OTEL_VIEWER_BIND", "")
) {
  # Check if a viewer is already running on this port
  already_running <- tryCatch(
    {
      rpc_call("getTraceSummaries", port = browser_port)
      TRUE
    },
    error = function(e) FALSE
  )

  if (already_running) {
    return(list(
      pid = NULL,
      browser_port = browser_port,
      http_port = http_port,
      grpc_port = grpc_port
    ))
  }

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

  host_args <- if (nchar(bind) > 0L) c("--host", bind) else character()
  viewer_proc <- processx::process$new(
    command = viewer_bin,
    args = c(
      "--browser-port",
      as.character(browser_port),
      "--http",
      as.character(http_port),
      "--grpc",
      as.character(grpc_port),
      host_args
    ),
    stdout = "|",
    stderr = "|",
    cleanup = FALSE
  )

  # Wait for viewer to be ready (up to ~15s)
  ready <- FALSE
  for (i in seq_len(30)) {
    if (!viewer_proc$is_alive()) {
      stop("otel-desktop-viewer died: ", viewer_proc$read_all_error())
    }
    ready <- tryCatch(
      {
        rpc_call("getTraceSummaries", port = browser_port)
        TRUE
      },
      error = function(e) FALSE
    )
    if (ready) {
      break
    }
    Sys.sleep(0.5)
  }
  if (!ready) {
    stderr_out <- tryCatch(
      viewer_proc$read_all_error(),
      error = function(e) ""
    )
    try(viewer_proc$kill(), silent = TRUE)
    stop(
      "otel-desktop-viewer did not become ready after 15s.",
      if (nchar(stderr_out) > 0) paste0(" stderr: ", stderr_out) else ""
    )
  }

  list(
    pid = viewer_proc$get_pid(),
    browser_port = browser_port,
    http_port = http_port,
    grpc_port = grpc_port
  )
}

#' Launch Shiny apps via shinytest2 with OTEL env vars
#'
#' Must run in the main R process (chromote requirement).
#' Kept for backwards compatibility; prefer [new_app_driver_block()] instead.
#'
#' @param app_paths Character vector of app directory paths
#' @param http_port OTLP HTTP port for the exporter endpoint
#'
#' @return A list of [shinytest2::AppDriver] objects.
#' @export
launch_apps <- function(app_paths, http_port = 4318L) {
  if (length(app_paths) == 0) {
    stop("No app paths specified")
  }

  lapply(app_paths, function(path) {
    svc_name <- tools::file_path_sans_ext(basename(path))

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
}

#' Fetch spans from otel-desktop-viewer and kill the viewer process
#'
#' Fetches all spans via RPC, then terminates the viewer by PID.
#'
#' @param browser_port RPC port for the viewer
#' @param viewer_pid PID of the otel-desktop-viewer process to kill
#'
#' @return A data.frame of spans.
#' @export
fetch_spans_and_cleanup <- function(browser_port, viewer_pid) {
  spans_df <- fetch_spans(port = browser_port)
  tools::pskill(viewer_pid)
  spans_df
}

#' Run the full OTel profiling pipeline (synchronous)
#'
#' Kept for backwards compatibility. Runs all phases sequentially.
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
  viewer_info <- start_otel_viewer(browser_port, http_port, grpc_port)
  on.exit(try(tools::pskill(viewer_info$pid), silent = TRUE), add = TRUE)

  apps <- launch_apps(app_paths, http_port)
  on.exit(
    lapply(apps, function(app) try(app$stop(), silent = TRUE)),
    add = TRUE
  )

  fetch_spans_and_cleanup(browser_port, viewer_info$pid)
}
