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

          # ── Start viewer at init so it's ready before apps ─────────
          observe({
            http_port <- otel_http_port()
            grpc_port <- otel_grpc_port()
            viewer_info <- start_otel_viewer(
              r_browser_port(),
              http_port,
              grpc_port
            )
            r_viewer_pid(viewer_info$pid)

            # Kill viewer when the Shiny app stops
            pid <- viewer_info$pid
            port <- r_browser_port()
            shiny::onStop(function() {
              if (!is.null(pid)) {
                try(tools::pskill(pid), silent = TRUE)
              } else {
                # Viewer was reused; kill by port
                try(kill_viewer_by_port(port), silent = TRUE)
              }
            })
          }) |>
            bindEvent(TRUE) # runs once at init

          # ── Async span fetching (viewer already running) ───────────
          run_task <- ExtendedTask$new(function(browser_port) {
            # Fetch spans from already-running viewer (mirai worker, async)
            # All functions inlined to avoid namespace resolution issues
            # in the worker process (devtools::load_all doesn't serialize).
            m <- mirai::mirai(
              {
                rpc <- function(method, params = list()) {
                  httr2::request(
                    paste0("http://localhost:", browser_port, "/rpc")
                  ) |>
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

                summaries <- rpc("getTraceSummaries")$result
                spans_list <- unlist(
                  lapply(summaries, function(s) {
                    trace <- rpc("getTraceByID", list(s$traceID))$result
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
                        duration_ms = (as.numeric(d$endTime) -
                          as.numeric(d$startTime)) /
                          1e6,
                        depth = sp$depth,
                        service_name = if (!is.null(svc)) svc else NA_character_,
                        session_id = if (!is.null(d$attributes$session.id)) {
                          d$attributes$session.id
                        } else {
                          NA_character_
                        },
                        stringsAsFactors = FALSE
                      )
                    })
                  }),
                  recursive = FALSE
                )

                do.call(rbind, spans_list)
              },
              browser_port = browser_port
            )
            promises::as.promise(m)
          })

          bslib::bind_task_button(run_task, "run")

          # Trigger task on button click (only if apps are running)
          observe({
            if (!any_app_running()) {
              showNotification(
                "No apps are running. Start an app first.",
                type = "warning"
              )
              return()
            }
            run_task$invoke(
              browser_port = r_browser_port()
            )
          }) |>
            bindEvent(input$run)

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

          list(
            expr = task_result,
            state = list(
              browser_port = r_browser_port
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
          numericInput(
            inputId = ns("browser_port"),
            label = "Browser port",
            value = browser_port,
            min = 1024,
            max = 65535,
            width = "100%"
          ),
          uiOutput(ns("app_status")),
          div(
            style = "margin-top: 10px;",
            bslib::input_task_button(
              ns("run"),
              "Fetch Spans",
              class = "btn-primary"
            )
          )
        )
      )
    },
    dat_valid = function(...args) {
      stopifnot(length(...args) >= 1L)
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
#'
#' @return A list with `pid`, `browser_port`, `http_port`, `grpc_port`.
#' @export
start_otel_viewer <- function(
  browser_port = 8000L,
  http_port = 4318L,
  grpc_port = 4317L
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
