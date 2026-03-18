#' App Driver Block
#'
#' A data block that starts a Shiny app via [shinytest2::AppDriver] with
#' OpenTelemetry instrumentation. The app runs in the main R process
#' (chromote requirement) and emits OTLP traces to the configured endpoint.
#'
#' @param app_dir Path to a Shiny app directory, file, URL, or app object.
#'   See [shinytest2::AppDriver] for details.
#' @param name Optional name for the AppDriver instance
#' @param load_timeout Maximum time to wait for the app to load (ms)
#' @param timeout Default timeout for AppDriver operations (ms)
#' @param height Browser window height in pixels
#' @param width Browser window width in pixels
#' @param shiny_args List of arguments passed to [shiny::runApp()]
#' @param ... Forwarded to [blockr.core::new_data_block()]
#'
#' @return A block object of class `app_driver_block`.
#' @export
new_app_driver_block <- function(
  app_dir = "",
  name = NULL,
  load_timeout = 15000L,
  timeout = 4000L,
  height = 400L,
  width = 800L,
  shiny_args = list(),
  ...
) {
  blockr.core::new_data_block(
    server = function(id) {
      moduleServer(
        id,
        function(input, output, session) {
          ns <- session$ns

          r_app_dir <- reactiveVal(app_dir)
          r_driver <- reactiveVal(NULL)
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
            # Stop existing driver if any
            drv <- r_driver()
            if (!is.null(drv)) {
              try(drv$stop(), silent = TRUE)
              r_driver(NULL)
            }

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

            drv <- withr::with_envvar(
              c(
                OTEL_SERVICE_NAME = svc_name,
                OTEL_EXPORTER_OTLP_ENDPOINT = paste0(
                  "http://localhost:", http_port
                ),
                OTEL_TRACES_EXPORTER = "otlp",
                OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
              ),
              shinytest2::AppDriver$new(
                app_dir = resolved_dir,
                name = svc_name,
                load_timeout = load_timeout,
                timeout = timeout,
                height = height,
                width = width,
                shiny_args = shiny_args
              )
            )

            r_driver(drv)
            r_result(data.frame(
              app_url = drv$get_url(),
              name = svc_name,
              stringsAsFactors = FALSE
            ))
          })

          # ── Stop app ───────────────────────────────────────────────
          observeEvent(input$stop, {
            drv <- r_driver()
            if (!is.null(drv)) {
              try(drv$stop(), silent = TRUE)
              r_driver(NULL)
              r_result(data.frame(
                app_url = NA_character_,
                name = name %||% "",
                stringsAsFactors = FALSE
              ))
            }
          })

          # ── Cleanup on session end ─────────────────────────────────
          session$onSessionEnded(function() {
            drv <- isolate(r_driver())
            if (!is.null(drv)) {
              try(drv$stop(), silent = TRUE)
            }
          })

          list(
            expr = reactive(
              bquote(identity(.(df)), list(df = r_result()))
            ),
            state = list(
              app_dir = r_app_dir,
              name = name,
              load_timeout = load_timeout,
              timeout = timeout,
              height = height,
              width = width,
              shiny_args = shiny_args
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
