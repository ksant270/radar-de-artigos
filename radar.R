# Radar de artigos
# Busca no PubMed os artigos novos dos temas definidos em temas.R, resume cada
# um com IA (Gemini), gera um resumo da semana em HTML e manda por e-mail pra
# quem assinou, cada pessoa só com os temas que escolheu.
#
# Como rodar, no console do R:
#   setwd("~/Desktop/radar-de-artigos")
#   source("radar.R")


# 1. Configuração --------------------------------------------------------------

pacotes <- c("rentrez", "xml2", "httr2", "jsonlite", "commonmark")
faltando <- setdiff(pacotes, rownames(installed.packages()))
if (length(faltando) > 0) install.packages(faltando)

library(rentrez)
library(xml2)

source("temas.R")

dias <- 7           # busca artigos que entraram no PubMed nos últimos N dias
max_por_tema <- 20  # no máximo N artigos por tema
nota_destaque <- 4  # a partir dessa nota, o artigo aparece com resumo

# Modelos do Gemini em ordem de preferência. Se um estiver sobrecarregado ou
# indisponível, o radar tenta o próximo da lista.
modelos <- c("gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.8-flash", "gemini-3.7-flash",
             "gemini-flash-lite-latest", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite")
espera_modelo <- 90  # segundos que cada modelo tem pra responder
modelos_usados <- character(0)     # quem funcionou é o primeiro a ser chamado no tema seguinte
modelos_com_falha <- character(0)  # quem falhou vai pro fim da fila
modelos_sem_cota <- character(0)   # quem estourou a cota do dia fica de fora até o fim

# Se a IA não responder dentro desse tempo, o resumo sai mesmo assim, só com
# títulos e links nos temas que ficaram sem resumo.
limite_ia_minutos <- 12
inicio <- Sys.time()
ia_indisponivel <- FALSE
chave_recusada <- FALSE
temas_sem_ia <- character(0)
temas_sem_pubmed <- character(0)
ultimo_erro_ia <- ""

# No GitHub Actions, avisos que aparecem na página da execução sem precisar de login
no_github <- Sys.getenv("GITHUB_ACTIONS") == "true"
aviso_github <- function(tipo, texto) if (no_github) cat("::", tipo, "::", texto, "\n", sep = "")

# Chave da API, e-mail e assinantes ficam em chave_api.txt, que nunca vai pro
# GitHub. No GitHub Actions, eles vêm dos "secrets" do repositório.
if (file.exists("chave_api.txt")) readRenviron("chave_api.txt")
# Tira espaços e quebras de linha que às vezes vêm junto quando a chave é colada
Sys.setenv(GEMINI_API_KEY = gsub("\\s", "", Sys.getenv("GEMINI_API_KEY")),
           GMAIL_USUARIO = trimws(Sys.getenv("GMAIL_USUARIO")))
if (Sys.getenv("GEMINI_API_KEY") %in% c("", "cole_sua_chave_aqui")) {
  aviso_github("error", "Falta a chave do Gemini (secret GEMINI_API_KEY).")
  stop("Coloque sua chave do Gemini no arquivo chave_api.txt (GEMINI_API_KEY=sua_chave).")
}


# 2. Busca no PubMed -----------------------------------------------------------

# Sem chave, o PubMed aceita até 3 pedidos por segundo por endereço de internet,
# e os computadores do GitHub são compartilhados. Com a chave gratuita do NCBI
# (secret NCBI_API_KEY, opcional), o limite sobe pra 10.
if (nzchar(Sys.getenv("NCBI_API_KEY"))) set_entrez_key(Sys.getenv("NCBI_API_KEY"))

# Faz um pedido ao PubMed com pausa depois e até 4 tentativas, porque o limite
# de pedidos às vezes estoura sem culpa nossa.
pedir_pubmed <- function(f, ...) {
  for (tentativa in 1:4) {
    resultado <- tryCatch(f(...), error = function(e) e)
    if (!inherits(resultado, "error")) {
      Sys.sleep(0.4)
      return(resultado)
    }
    message("  O PubMed não respondeu (tentativa ", tentativa, " de 4): ",
            gsub("\\s+", " ", conditionMessage(resultado)))
    Sys.sleep(5 * tentativa)
  }
  stop(resultado)
}

buscar_pubmed <- function(consulta) {
  # Tira avisos de retratação e errata, que não são artigos novos
  consulta <- paste0("(", consulta, ") NOT (\"retraction notice\"[Publication Type]",
                     " OR \"published erratum\"[Publication Type])")
  busca <- pedir_pubmed(entrez_search, db = "pubmed", term = consulta, datetype = "edat",
                        reldate = dias, retmax = max_por_tema)
  if (length(busca$ids) == 0) return(NULL)

  xml <- read_xml(pedir_pubmed(entrez_fetch, db = "pubmed", id = busca$ids,
                               rettype = "xml", parsed = FALSE))
  artigos <- xml_find_all(xml, ".//PubmedArticle")

  data.frame(
    pmid     = xml_text(xml_find_first(artigos, "./MedlineCitation/PMID")),
    titulo   = xml_text(xml_find_first(artigos, ".//ArticleTitle")),
    revista  = xml_text(xml_find_first(artigos, ".//Journal/Title")),
    abstract = vapply(artigos, function(a) {
      paste(xml_text(xml_find_all(a, ".//Abstract/AbstractText")), collapse = " ")
    }, character(1)),
    stringsAsFactors = FALSE
  )
}


# 3. Resumo com IA -------------------------------------------------------------

if (!exists("interesses_por_tema")) interesses_por_tema <- list()

# Cada tema pode ter o próprio perfil de interesse (interesses_por_tema, em
# temas.R). Se não tiver, vale o perfil geral do grupo.
montar_instrucoes <- function(tema) {
  interesse <- interesses_por_tema[[tema]]
  if (is.null(interesse)) interesse <- interesses_do_grupo
  paste(
    "Você ajuda pesquisadores a acompanhar a literatura científica.",
    paste0("Quem vai ler estuda ", interesse, "."),
    "Para cada artigo recebido: resuma em português, em no máximo 2 frases,",
    "o que o estudo fez e o principal achado; dê uma nota de relevância de 1 a 5",
    "para quem vai ler (5 = muito relevante); e explique a nota em uma frase curta.",
    "Use apenas o título e o abstract fornecidos: não invente resultados, números",
    "ou métodos que não estejam no texto. Se o abstract estiver vazio, escreva",
    "'Sem abstract disponível.' e dê nota 1."
  )
}

# Formato que o Gemini é obrigado a seguir na resposta: uma lista com PMID,
# resumo, nota e motivo de cada artigo. Assim o código consegue ordenar e
# filtrar, sem depender de texto livre.
formato <- list(
  type = "array",
  items = list(
    type = "object",
    properties = list(
      pmid       = list(type = "string",  description = "PMID do artigo, exatamente como recebido"),
      resumo     = list(type = "string",  description = "Resumo em português, em no máximo 2 frases"),
      relevancia = list(type = "integer", description = "Nota de relevância para o grupo, de 1 a 5"),
      motivo     = list(type = "string",  description = "Por que essa nota, em uma frase curta")
    ),
    required = list("pmid", "resumo", "relevancia", "motivo")
  )
)

# Uma chamada à API do Gemini. Se o modelo der erro ou não responder a tempo,
# a função para com a mensagem do Google, e o radar tenta o próximo modelo.
perguntar_gemini <- function(modelo, instrucoes, pedido) {
  resposta <- httr2::request("https://generativelanguage.googleapis.com/v1beta/models") |>
    httr2::req_url_path_append(paste0(modelo, ":generateContent")) |>
    httr2::req_headers("x-goog-api-key" = Sys.getenv("GEMINI_API_KEY")) |>
    httr2::req_body_json(list(
      systemInstruction = list(parts = list(list(text = instrucoes))),
      contents = list(list(role = "user", parts = list(list(text = pedido)))),
      generationConfig = list(temperature = 0.2, maxOutputTokens = 16384,
                              responseMimeType = "application/json",
                              responseSchema = formato)
    )) |>
    httr2::req_timeout(espera_modelo) |>
    httr2::req_error(body = function(resp) {
      tryCatch(httr2::resp_body_json(resp)$error$message, error = function(e) NULL)
    }) |>
    httr2::req_perform()

  partes <- httr2::resp_body_json(resposta)$candidates[[1]]$content$parts
  texto <- paste(vapply(partes, function(p) {
    if (is.null(p$text) || isTRUE(p$thought)) "" else p$text
  }, character(1)), collapse = "")
  tabela <- jsonlite::fromJSON(texto)
  if (!is.data.frame(tabela) || nrow(tabela) == 0 ||
      !all(names(formato$items$properties) %in% names(tabela))) {
    stop("o modelo devolveu uma resposta vazia ou incompleta")
  }
  tabela
}

tempo_esgotado <- function() {
  as.numeric(difftime(Sys.time(), inicio, units = "mins")) > limite_ia_minutos
}

# Traduz os erros mais comuns do Google numa frase curta pro log
explicar_erro <- function(erro) {
  if (grepl("per day|PerDay", erro, ignore.case = TRUE)) return("cota do dia do plano gratuito esgotada (429)")
  if (grepl("HTTP 429", erro)) return("limite de pedidos por minuto (429)")
  if (grepl("HTTP 503", erro)) return("modelo sobrecarregado (503)")
  if (grepl("Timeout was reached", erro)) return(paste0("não respondeu em ", espera_modelo, " segundos"))
  substr(erro, 1, 200)
}

# Manda todos os artigos de um tema numa chamada só (gasta menos do limite
# gratuito) e devolve uma tabela com resumo, nota e motivo de cada PMID.
# Se nenhum modelo responder, devolve NULL e o tema sai só com títulos e links.
resumir <- function(tema, artigos) {
  if (ia_indisponivel) return(NULL)
  texto <- paste0(
    "PMID: ", artigos$pmid, "\n",
    "Título: ", artigos$titulo, "\n",
    "Abstract: ", ifelse(nzchar(artigos$abstract), artigos$abstract, "(vazio)"),
    collapse = "\n\n---\n\n"
  )
  pedido <- paste0("Tema: ", tema, "\n\nArtigos:\n\n", texto)

  esperas <- c(60, 180)  # segundos de espera antes da 2ª e da 3ª rodada

  for (rodada in 1:3) {
    # Quem já funcionou vai primeiro e quem falhou vai pro fim da fila. Quem
    # estourou a cota do dia fica de fora, porque só volta no dia seguinte.
    fila <- unique(c(rev(modelos_usados), setdiff(modelos, modelos_com_falha), modelos_com_falha))
    fila <- setdiff(fila, modelos_sem_cota)
    for (modelo in fila) {
      if (tempo_esgotado()) break
      resposta <- tryCatch(perguntar_gemini(modelo, montar_instrucoes(tema), pedido),
        error = function(e) {
          erro <- gsub("\\s+", " ", conditionMessage(e))
          message("  ", modelo, " não respondeu: ", explicar_erro(erro))
          modelos_com_falha <<- unique(c(modelos_com_falha, modelo))
          ultimo_erro_ia <<- paste0(modelo, ": ", explicar_erro(erro))
          if (grepl("per day|PerDay", erro, ignore.case = TRUE)) {
            modelos_sem_cota <<- unique(c(modelos_sem_cota, modelo))
          }
          # Chave errada não melhora tentando outro modelo
          if (grepl("API key|API_KEY", erro, ignore.case = TRUE)) chave_recusada <<- TRUE
          NULL
        })
      if (chave_recusada) break
      if (!is.null(resposta)) {
        message("  Resumido com ", modelo)
        modelos_usados <<- unique(c(modelos_usados, modelo))
        resposta$pmid <- gsub("\\D", "", resposta$pmid)
        return(resposta[!duplicated(resposta$pmid), ])
      }
    }
    sem_cota_em_todos <- all(modelos %in% modelos_sem_cota)
    if (rodada == 3 || tempo_esgotado() || chave_recusada || sem_cota_em_todos) break
    message("Nenhum modelo respondeu. Tentando de novo em ", esperas[rodada], " segundos...")
    Sys.sleep(esperas[rodada])
  }
  if (chave_recusada) {
    message("O Google recusou a chave do Gemini: confira a GEMINI_API_KEY.")
    aviso_github("error", "O Google recusou a chave do Gemini: confira o secret GEMINI_API_KEY.")
  }
  message("A IA não respondeu: os temas que faltam vão só com títulos e links.")
  ia_indisponivel <<- TRUE
  NULL
}


# 4. Busca e resume cada tema --------------------------------------------------

resultados <- list()
vistos <- character(0)  # evita repetir um artigo que aparece em mais de um tema

for (tema in names(temas)) {
  message("Buscando: ", tema)
  artigos <- tryCatch(buscar_pubmed(temas[[tema]]), error = function(e) {
    message("  Não consegui buscar esse tema no PubMed: ", conditionMessage(e))
    temas_sem_pubmed <<- c(temas_sem_pubmed, tema)
    NULL
  })
  if (!is.null(artigos)) artigos <- artigos[!artigos$pmid %in% vistos, ]
  if (is.null(artigos) || nrow(artigos) == 0) next
  vistos <- c(vistos, artigos$pmid)

  message("Resumindo ", nrow(artigos), " artigo(s) com IA...")
  resumos <- resumir(tema, artigos)
  if (is.null(resumos)) {
    artigos$resumo <- NA_character_
    artigos$relevancia <- NA_integer_
    artigos$motivo <- NA_character_
    temas_sem_ia <- c(temas_sem_ia, tema)
  } else {
    artigos <- merge(artigos, resumos, by = "pmid", all.x = TRUE)
  }
  resultados[[tema]] <- artigos[order(-artigos$relevancia), ]
  Sys.sleep(5)  # pausa entre temas, por causa do limite do plano gratuito
}

if (length(temas_sem_pubmed) > 0) {
  aviso_github("warning", paste0("O PubMed não respondeu em: ",
                                 paste(temas_sem_pubmed, collapse = ", "), "."))
}
if (length(temas_sem_pubmed) == length(temas)) {
  # Melhor não mandar nada do que dizer que não saiu nenhum artigo novo
  aviso_github("error", "O PubMed não respondeu em nenhum tema: nenhum e-mail enviado.")
  stop("O PubMed não respondeu em nenhum tema. Tente de novo mais tarde.")
}


# 5. Monta o resumo em HTML ----------------------------------------------------

link <- function(pmid) paste0("https://pubmed.ncbi.nlm.nih.gov/", pmid, "/")
escapar <- function(x) gsub("([][*_`])", "\\\\\\1", x)  # evita quebrar o markdown
ia <- if (length(modelos_usados) > 0) paste0(" (", paste(modelos_usados, collapse = ", "), ")") else ""
estilo <- paste0(
  "body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:720px;",
  "margin:24px auto;padding:0 16px;line-height:1.5;color:#1f2328}",
  "h1{font-size:22px}h2{font-size:18px;border-bottom:1px solid #d0d7de;",
  "padding-bottom:4px;margin-top:32px}h3{font-size:15px;margin:22px 0 4px}",
  "p{margin:6px 0}a{color:#0969da}"
)

# Monta a página só com os temas escolhidos (todos, se ninguém disser nada).
# O rodapé com instruções aparece na versão que vai por e-mail.
montar_html <- function(escolhidos = names(temas), rodape = FALSE) {
  res <- resultados[intersect(escolhidos, names(resultados))]
  total <- sum(vapply(res, nrow, integer(1)))
  linhas <- c(
    paste0("# Radar de artigos — ", format(Sys.Date(), "%d/%m/%Y")),
    "",
    paste0(total, " artigo(s) novo(s) no PubMed nos últimos ", dias, " dias, nos temas: ",
           paste(escolhidos, collapse = ", "), ". Os resumos são feitos por IA", ia,
           " a partir do abstract; confira sempre o artigo original."),
    ""
  )
  sem_ia <- intersect(names(res), temas_sem_ia)
  if (length(sem_ia) > 0) {
    linhas <- c(linhas,
      paste0("*Nesta semana a IA não respondeu, então ", paste(sem_ia, collapse = ", "),
             " veio só com títulos e links.*"),
      "")
  }
  sem_pubmed <- intersect(escolhidos, temas_sem_pubmed)
  if (length(sem_pubmed) > 0) {
    linhas <- c(linhas,
      paste0("*O PubMed não respondeu na busca de ", paste(sem_pubmed, collapse = ", "),
             " nesta semana.*"),
      "")
  }

  for (tema in names(res)) {
    a <- res[[tema]]
    destaque <- a[!is.na(a$relevancia) & a$relevancia >= nota_destaque, ]
    outros   <- a[is.na(a$relevancia) | a$relevancia < nota_destaque, ]

    linhas <- c(linhas, paste0("## ", tema), "")
    for (i in seq_len(nrow(destaque))) {
      linhas <- c(linhas,
        paste0("### [", escapar(destaque$titulo[i]), "](", link(destaque$pmid[i]), ")"),
        "",
        paste0("*", escapar(destaque$revista[i]), "* · relevância ",
               destaque$relevancia[i], "/5"),
        "",
        destaque$resumo[i],
        "",
        paste0("**Por que importa:** ", destaque$motivo[i]),
        "")
    }
    if (nrow(outros) > 0) {
      linhas <- c(linhas,
        if (nrow(destaque) > 0) "**Outros artigos do tema:**" else "**Artigos do tema:**",
        "",
        paste0("- [", escapar(outros$titulo), "](", link(outros$pmid), ") — *",
               escapar(outros$revista), "*"),
        "")
    }
  }
  if (total == 0) linhas <- c(linhas, "Nenhum artigo novo nos seus temas nesta semana.")
  if (rodape) {
    linhas <- c(linhas, "", "---", "",
                "Pra mudar seus temas ou sair da lista, é só responder este e-mail.")
  }

  corpo <- commonmark::markdown_html(paste(linhas, collapse = "\n"))
  paste0('<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">',
         "<title>Radar de artigos</title><style>", estilo, "</style></head>",
         "<body>", corpo, "</body></html>")
}

dir.create("saidas", showWarnings = FALSE)
arquivo <- file.path("saidas", paste0("radar_", Sys.Date(), ".html"))
writeLines(montar_html(), arquivo, useBytes = TRUE)
message("Pronto! Resumo salvo em ", normalizePath(arquivo))
if (interactive()) browseURL(normalizePath(arquivo))


# 6. Envia por e-mail ----------------------------------------------------------
# Quem recebe e quais temas fica na variável ASSINANTES, separando as pessoas
# com ponto e vírgula. Exemplo:
#   ASSINANTES=ana@gmail.com: lncRNA, Microambiente imune; joao@gmail.com: todos

b64 <- function(x) jsonlite::base64_enc(charToRaw(enc2utf8(x)))

# Quem envia é o programa curl (o mesmo que vem no Mac, no Linux e no Windows),
# num processo separado. No GitHub, enviar de dentro do R derrubava a execução
# inteira; assim, se o envio falhar, o R continua e avisa o que aconteceu.
enviar_email <- function(para, assunto, html) {
  mensagem <- paste0(
    "From: Radar de artigos <", Sys.getenv("GMAIL_USUARIO"), ">\r\n",
    "To: ", para, "\r\n",
    "Subject: =?UTF-8?B?", b64(assunto), "?=\r\n",
    "MIME-Version: 1.0\r\n",
    "Content-Type: text/html; charset=UTF-8\r\n",
    "Content-Transfer-Encoding: base64\r\n\r\n",
    gsub("(.{76})", "\\1\r\n", b64(html)), "\r\n"
  )
  servidor <- Sys.getenv("SMTP_SERVIDOR", "smtps://smtp.gmail.com:465")
  arquivo <- tempfile(fileext = ".eml")
  credenciais <- tempfile()
  on.exit(unlink(c(arquivo, credenciais)))
  writeBin(charToRaw(mensagem), arquivo)
  # A senha vai num arquivo temporário só seu, e não na linha de comando
  writeLines(paste("machine", sub("^smtps?://([^:/]+).*$", "\\1", servidor),
                   "login", Sys.getenv("GMAIL_USUARIO"),
                   "password", gsub("\\s", "", Sys.getenv("GMAIL_SENHA_APP"))),  # o Google mostra a senha com espaços
             credenciais)
  Sys.chmod(credenciais, "0600")
  saida <- suppressWarnings(system2("curl", shQuote(c(
    "--silent", "--show-error", "--ssl-reqd", "--max-time", "60",
    "--url", servidor, "--netrc-file", credenciais,
    "--mail-from", Sys.getenv("GMAIL_USUARIO"), "--mail-rcpt", para, "--upload-file", arquivo
  )), stdout = TRUE, stderr = TRUE))
  status <- attr(saida, "status")
  if (!is.null(status) && status != 0) {
    stop(paste(c(saida, paste0("(código ", status, ")")), collapse = " "))
  }
}

ler_assinantes <- function(texto) {
  itens <- trimws(unlist(strsplit(texto, "[;\n]")))
  lapply(itens[nzchar(itens)], function(item) {
    partes <- strsplit(item, ":", fixed = TRUE)[[1]]
    pedidos <- if (length(partes) > 1) trimws(strsplit(partes[2], ",")[[1]]) else "todos"
    pedidos <- pedidos[nzchar(pedidos)]
    sem_tema <- setdiff(tolower(pedidos), c(tolower(names(temas)), "todos"))
    # Um e-mail no lugar de um tema quer dizer que faltou o ponto e vírgula.
    # O endereço nunca é mostrado, porque o log do GitHub é público.
    if (any(grepl("@", sem_tema))) {
      message("Parece que faltou um ponto e vírgula entre duas pessoas no ASSINANTES.")
      aviso_github("warning", "Parece que faltou um ponto e vírgula entre duas pessoas no secret ASSINANTES.")
      sem_tema <- sem_tema[!grepl("@", sem_tema)]
    }
    if (length(sem_tema) > 0) {
      message("Tema pedido que ainda não está em temas.R: ", paste(sem_tema, collapse = ", "))
      aviso_github("warning", paste0("Tema pedido que não está em temas.R: ",
                                     paste(sem_tema, collapse = ", "), "."))
    }
    escolhidos <- names(temas)[tolower(names(temas)) %in% tolower(pedidos)]
    if (length(escolhidos) == 0 || "todos" %in% tolower(pedidos)) escolhidos <- names(temas)
    list(email = trimws(partes[1]), temas = escolhidos)
  })
}

assinantes <- ler_assinantes(Sys.getenv("ASSINANTES"))
if (length(temas_sem_ia) > 0) {
  aviso_github("warning", paste0("Sem resumo de IA em ", length(temas_sem_ia),
                                 " tema(s). Último erro: ", ultimo_erro_ia))
}
if (length(assinantes) == 0 || !nzchar(Sys.getenv("GMAIL_SENHA_APP"))) {
  message("Sem assinantes ou sem senha do Gmail: o resumo não foi enviado por e-mail.")
  if (no_github) {
    aviso_github("error", "Faltam os secrets ASSINANTES ou GMAIL_SENHA_APP: nenhum e-mail enviado.")
    stop("Sem assinantes ou sem senha do Gmail.")
  }
} else {
  assunto <- paste0("Radar de artigos — ", format(Sys.Date(), "%d/%m/%Y"))
  enviados <- 0
  login_recusado <- FALSE
  for (a in assinantes) {
    ok <- tryCatch({
      enviar_email(a$email, assunto, montar_html(a$temas, rodape = TRUE))
      TRUE
    }, error = function(e) {
      message("Um e-mail falhou: ", conditionMessage(e))
      if (grepl("login|535|auth", conditionMessage(e), ignore.case = TRUE)) login_recusado <<- TRUE
      FALSE
    })
    enviados <- enviados + ok
  }
  if (login_recusado) {
    message("O Gmail recusou o login: confira o GMAIL_USUARIO e a senha de app.")
    aviso_github("error", "O Gmail recusou o login: confira os secrets GMAIL_USUARIO e GMAIL_SENHA_APP.")
  }
  # Mostra só quantos e-mails foram, nunca os endereços: o log do GitHub é público
  message("E-mails enviados: ", enviados, " de ", length(assinantes))
  aviso_github(if (enviados == length(assinantes)) "notice" else "warning",
               paste0("E-mails enviados: ", enviados, " de ", length(assinantes),
                      ". Modelos usados: ", if (length(modelos_usados)) paste(modelos_usados, collapse = ", ") else "nenhum"))
  if (enviados == 0) stop("Nenhum e-mail foi enviado.")
}

# Os assinantes já receberam os títulos, mas a execução fica vermelha no GitHub
# pra avisar que a chave precisa ser trocada.
if (chave_recusada) stop("O Google recusou a chave do Gemini. Confira a GEMINI_API_KEY.")
