#' App Driver Block
#'
#' A data block that starts a Shiny app via [shinytest2::AppDriver] in a
#' background Rscript process. The AppDriver handles both launching the app
#' and connecting a headless Chrome session, triggering Shiny session
#' creation and OTEL span generation.
#'
#' When `app_dir` is a URL (`http://` or `https://`), the block connects
#' to the already-running app without launching a new process. In that
#' case, OTEL must be configured on the remote app separately.
#'
#' Uses [ExtendedTask] + [mirai::mirai()] so the start button shows a
#' loading indicator while the AppDriver boots up. The mirai worker
#' launches the Rscript, polls its stdout for the app URL, and returns
#' the URL + PID. The main process stores the PID for stop/cleanup.
#'
#' @param app_dir Path to a Shiny app directory, single-file app, or URL
#'   of a running Shiny app.
#' @param name Optional service name for OTEL. Defaults to the app
#'   directory basename.
#' @param timeout Timeout in seconds for the Shiny app to start.
#'   Passed as `load_timeout` (in ms) to [shinytest2::AppDriver].
#'   Defaults to 15. Ignored when `app_dir` is a URL.
#' @param ... Forwarded to [blockr.core::new_data_block()]
#'
#' @return A block object of class `app_driver_block`.
#' @export
new_app_driver_block <- function(
  app_dir = "",
  name = NULL,
  timeout = 15,
  ...
) {
  blockr.core::new_data_block(
    server = function(id) {
      moduleServer(
        id,
        function(input, output, session) {
          ns <- session$ns

          r_app_dir <- reactiveVal(app_dir)
          r_timeout <- reactiveVal(timeout)
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
          observeEvent(input$timeout, r_timeout(input$timeout))

          # -- Initial button states ----------------------------------
          shinyjs::disable("stop")
          shinyjs::disable("log")

          # -- ExtendedTask: launch Rscript + poll stdout for URL ------
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

                # Poll stdout for APP_URL: line
                # Allow enough time for AppDriver load_timeout + overhead
                poll_secs <- timeout + 30
                n_polls <- ceiling(poll_secs / 0.5)
                for (i in seq_len(n_polls)) {
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

                # Timed out
                try(proc$kill(), silent = TRUE)
                stop(sprintf(
                  "AppDriver did not start within %d seconds.", poll_secs
                ))
              },
              rscript_bin = rscript_bin,
              script_path = script_path,
              log_file = log_file,
              timeout = timeout
            )
            promises::as.promise(m)
          })

          # -- ExtendedTask: connect to a URL --------------------------
          connect_task <- ExtendedTask$new(function(app_url) {
            m <- mirai::mirai(
              {
                list(url = app_url, pid = NULL)
              },
              app_url = app_url
            )
            promises::as.promise(m)
          })

          bslib::bind_task_button(start_task, "start")
          bslib::bind_task_button(connect_task, "start")

          # -- Start/connect app (on button click) ---------------------
          observe({
            kill_app_driver(r_pid)
            r_pid(NULL)

            app_dir_val <- r_app_dir()
            if (nchar(app_dir_val) == 0) {
              showNotification(
                "Please enter an app directory or URL.",
                type = "warning"
              )
              return()
            }

            is_url <- grepl("^https?://", app_dir_val)

            svc_name <- name %||% if (is_url) {
              sub("^https?://", "", app_dir_val)
            } else {
              tools::file_path_sans_ext(basename(app_dir_val))
            }

            r_svc_name(svc_name)

            if (is_url) {
              # Connect to an already-running app
              connect_task$invoke(app_url = app_dir_val)
            } else {
              # Handle single-file apps
              resolved_dir <- if (
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
              timeout_val <- r_timeout()
              script_path <- build_app_driver_script(
                resolved_dir, svc_name, otel_vars, timeout_val
              )
              log_file <- tempfile(
                pattern = paste0("appdriver_log_", svc_name, "_"),
                fileext = ".log"
              )
              r_log_file(log_file)

              # Invoke mirai: launches the Rscript + polls for URL
              start_task$invoke(
                rscript_bin = file.path(R.home("bin"), "Rscript"),
                script_path = script_path,
                log_file = log_file
              )
            }
          }) |>
            bindEvent(input$start)

          # -- Handle task result (local launch) -----------------------
          observe({
            result <- start_task$result()
            on_app_started(result, r_pid, r_result, r_svc_name, session)
          })

          # -- Handle task result (URL connect) ------------------------
          observe({
            result <- connect_task$result()
            on_app_started(result, r_pid, r_result, r_svc_name, session)
          })

          # -- Show process log on demand ----------------------------
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

          # -- Monitor process health ---------------------------------
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
              # Process died: re-enable start, disable stop/log
              shinyjs::enable("start")
              shinyjs::disable("stop")
              shinyjs::disable("log")
            }
          })

          # -- Stop app ------------------------------------------------
          observeEvent(input$stop, {
            kill_app_driver(r_pid)
            r_pid(NULL)
            r_result(data.frame(
              app_url = NA_character_,
              name = name %||% "",
              stringsAsFactors = FALSE
            ))
            # App stopped: re-enable start, disable stop/log
            shinyjs::enable("start")
            shinyjs::disable("stop")
            shinyjs::disable("log")
          })

          # -- Cleanup on session end ----------------------------------
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
              name = name,
              timeout = r_timeout
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
          tags$h4(icon("rocket"), " App Driver"),
          textInput(
            inputId = ns("app_dir"),
            label = "App directory or URL",
            value = app_dir,
            width = "100%",
            placeholder = "/path/to/app or http://host:port"
          ),
          numericInput(
            inputId = ns("timeout"),
            label = "Timeout (s)",
            value = timeout,
            min = 5,
            step = 5,
            width = "100%"
          ),
          div(
            class = "btn-toolbar",
            role = "toolbar",
            style = "margin-bottom: 10px;",
            div(
              class = "btn-group btn-group-sm me-2",
              role = "group",
              bslib::input_task_button(
                ns("start"),
                label = tagList(icon("play"), "Start"),
                class = "btn-success btn-sm"
              ),
              actionButton(
                ns("stop"),
                label = tagList(icon("stop"), "Stop"),
                class = "btn-danger btn-sm"
              )
            ),
            div(
              class = "btn-group btn-group-sm",
              role = "group",
              actionButton(
                ns("log"),
                label = tagList(icon("terminal"), "Log"),
                class = "btn-secondary btn-sm"
              )
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

#' Handle successful app start/connect
#' @noRd
on_app_started <- function(result, r_pid, r_result, r_svc_name, session) {
  r_pid(result$pid)
  r_result(data.frame(
    app_url = result$url,
    name = r_svc_name(),
    stringsAsFactors = FALSE
  ))
  shinyjs::enable("stop")
  shinyjs::enable("log")
  shinyjs::disable("start")
  showNotification(
    sprintf("Connected to %s at %s", r_svc_name(), result$url),
    type = "message",
    duration = 3
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
#' @param timeout Timeout in seconds for AppDriver to load the app
#' @return Path to the temp R script
#' @noRd
build_app_driver_script <- function(app_dir, name, otel_vars, timeout = 15) {
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
      "app <- shinytest2::AppDriver$new(app_dir = '%s', name = '%s', load_timeout = %d)",
      app_dir, name, timeout * 1000L
    ),
    "message('[appdriver] AppDriver ready')",
    "",
    "# Print app URL to stdout so the polling process can read it",
    "cat(paste0('APP_URL:', app$get_url()), '\\n')",
    "",
    "# Keep alive: AppDriver manages both app + Chrome",
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
