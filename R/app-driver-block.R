#' App Driver Block
#'
#' A data block that starts a Shiny app via [shinytest2::AppDriver] in a
#' background Rscript process. The AppDriver handles both launching the app
#' and connecting a headless Chrome session, triggering Shiny session
#' creation and OTEL span generation.
#'
#' Uses [ExtendedTask] + [mirai::mirai()] so the start button shows a
#' loading indicator while the AppDriver boots up. The mirai worker
#' launches the Rscript, polls its stdout for the app URL, and returns
#' the URL + PID. The main process stores the PID for stop/cleanup.
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
          r_pid <- reactiveVal(NULL)
          r_log_file <- reactiveVal(NULL)
          r_svc_name <- reactiveVal(name %||% "")
          r_result <- reactiveVal(
            data.frame(
              app_url = NA_character_,
              name = name %||% "",
              stringsAsFactors = FALSE
            )
          )

          observeEvent(input$app_dir, r_app_dir(trimws(input$app_dir)))

          # ── Initial button states ─────────────────────────────────
          shinyjs::disable("stop")
          shinyjs::disable("log")

          # ── ExtendedTask: launch Rscript + poll stdout for URL ────
          start_task <- ExtendedTask$new(function(
            rscript_bin, script_path, log_file
          ) {
            m <- mirai::mirai(
              {
                # Launch the Rscript with stdout piped, stderr to log file
                proc <- processx::process$new(
                  command = rscript_bin,
                  args = script_path,
                  stdout = "|",
                  stderr = log_file,
                  cleanup = FALSE
                )

                pid <- proc$get_pid()

                # Poll stdout for APP_URL: line (up to 60s)
                for (i in seq_len(120)) {
                  out <- tryCatch(
                    proc$read_output_lines(),
                    error = function(e) character(0)
                  )
                  url_line <- grep("^APP_URL:", out, value = TRUE)

                  if (length(url_line) > 0) {
                    app_url <- sub("^APP_URL:", "", url_line[1])
                    return(list(url = app_url, pid = pid))
                  }

                  if (!proc$is_alive()) {
                    err <- tryCatch(
                      readLines(log_file, warn = FALSE),
                      error = function(e) ""
                    )
                    stop(
                      "AppDriver died: ",
                      paste(tail(err, 20), collapse = "\n")
                    )
                  }

                  Sys.sleep(0.5)
                }

                # Timed out — kill and report
                try(proc$kill(), silent = TRUE)
                stop("AppDriver did not start within 60 seconds.")
              },
              rscript_bin = rscript_bin,
              script_path = script_path,
              log_file = log_file
            )
            promises::as.promise(m)
          })

          bslib::bind_task_button(start_task, "start")

          # ── Start app (on button click) ───────────────────────────
          observe({
            kill_app_driver(r_pid)
            r_pid(NULL)

            app_dir_val <- r_app_dir()
            if (nchar(app_dir_val) == 0) {
              showNotification(
                "Please enter an app directory.",
                type = "warning"
              )
              return()
            }

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

            # Prepare Rscript and log file
            script_path <- build_app_driver_script(
              resolved_dir, svc_name, otel_vars
            )
            log_file <- tempfile(
              pattern = paste0("appdriver_log_", svc_name, "_"),
              fileext = ".log"
            )
            r_log_file(log_file)
            r_svc_name(svc_name)

            # Invoke mirai — it launches the Rscript + polls for URL
            start_task$invoke(
              rscript_bin = file.path(R.home("bin"), "Rscript"),
              script_path = script_path,
              log_file = log_file
            )
          }) |>
            bindEvent(input$start)

          # ── Handle task result ────────────────────────────────────
          observe({
            result <- start_task$result()
            r_pid(result$pid)
            r_result(data.frame(
              app_url = result$url,
              name = r_svc_name(),
              stringsAsFactors = FALSE
            ))
            # App is running — enable stop/log, disable start
            shinyjs::enable("stop")
            shinyjs::enable("log")
            shinyjs::disable("start")
            showNotification(
              sprintf("Started %s at %s", r_svc_name(), result$url),
              type = "message",
              duration = 3
            )
          })

          # ── Show process log on demand ─────────────────────────
          observeEvent(input$log, {
            log_file <- r_log_file()
            pid <- r_pid()
            log_lines <- tryCatch(
              readLines(log_file, warn = FALSE),
              error = function(e) character(0)
            )
            alive <- !is.null(pid) && pid_is_alive(pid)
            header <- sprintf("=== AppDriver (alive: %s) ===", alive)
            msg <- paste(
              c(header, tail(log_lines, 50)),
              collapse = "\n"
            )
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
            pid <- r_pid()
            if (is.null(pid)) return()
            invalidateLater(2000)
            if (!pid_is_alive(pid)) {
              log_file <- r_log_file()
              stderr_out <- if (
                !is.null(log_file) && file.exists(log_file)
              ) {
                paste(
                  tail(readLines(log_file, warn = FALSE), 20),
                  collapse = "\n"
                )
              } else {
                ""
              }
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
              r_pid(NULL)
              r_result(data.frame(
                app_url = NA_character_,
                name = name %||% "",
                stringsAsFactors = FALSE
              ))
              # Process died — re-enable start, disable stop/log
              shinyjs::enable("start")
              shinyjs::disable("stop")
              shinyjs::disable("log")
            }
          })

          # ── Stop app ───────────────────────────────────────────────
          observeEvent(input$stop, {
            kill_app_driver(r_pid)
            r_pid(NULL)
            r_result(data.frame(
              app_url = NA_character_,
              name = name %||% "",
              stringsAsFactors = FALSE
            ))
            # App stopped — re-enable start, disable stop/log
            shinyjs::enable("start")
            shinyjs::disable("stop")
            shinyjs::disable("log")
          })

          # ── Cleanup on session end ─────────────────────────────────
          session$onSessionEnded(function() {
            kill_app_driver(r_pid)
          })

          list(
            expr = reactive({
              df <- r_result()
              if (is.na(df$app_url[1])) {
                stop("No app running. Click Start to launch.")
              }
              bquote(identity(.(df)), list(df = df))
            }),
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
        shinyjs::useShinyjs(),
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
            bslib::input_task_button(
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

#' Build the R script for the AppDriver background process
#'
#' Creates a temp R script that sets up OTEL env vars, creates a
#' [shinytest2::AppDriver], prints the app URL to stdout, and keeps alive.
#'
#' @param app_dir Resolved app directory path
#' @param name Service name for the AppDriver
#' @param otel_vars Named character vector of OTEL env vars
#' @return Path to the temp R script
#' @noRd
build_app_driver_script <- function(app_dir, name, otel_vars) {
  lib_paths <- paste(deparse(.libPaths()), collapse = "")
  chrome_bin <- chromote::find_chrome()

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
    "# Print app URL to stdout so the polling process can read it",
    "cat(paste0('APP_URL:', app$get_url()), '\\n')",
    "",
    "# Keep alive — AppDriver manages both app + Chrome",
    "while (TRUE) Sys.sleep(1)"
  ), script)

  script
}

#' Check if a process with given PID is alive
#' @noRd
pid_is_alive <- function(pid) {
  tryCatch(
    {
      # signal 0 checks existence without killing
      tools::pskill(pid, signal = 0L)
      TRUE
    },
    error = function(e) FALSE
  )
}

#' Kill the AppDriver process by PID
#' @noRd
kill_app_driver <- function(r_pid) {
  pid <- isolate(r_pid())
  if (!is.null(pid) && pid_is_alive(pid)) {
    try(tools::pskill(pid), silent = TRUE)
  }
}
