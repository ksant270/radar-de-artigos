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
  ),
  "LUAD vs LUSC" = paste(
    '("lung adenocarcinoma"[Title/Abstract] OR LUAD[Title/Abstract])',
    'AND ("lung squamous cell carcinoma"[Title/Abstract] OR "squamous cell lung cancer"[Title/Abstract]',
    'OR "squamous cell carcinoma of the lung"[Title/Abstract] OR LUSC[Title/Abstract])'
  ),
  "Microbioma pulmonar" = paste(
    '(("lung neoplasms"[MeSH Terms] OR "lung cancer"[Title/Abstract]',
    'OR "lung adenocarcinoma"[Title/Abstract] OR NSCLC[Title/Abstract])',
    'AND (microbiome[Title/Abstract] OR microbiota[Title/Abstract]',
    'OR "Microbiota"[MeSH Terms] OR dysbiosis[Title/Abstract]))',
    'OR ("lung microbiome"[Title/Abstract] OR "lung microbiota"[Title/Abstract]',
    'OR "pulmonary microbiome"[Title/Abstract] OR "respiratory microbiome"[Title/Abstract]',
    'OR "airway microbiome"[Title/Abstract])'
  )
)

# A IA usa isso pra dar a nota de relevância de cada artigo.
interesses_do_grupo <- paste(
  "câncer gástrico, com foco em assinaturas de lncRNA, fatores de transcrição,",
  "microambiente imune do tumor e metaloproteinases de matriz,",
  "em pacientes da região Norte do Brasil"
)

# Opcional: um perfil próprio pra temas que fogem do perfil do grupo.
# Quem não estiver aqui usa o interesses_do_grupo.
interesses_por_tema <- list(
  "LUAD vs LUSC" = paste(
    "as diferenças moleculares entre o adenocarcinoma de pulmão (LUAD)",
    "e o carcinoma de células escamosas de pulmão (LUSC)"
  ),
  "Microbioma pulmonar" = paste(
    "o microbioma pulmonar e como o microbioma, do pulmão ou do intestino,",
    "influencia o câncer de pulmão"
  )
)
