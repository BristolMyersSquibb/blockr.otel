#' App Driver Block
#'
#' A data block that starts a Shiny app via [shinytest2::AppDriver] in a
#' background Rscript process. The AppDriver handles both launching the app
#' and connecting a headless Chrome session, triggering Shiny session
#' creation and OTEL span generation.
#'
#' @param app_dir Path to a Shiny app directory or single-file app.
#' @param name Optional service name for OTEL. Defaults to the app
#'   directory basename.
#' @param ... Forwarded to [blockr.core::new_data_block()]
#'
#' @return A block object of class `app_driver_block`.
#' @export
new_app_driver_block <- function(
  app_dir = "",
  name = NULL,
  ...
) {
  blockr.core::new_data_block(
    server = function(id) {
      moduleServer(
        id,
        function(input, output, session) {
          ns <- session$ns

          r_app_dir <- reactiveVal(app_dir)
          r_process <- reactiveVal(NULL)
          r_app_url <- reactiveVal(NULL)
          r_svc_name <- reactiveVal(name %||% "")
          r_result <- reactiveVal(
            data.frame(
              app_url = NA_character_,
              name = name %||% "",
              stringsAsFactors = FALSE
            )
          )

          observeEvent(input$app_dir, r_app_dir(trimws(input$app_dir)))

          # ── Start app ──────────────────────────────────────────────
          observeEvent(input$start, {
            stop_app_driver(r_process)
            r_process(NULL)

            app_dir_val <- r_app_dir()
            if (nchar(app_dir_val) == 0) return()

            svc_name <- name %||% tools::file_path_sans_ext(
              basename(app_dir_val)
            )

            # Handle single-file apps
            resolved_dir <- if (
              !grepl("^https?://", app_dir_val) &&
                file.exists(app_dir_val) &&
                !file.info(app_dir_val)$isdir
            ) {
              tmp <- tempfile(pattern = svc_name)
              dir.create(tmp)
              file.copy(app_dir_val, file.path(tmp, "app.R"))
              tmp
            } else {
              app_dir_val
            }

            http_port <- otel_http_port()

            otel_vars <- c(
              OTEL_SERVICE_NAME = svc_name,
              OTEL_EXPORTER_OTLP_ENDPOINT = paste0(
                "http://localhost:", http_port
              ),
              OTEL_TRACES_EXPORTER = "otlp",
              OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
            )

            # Launch shinytest2::AppDriver in a background Rscript.
            # The Rscript gets its own event loop so chromote works.
            # It prints the app URL to stdout for the main process.
            driver_proc <- tryCatch(
              launch_app_driver_bg(resolved_dir, svc_name, otel_vars),
              error = function(e) {
                showNotification(
                  paste("Launch error:", e$message),
                  type = "error",
                  duration = 10
                )
                NULL
              }
            )

            if (is.null(driver_proc)) return()

            r_process(driver_proc)
            r_svc_name(svc_name)

            showNotification(
              sprintf("Starting %s...", svc_name),
              type = "message",
              duration = 3
            )
          })

          # ── Non-blocking poll for app URL from AppDriver stdout ──
          observe({
            proc <- r_process()
            if (is.null(proc)) return()
            # Already got the URL
            if (!is.null(r_app_url())) return()

            out <- tryCatch(
              proc$read_output_lines(),
              error = function(e) character(0)
            )
            url_line <- grep("^APP_URL:", out, value = TRUE)

            if (length(url_line) > 0) {
              app_url <- sub("^APP_URL:", "", url_line[1])
              r_app_url(app_url)
              r_result(data.frame(
                app_url = app_url,
                name = r_svc_name(),
                stringsAsFactors = FALSE
              ))
              showNotification(
                sprintf("Started %s at %s", r_svc_name(), app_url),
                type = "message",
                duration = 3
              )
              return()
            }

            if (!proc$is_alive()) {
              err <- tryCatch(
                proc$read_all_error(),
                error = function(e) ""
              )
              showNotification(
                paste0("AppDriver died: ", substr(err, 1, 500)),
                type = "error",
                duration = 15
              )
              r_process(NULL)
              return()
            }

            # Not ready yet — check again in 500ms
            invalidateLater(500)
          })

          # ── Show process log on demand ─────────────────────────
          observeEvent(input$log, {
            proc <- r_process()
            if (is.null(proc)) {
              showNotification("No process running.", type = "warning")
              return()
            }
            err <- tryCatch(proc$read_error(), error = function(e) "")
            out <- tryCatch(proc$read_output(), error = function(e) "")
            alive <- tryCatch(proc$is_alive(), error = function(e) FALSE)
            parts <- sprintf("=== AppDriver (alive: %s) ===", alive)
            if (nchar(err) > 0) parts <- c(parts, paste0("STDERR:\n", err))
            if (nchar(out) > 0) parts <- c(parts, paste0("STDOUT:\n", out))
            msg <- paste(parts, collapse = "\n")
            showNotification(
              tags$pre(
                style = "white-space: pre-wrap; max-height: 400px; overflow: auto;",
                msg
              ),
              type = "message",
              duration = 30
            )
          })

          # ── Monitor process health ───────────────────────────────
          observe({
            proc <- r_process()
            if (is.null(proc)) return()
            invalidateLater(2000)
            if (!proc$is_alive()) {
              stderr_out <- tryCatch(
                proc$read_all_error(),
                error = function(e) ""
              )
              showNotification(
                paste0(
                  "AppDriver exited. ",
                  if (nchar(stderr_out) > 0)
                    paste0("stderr:\n", substr(stderr_out, 1, 500))
                  else
                    "No stderr output."
                ),
                type = "error",
                duration = 15
              )
              r_process(NULL)
              r_app_url(NULL)
              r_result(data.frame(
                app_url = NA_character_,
                name = name %||% "",
                stringsAsFactors = FALSE
              ))
            }
          })

          # ── Stop app ───────────────────────────────────────────────
          observeEvent(input$stop, {
            stop_app_driver(r_process)
            r_process(NULL)
            r_app_url(NULL)
            r_result(data.frame(
              app_url = NA_character_,
              name = name %||% "",
              stringsAsFactors = FALSE
            ))
          })

          # ── Cleanup on session end ─────────────────────────────────
          session$onSessionEnded(function() {
            stop_app_driver(r_process)
          })

          list(
            expr = reactive(
              bquote(identity(.(df)), list(df = r_result()))
            ),
            state = list(
              app_dir = r_app_dir,
              name = name
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
          tags$h4("App Driver"),
          textInput(
            inputId = ns("app_dir"),
            label = "App directory",
            value = app_dir,
            width = "100%",
            placeholder = "/path/to/app"
          ),
          div(
            class = "d-flex gap-2",
            style = "margin-bottom: 10px;",
            actionButton(
              ns("start"),
              "Start App",
              icon = icon("play"),
              class = "btn-primary btn-sm"
            ),
            actionButton(
              ns("stop"),
              "Stop App",
              icon = icon("stop"),
              class = "btn-danger btn-sm"
            ),
            actionButton(
              ns("log"),
              "Log",
              icon = icon("terminal"),
              class = "btn-secondary btn-sm"
            )
          )
        )
      )
    },
    allow_empty_state = TRUE,
    class = "app_driver_block",
    ...
  )
}

#' Launch shinytest2::AppDriver in a background Rscript
#'
#' Writes a temp R script that creates an AppDriver with OTEL env vars,
#' prints the app URL to stdout, then keeps the process alive.
#' Runs in its own Rscript process so chromote has its own event loop.
#'
#' @param app_dir Resolved app directory path
#' @param name Service name for the AppDriver
#' @param otel_vars Named character vector of OTEL env vars
#' @return A processx::process object
#' @noRd
launch_app_driver_bg <- function(app_dir, name, otel_vars) {
  lib_paths <- paste(deparse(.libPaths()), collapse = "")
  chrome_bin <- chromote::find_chrome()

  # Serialize OTEL env vars as R code
  otel_code <- paste0(
    "Sys.setenv(",
    paste(
      sprintf('"%s" = "%s"', names(otel_vars), unname(otel_vars)),
      collapse = ", "
    ),
    ")"
  )

  script <- tempfile(pattern = "appdriver_", fileext = ".R")
  writeLines(c(
    sprintf(".libPaths(%s)", lib_paths),
    sprintf("Sys.setenv(CHROMOTE_CHROME = '%s')", chrome_bin),
    "Sys.setenv(NOT_CRAN = 'true')",
    otel_code,
    "",
    "message('[appdriver] Creating AppDriver...')",
    sprintf(
      "app <- shinytest2::AppDriver$new(app_dir = '%s', name = '%s')",
      app_dir, name
    ),
    "message('[appdriver] AppDriver ready')",
    "",
    "# Print app URL to stdout so the main process can read it",
    "cat(paste0('APP_URL:', app$get_url()), '\\n')",
    "",
    "# Keep alive — AppDriver manages both app + Chrome",
    "while (TRUE) Sys.sleep(1)"
  ), script)

  processx::process$new(
    command = file.path(R.home("bin"), "Rscript"),
    args = script,
    stdout = "|",
    stderr = "|",
    cleanup = FALSE
  )
}

#' Stop the AppDriver background process
#' @noRd
stop_app_driver <- function(r_process) {
  proc <- isolate(r_process())
  if (!is.null(proc) && proc$is_alive()) {
    proc$kill()
  }
}
