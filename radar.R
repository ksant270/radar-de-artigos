# Radar de artigos
# Busca no PubMed os artigos novos dos temas definidos em temas.R, resume cada
# um com IA (Gemini), gera um resumo da semana em HTML e manda por e-mail pra
# quem assinou, cada pessoa só com os temas que escolheu.
#
# Como rodar, no console do R:
#   setwd("~/Desktop/radar-de-artigos")
#   source("radar.R")


# 1. Configuração --------------------------------------------------------------

pacotes <- c("rentrez", "xml2", "ellmer", "commonmark")
faltando <- setdiff(pacotes, rownames(installed.packages()))
if (length(faltando) > 0) install.packages(faltando)
if (packageVersion("ellmer") < "0.2.0") {
  stop("Seu pacote ellmer está desatualizado. Rode install.packages(\"ellmer\"), ",
       "reinicie o R e rode o radar de novo.")
}

library(rentrez)
library(xml2)
library(ellmer)

source("temas.R")

dias <- 7           # busca artigos que entraram no PubMed nos últimos N dias
max_por_tema <- 20  # no máximo N artigos por tema
nota_destaque <- 4  # a partir dessa nota, o artigo aparece com resumo

# Modelos do Gemini em ordem de preferência. Se um estiver sobrecarregado ou
# indisponível, o radar tenta o próximo da lista.
modelos <- c("gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.5-flash",
             "gemini-flash-lite-latest", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite")
options(ellmer_timeout_s = 90)  # se um modelo não responder em 90 segundos, passa pro próximo
modelos_usados <- character(0)
modelos_com_falha <- character(0)  # quem falhou uma vez é pulado nos próximos temas

# Chave da API, e-mail e assinantes ficam em chave_api.txt, que nunca vai pro
# GitHub. No GitHub Actions, eles vêm dos "secrets" do repositório.
if (file.exists("chave_api.txt")) readRenviron("chave_api.txt")
if (Sys.getenv("GEMINI_API_KEY") %in% c("", "cole_sua_chave_aqui")) {
  stop("Coloque sua chave do Gemini no arquivo chave_api.txt (GEMINI_API_KEY=sua_chave).")
}


# 2. Busca no PubMed -----------------------------------------------------------

buscar_pubmed <- function(consulta) {
  # Tira avisos de retratação e errata, que não são artigos novos
  consulta <- paste0("(", consulta, ") NOT (\"retraction notice\"[Publication Type]",
                     " OR \"published erratum\"[Publication Type])")
  busca <- entrez_search(db = "pubmed", term = consulta, datetype = "edat",
                         reldate = dias, retmax = max_por_tema)
  if (length(busca$ids) == 0) return(NULL)

  xml <- read_xml(entrez_fetch(db = "pubmed", id = busca$ids,
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

instrucoes <- paste(
  "Você ajuda um grupo de pesquisa a acompanhar a literatura científica.",
  paste0("O grupo estuda ", interesses_do_grupo, "."),
  "Para cada artigo recebido: resuma em português, em no máximo 2 frases,",
  "o que o estudo fez e o principal achado; dê uma nota de relevância de 1 a 5",
  "para o grupo (5 = muito relevante); e explique a nota em uma frase curta.",
  "Use apenas o título e o abstract fornecidos: não invente resultados, números",
  "ou métodos que não estejam no texto. Se o abstract estiver vazio, escreva",
  "'Sem abstract disponível.' e dê nota 1."
)

formato <- type_array(
  items = type_object(
    pmid       = type_string("PMID do artigo, exatamente como recebido"),
    resumo     = type_string("Resumo em português, em no máximo 2 frases"),
    relevancia = type_integer("Nota de relevância para o grupo, de 1 a 5"),
    motivo     = type_string("Por que essa nota, em uma frase curta")
  )
)

# Manda todos os artigos de um tema numa chamada só (gasta menos do limite
# gratuito) e devolve uma tabela com resumo, nota e motivo de cada PMID.
resumir <- function(tema, artigos) {
  texto <- paste0(
    "PMID: ", artigos$pmid, "\n",
    "Título: ", artigos$titulo, "\n",
    "Abstract: ", ifelse(nzchar(artigos$abstract), artigos$abstract, "(vazio)"),
    collapse = "\n\n---\n\n"
  )
  pedido <- paste0("Tema: ", tema, "\n\nArtigos:\n\n", texto)

  for (rodada in 1:2) {
    candidatos <- if (rodada == 1) setdiff(modelos, modelos_com_falha) else modelos
    if (length(candidatos) == 0) candidatos <- modelos
    for (modelo in candidatos) {
      resposta <- tryCatch({
        chat <- chat_google_gemini(system_prompt = instrucoes, model = modelo, echo = "none",
                                   params = params(temperature = 0.2, max_tokens = 16384))
        chat$chat_structured(pedido, type = formato)
      }, error = function(e) {
        message("  ", modelo, " não respondeu: ", gsub("\\s+", " ", conditionMessage(e)))
        modelos_com_falha <<- unique(c(modelos_com_falha, modelo))
        NULL
      })
      if (!is.null(resposta)) {
        message("  Resumido com ", modelo)
        modelos_usados <<- unique(c(modelos_usados, modelo))
        resposta <- as.data.frame(resposta)
        resposta$pmid <- gsub("\\D", "", resposta$pmid)
        return(resposta[!duplicated(resposta$pmid), ])
      }
    }
    if (rodada == 1) {
      message("Nenhum modelo respondeu. Tentando de novo em 60 segundos...")
      Sys.sleep(60)
    }
  }
  stop("Nenhum modelo do Gemini respondeu. Tente de novo mais tarde.")
}


# 4. Busca e resume cada tema --------------------------------------------------

resultados <- list()
vistos <- character(0)  # evita repetir um artigo que aparece em mais de um tema

for (tema in names(temas)) {
  message("Buscando: ", tema)
  artigos <- buscar_pubmed(temas[[tema]])
  if (!is.null(artigos)) artigos <- artigos[!artigos$pmid %in% vistos, ]
  if (is.null(artigos) || nrow(artigos) == 0) next
  vistos <- c(vistos, artigos$pmid)

  message("Resumindo ", nrow(artigos), " artigo(s) com IA...")
  artigos <- merge(artigos, resumir(tema, artigos), by = "pmid", all.x = TRUE)
  resultados[[tema]] <- artigos[order(-artigos$relevancia), ]
  Sys.sleep(5)  # pausa entre temas, por causa do limite do plano gratuito
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
  curl::send_mail(
    mail_from = Sys.getenv("GMAIL_USUARIO"), mail_rcpt = para, message = mensagem,
    smtp_server = Sys.getenv("SMTP_SERVIDOR", "smtps://smtp.gmail.com:465"),
    username = Sys.getenv("GMAIL_USUARIO"), password = Sys.getenv("GMAIL_SENHA_APP"),
    verbose = FALSE
  )
}

ler_assinantes <- function(texto) {
  itens <- trimws(unlist(strsplit(texto, "[;\n]")))
  lapply(itens[nzchar(itens)], function(item) {
    partes <- strsplit(item, ":", fixed = TRUE)[[1]]
    pedidos <- if (length(partes) > 1) trimws(strsplit(partes[2], ",")[[1]]) else "todos"
    pedidos <- pedidos[nzchar(pedidos)]
    sem_tema <- setdiff(tolower(pedidos), c(tolower(names(temas)), "todos"))
    if (length(sem_tema) > 0) {
      message("Tema pedido que ainda não está em temas.R: ", paste(sem_tema, collapse = ", "))
    }
    escolhidos <- names(temas)[tolower(names(temas)) %in% tolower(pedidos)]
    if (length(escolhidos) == 0 || "todos" %in% tolower(pedidos)) escolhidos <- names(temas)
    list(email = trimws(partes[1]), temas = escolhidos)
  })
}

assinantes <- ler_assinantes(Sys.getenv("ASSINANTES"))
if (length(assinantes) == 0 || !nzchar(Sys.getenv("GMAIL_SENHA_APP"))) {
  message("Sem assinantes ou sem senha do Gmail: o resumo não foi enviado por e-mail.")
} else {
  assunto <- paste0("Radar de artigos — ", format(Sys.Date(), "%d/%m/%Y"))
  enviados <- 0
  for (a in assinantes) {
    ok <- tryCatch({
      enviar_email(a$email, assunto, montar_html(a$temas, rodape = TRUE))
      TRUE
    }, error = function(e) {
      message("Um e-mail falhou: ", conditionMessage(e))
      FALSE
    })
    enviados <- enviados + ok
  }
  # Mostra só quantos e-mails foram, nunca os endereços: o log do GitHub é público
  message("E-mails enviados: ", enviados, " de ", length(assinantes))
}
