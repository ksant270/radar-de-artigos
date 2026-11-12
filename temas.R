# Temas que o radar busca toda semana no PubMed.
# Pra criar um tema novo, copie um item da lista e troque o nome e a busca.
# Dá pra testar a busca antes em pubmed.ncbi.nlm.nih.gov.

cancer_gastrico <- paste(
  '("stomach neoplasms"[MeSH Terms] OR "gastric cancer"[Title/Abstract]',
  'OR "gastric adenocarcinoma"[Title/Abstract] OR "stomach cancer"[Title/Abstract])'
)

temas <- list(
  "lncRNA" = paste(
    cancer_gastrico,
    'AND ("long non-coding RNA"[Title/Abstract] OR "long noncoding RNA"[Title/Abstract]',
    'OR lncRNA[Title/Abstract])'
  ),
  "Fatores de transcrição" = paste(
    cancer_gastrico,
    'AND ("transcription factor"[Title/Abstract] OR "transcription factors"[Title/Abstract])'
  ),
  "Microambiente imune" = paste(
    cancer_gastrico,
    'AND ("tumor microenvironment"[Title/Abstract] OR "tumour microenvironment"[Title/Abstract]',
    'OR "immune infiltration"[Title/Abstract] OR "tumor-infiltrating"[Title/Abstract])'
  )
)

# A IA usa isso pra dar a nota de relevância de cada artigo.
interesses_do_grupo <- paste(
  "câncer gástrico, com foco em assinaturas de lncRNA, fatores de transcrição,",
  "microambiente imune do tumor e metaloproteinases de matriz,",
  "em pacientes da região Norte do Brasil"
)
