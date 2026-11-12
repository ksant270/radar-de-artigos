# Teste rápido da conexão com o Gemini (leva no máximo 2 minutos).
# Como rodar, no console do R, com a pasta do radar como diretório:
#   source("teste_conexao.R")

readRenviron("chave_api.txt")
chave <- Sys.getenv("GEMINI_API_KEY")
base <- "https://generativelanguage.googleapis.com/v1beta/"

pedir <- function(req, limite) {
  inicio <- Sys.time()
  res <- tryCatch(
    req |>
      httr2::req_headers("x-goog-api-key" = chave) |>
      httr2::req_timeout(limite) |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_perform(),
    error = function(e) e
  )
  list(res = res, segundos = round(as.numeric(difftime(Sys.time(), inicio, units = "secs")), 1))
}

mostrar <- function(p, se_ok) {
  if (inherits(p$res, "error")) {
    cat("   FALHOU em", p$segundos, "s:", conditionMessage(p$res), "\n")
  } else if (httr2::resp_status(p$res) != 200) {
    cat("   ERRO", httr2::resp_status(p$res), "em", p$segundos, "s:",
        httr2::resp_body_json(p$res)$error$message, "\n")
  } else {
    se_ok(httr2::resp_body_json(p$res), p$segundos)
  }
}

cat("\n1. Conexão com o Google e modelos da sua chave\n")
flash <- character(0)
mostrar(pedir(httr2::request(paste0(base, "models?pageSize=200")), 20), function(corpo, s) {
  modelos <- sub("^models/", "", vapply(corpo$models, function(m) m$name, ""))
  flash <<- grep("flash", modelos, value = TRUE)
  cat("   OK em", s, "s. Modelos flash:", paste(flash, collapse = ", "), "\n")
})

testar <- function(modelo) {
  cat("\n2. Resposta curta do modelo", modelo, "\n")
  corpo <- list(contents = list(list(parts = list(list(text = "Responda apenas: ok")))))
  req <- httr2::req_body_json(
    httr2::request(paste0(base, "models/", modelo, ":generateContent")), corpo)
  mostrar(pedir(req, 45), function(corpo, s) {
    cat("   OK em", s, "s. Resposta:", corpo$candidates[[1]]$content$parts[[1]]$text, "\n")
  })
}

testar("gemini-3.8-flash")
outros <- setdiff(grep("^gemini-[0-9.]+-flash$", flash, value = TRUE), "gemini-3.8-flash")
if (length(outros) > 0) testar(outros[1])

cat("\nCopia tudo que apareceu acima e cola no chat.\n")
