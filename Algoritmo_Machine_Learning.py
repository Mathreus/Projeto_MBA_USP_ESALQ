# -*- coding: utf-8 -*-
"""
TCC MBA USP/ESALQ
Modelo de anomalias para priorização de clientes na circularização em auditoria interna

Algoritmo principal: Isolation Forest
Abordagem: Machine Learning não supervisionado

Objetivo:
    Identificar clientes com comportamento atípico a partir de testes
    automatizados de auditoria, apoiando a priorização da circularização.

Observação:
    A classificação como cliente atípico não confirma fraude, erro ou
    irregularidade. O resultado deve ser interpretado como prioridade analítica.
"""

from pathlib import Path
import platform
import sys
import warnings

import matplotlib
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import sklearn

from sklearn.decomposition import PCA
from sklearn.ensemble import IsolationForest
from sklearn.impute import SimpleImputer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import RobustScaler


warnings.filterwarnings("ignore")


# =============================================================================
# 1. CONFIGURAÇÕES GERAIS
# =============================================================================

BASE_DIR = Path(__file__).resolve().parent

ARQUIVO_ENTRADA = BASE_DIR / "TCC_matriz_analitica_e_modelo.csv"

PASTA_SAIDA = BASE_DIR / "tcc_model_outputs_v4"
PASTA_SAIDA.mkdir(parents=True, exist_ok=True)

ARQUIVO_MATRIZ_CONSOLIDADA = (
    BASE_DIR / "TCC_matriz_consolidada_por_cliente_v4.csv"
)
ARQUIVO_SAIDA_CSV = BASE_DIR / "TCC_matriz_com_modelo_v4.csv"
ARQUIVO_SAIDA_XLSX = BASE_DIR / "TCC_resumo_modelo_v4.xlsx"
ARQUIVO_AMBIENTE = BASE_DIR / "TCC_ambiente_execucao_v4.csv"

CONTAMINACAO = 0.05
RANDOM_STATE = 42

# Mantido como True porque o script original gerava a projeção PCA.
# Caso a PCA seja retirada do TCC, pode ser alterado para False.
EXECUTAR_PCA = True

# Esta análise exige novos ajustes do Isolation Forest e pode aumentar
# significativamente o tempo de execução. Ative quando desejar gerar
# a tabela de estabilidade solicitada na revisão metodológica.
EXECUTAR_ANALISE_HIPERPARAMETROS = False


# =============================================================================
# 2. REGISTRO DO AMBIENTE COMPUTACIONAL
# =============================================================================

def obter_ambiente_execucao() -> pd.DataFrame:
    """
    Registra as versões do ambiente computacional utilizadas na execução.

    Essas informações permitem documentar a reprodutibilidade do estudo.
    """
    dados = [
        ("Python", sys.version.split()[0]),
        ("Sistema operacional", platform.platform()),
        ("NumPy", np.__version__),
        ("Pandas", pd.__version__),
        ("Matplotlib", matplotlib.__version__),
        ("Scikit-learn", sklearn.__version__),
        ("Random state", str(RANDOM_STATE)),
        ("Contamination", str(CONTAMINACAO)),
    ]

    return pd.DataFrame(dados, columns=["componente", "versao_configuracao"])


ambiente_execucao = obter_ambiente_execucao()
ambiente_execucao.to_csv(
    ARQUIVO_AMBIENTE,
    index=False,
    encoding="utf-8-sig"
)

print("\nAmbiente computacional:")
for _, linha in ambiente_execucao.iterrows():
    print(f"{linha['componente']}: {linha['versao_configuracao']}")


# =============================================================================
# 3. FUNÇÕES AUXILIARES
# =============================================================================

def ler_csv_robusto(caminho: Path) -> pd.DataFrame:
    """
    Lê arquivos CSV testando diferentes separadores e encodings.

    A função foi utilizada porque arquivos exportados do Excel ou BigQuery
    podem variar entre separador por vírgula, ponto e vírgula ou tabulação.
    """
    encodings = ["utf-8-sig", "utf-8", "latin1", "cp1252"]
    separadores = [";", ",", "\t", "|"]

    for encoding in encodings:
        for sep in separadores:
            try:
                df_teste = pd.read_csv(
                    caminho,
                    sep=sep,
                    encoding=encoding,
                    engine="python",
                    quotechar='"',
                    escapechar="\\",
                    on_bad_lines="error",
                )

                if len(df_teste.columns) > 1:
                    print(
                        f"CSV lido com separador {repr(sep)} "
                        f"e encoding {encoding}."
                    )
                    return df_teste

            except Exception:
                continue

    raise ValueError(
        "Não foi possível ler o CSV. Verifique o separador, "
        "encoding ou estrutura do arquivo."
    )


def primeiro_nao_nulo(serie: pd.Series):
    """
    Retorna o primeiro valor não nulo de uma série.
    """
    s = serie.dropna()

    if len(s) == 0:
        return np.nan

    return s.iloc[0]


def converter_para_numerico(serie: pd.Series) -> pd.Series:
    """
    Converte uma série em formato numérico de forma conservadora.

    Primeiro tenta a conversão direta. Se a série tiver sido importada como
    texto em padrão brasileiro, tenta remover pontos de milhar e substituir
    a vírgula decimal por ponto.
    """
    convertido_direto = pd.to_numeric(serie, errors="coerce")

    # Se a conversão direta funcionou para a maior parte dos valores válidos,
    # mantém o resultado para evitar alterar números já no padrão decimal.
    total_validos = serie.notna().sum()

    if total_validos == 0:
        return convertido_direto

    taxa_sucesso = convertido_direto.notna().sum() / total_validos

    if taxa_sucesso >= 0.95:
        return convertido_direto

    texto = (
        serie.astype(str)
        .str.strip()
        .replace(
            {
                "nan": np.nan,
                "None": np.nan,
                "": np.nan,
            }
        )
    )

    texto_br = (
        texto
        .str.replace(".", "", regex=False)
        .str.replace(",", ".", regex=False)
    )

    convertido_br = pd.to_numeric(texto_br, errors="coerce")

    if convertido_br.notna().sum() > convertido_direto.notna().sum():
        return convertido_br

    return convertido_direto


# =============================================================================
# 4. LEITURA DA BASE
# =============================================================================

if not ARQUIVO_ENTRADA.exists():
    raise FileNotFoundError(
        f"Arquivo não encontrado: {ARQUIVO_ENTRADA}\n"
        "Coloque o arquivo TCC_matriz_analitica_e_modelo.csv "
        "na mesma pasta deste script."
    )

df_raw = ler_csv_robusto(ARQUIVO_ENTRADA)
df_raw.columns = [str(col).strip() for col in df_raw.columns]

print("\nBase original carregada.")
print(f"Linhas originais: {len(df_raw):,}")
print(f"Colunas originais: {len(df_raw.columns):,}")


# =============================================================================
# 5. CONSOLIDAÇÃO POR CLIENTE
# =============================================================================

if "id_cliente" not in df_raw.columns:
    raise ValueError(
        "A coluna id_cliente não foi encontrada na matriz analítica."
    )

df_raw["id_cliente"] = df_raw["id_cliente"].astype(str).str.strip()

linhas_originais = len(df_raw)
clientes_unicos = df_raw["id_cliente"].nunique()
linhas_duplicadas = df_raw.duplicated("id_cliente").sum()

print("\nDiagnóstico de duplicidade:")
print(f"Clientes únicos antes da consolidação: {clientes_unicos:,}")
print(f"Linhas duplicadas por id_cliente: {linhas_duplicadas:,}")


# Remove colunas de modelos anteriores, caso existam
colunas_modelo_antigo = [
    col
    for col in df_raw.columns
    if "iforest" in col.lower()
    or "isolation_forest" in col.lower()
    or col in ["pca_1", "pca_2"]
]

df_base = df_raw.drop(
    columns=colunas_modelo_antigo,
    errors="ignore",
).copy()


# Regras de consolidação
agg = {}

for col in df_base.columns:
    if col == "id_cliente":
        continue

    col_lower = col.lower()

    if col in ["nome_cliente"]:
        agg[col] = primeiro_nao_nulo

    elif col.startswith("teste_"):
        agg[col] = "max"

    elif col.startswith("criticidade_"):
        agg[col] = "max"

    elif col.startswith("score_"):
        agg[col] = "max"

    elif col.startswith("qtd_"):
        agg[col] = "max"

    elif col.startswith("valor_"):
        agg[col] = "max"

    elif col.startswith("saldo_"):
        agg[col] = "max"

    elif col.startswith("maior_"):
        agg[col] = "max"

    elif "perc" in col_lower:
        agg[col] = "max"

    elif "dias" in col_lower:
        agg[col] = "max"

    elif "nivel" in col_lower or "status" in col_lower:
        agg[col] = primeiro_nao_nulo

    else:
        if pd.api.types.is_numeric_dtype(df_base[col]):
            agg[col] = "max"
        else:
            agg[col] = primeiro_nao_nulo


df = df_base.groupby(
    "id_cliente",
    as_index=False,
).agg(agg)


# Quantidade de linhas originais agrupadas em cada cliente
contagem_linhas = (
    df_raw.groupby("id_cliente")
    .size()
    .rename("qtd_linhas_consolidadas")
    .reset_index()
)

df = df.merge(
    contagem_linhas,
    on="id_cliente",
    how="left",
)

print("\nConsolidação concluída.")
print(f"Linhas após consolidação: {len(df):,}")
print(
    f"Linhas reduzidas: "
    f"{linhas_originais - len(df):,}"
)


# =============================================================================
# 6. RECÁLCULO DOS INDICADORES
# =============================================================================

testes = [
    f"teste_0{i}"
    for i in range(1, 7)
    if f"teste_0{i}" in df.columns
]

for teste in testes:
    df[teste] = (
        pd.to_numeric(df[teste], errors="coerce")
        .fillna(0)
        .clip(lower=0, upper=1)
        .astype(int)
    )

if testes:
    df["qtd_testes_com_indicio"] = df[testes].sum(axis=1)
else:
    df["qtd_testes_com_indicio"] = 0


scores = [
    f"score_teste_0{i}"
    for i in range(1, 7)
    if f"score_teste_0{i}" in df.columns
]

for score in scores:
    df[score] = pd.to_numeric(
        df[score],
        errors="coerce",
    ).fillna(0)

if scores:
    df["score_ponderado_auditoria"] = df[scores].sum(axis=1)
else:
    df["score_ponderado_auditoria"] = 0


criticidades = [
    f"criticidade_teste_0{i}"
    for i in range(1, 7)
    if f"criticidade_teste_0{i}" in df.columns
]

for criticidade in criticidades:
    df[criticidade] = pd.to_numeric(
        df[criticidade],
        errors="coerce",
    ).fillna(0)

if criticidades:
    df["score_total_criticidade"] = df[criticidades].sum(axis=1)
else:
    df["score_total_criticidade"] = 0


pesos_binarios = {
    "teste_01": 3,
    "teste_02": 3,
    "teste_03": 3,
    "teste_04": 2,
    "teste_05": 3,
    "teste_06": 2,
}

df["score_ponderado_binario"] = 0

for teste, peso in pesos_binarios.items():
    if teste in df.columns:
        df["score_ponderado_binario"] += df[teste] * peso


valores_priorizacao = [
    "valor_total_titulos_vencidos_abertos_30d",
    "valor_primeira_compra",
    "valor_total_estornos_cliente",
    "saldo_total_aberto_cliente",
    "valor_total_titulos_prorrogados",
    "valor_total_devolvido_cliente",
]

df["valor_referencia_priorizacao"] = 0.0

for variavel in valores_priorizacao:
    if variavel in df.columns:
        df[variavel] = pd.to_numeric(
            df[variavel],
            errors="coerce",
        ).fillna(0)

        df["valor_referencia_priorizacao"] += df[variavel]


if {
    "valor_total_devolvido_cliente",
    "valor_total_faturado_cliente",
}.issubset(df.columns):

    devolvido = pd.to_numeric(
        df["valor_total_devolvido_cliente"],
        errors="coerce",
    ).fillna(0)

    faturado = pd.to_numeric(
        df["valor_total_faturado_cliente"],
        errors="coerce",
    ).fillna(0)

    df["perc_devolucao_sobre_faturamento_recalculado"] = np.where(
        faturado > 0,
        devolvido / faturado,
        0,
    )


df["nivel_prioridade_score"] = np.select(
    [
        df["score_ponderado_auditoria"] >= 10,
        df["score_ponderado_auditoria"] >= 6,
        df["score_ponderado_auditoria"] >= 3,
    ],
    [
        "Alto",
        "Médio",
        "Baixo",
    ],
    default="Sem indício",
)

# Proxy operacional interno.
# Não representa label validada nem confirmação de risco.
df["label_operacional_alto_risco_proxy"] = (
    df["nivel_prioridade_score"].eq("Alto")
).astype(int)


df.to_csv(
    ARQUIVO_MATRIZ_CONSOLIDADA,
    index=False,
    encoding="utf-8-sig",
)


# =============================================================================
# 7. SELEÇÃO DAS VARIÁVEIS DO MODELO
# =============================================================================

variaveis_binarias = testes

variaveis_frequenciais = [
    "qtd_titulos_vencidos_abertos_30d",
    "qtd_estornos_cliente",
    "qtd_usuarios_estorno",
    "qtd_titulos_abertos_cliente",
    "qtd_titulos_prorrogados_cliente",
    "qtd_prorrogacoes_cliente",
    "qtd_notas_faturadas_cliente",
    "qtd_notas_devolucao_cliente",
    "qtd_testes_com_indicio",
    "qtd_linhas_consolidadas",
]

variaveis_continuas = [
    "valor_total_titulos_vencidos_abertos_30d",
    "maior_dias_vencido_teste_01",
    "valor_primeira_compra",
    "dias_atraso_primeira_compra",
    "valor_total_estornos_cliente",
    "maior_valor_estorno_cliente",
    "saldo_total_aberto_cliente",
    "maior_saldo_aberto_em_um_centro",
    "maior_perc_cliente_sobre_centro",
    "valor_total_titulos_prorrogados",
    "maior_valor_titulo_prorrogado",
    "dias_prorrogados_total_cliente",
    "maior_dias_prorrogados_mesmo_titulo",
    "maior_prorrogacao_individual_dias",
    "valor_total_faturado_cliente",
    "valor_total_devolvido_cliente",
    "perc_devolucao_sobre_faturamento_recalculado",
    "valor_referencia_priorizacao",
]

variaveis_ordinais = (
    criticidades
    + scores
    + [
        "score_ponderado_binario",
        "score_total_criticidade",
        "score_ponderado_auditoria",
    ]
)

variaveis_modelo = (
    variaveis_binarias
    + variaveis_frequenciais
    + variaveis_continuas
    + variaveis_ordinais
)

# Mantém apenas as variáveis realmente existentes na matriz.
# dict.fromkeys remove eventuais duplicidades preservando a ordem.
variaveis_modelo = list(
    dict.fromkeys(
        var
        for var in variaveis_modelo
        if var in df.columns
    )
)

if not variaveis_modelo:
    raise ValueError(
        "Nenhuma variável do modelo foi encontrada "
        "na matriz consolidada."
    )

print(
    f"\nVariáveis utilizadas no modelo: "
    f"{len(variaveis_modelo)}"
)


# =============================================================================
# 8. PRÉ-PROCESSAMENTO
# =============================================================================

X = df[variaveis_modelo].copy()

for col in X.columns:
    X[col] = converter_para_numerico(X[col])


pipeline_preprocessamento = Pipeline(
    steps=[
        (
            "imputacao",
            SimpleImputer(strategy="median"),
        ),
        (
            "escala",
            RobustScaler(),
        ),
    ]
)

X_proc = pipeline_preprocessamento.fit_transform(X)


# Medianas efetivamente utilizadas na imputação
medianas_imputacao = pd.DataFrame(
    {
        "variavel": variaveis_modelo,
        "mediana_imputacao": (
            pipeline_preprocessamento
            .named_steps["imputacao"]
            .statistics_
        ),
    }
)


# =============================================================================
# 9. IMPLEMENTAÇÃO DO ISOLATION FOREST
# =============================================================================

modelo = IsolationForest(
    n_estimators=300,
    contamination=CONTAMINACAO,
    max_samples="auto",
    random_state=RANDOM_STATE,
    n_jobs=-1,
)

modelo.fit(X_proc)


# O decision_function do scikit-learn atribui valores menores às observações
# mais anômalas. O sinal é invertido para que maiores valores representem
# maior grau de atipicidade no ranking do trabalho.
df["score_anomalia_iforest_v4"] = (
    -modelo.decision_function(X_proc)
)

df["cliente_atipico_iforest_v4"] = (
    modelo.predict(X_proc) == -1
).astype(int)

df["ranking_anomalia_iforest_v4"] = (
    df["score_anomalia_iforest_v4"]
    .rank(
        method="first",
        ascending=False,
    )
    .astype(int)
)

df["percentil_anomalia_iforest_v4"] = (
    df["score_anomalia_iforest_v4"]
    .rank(pct=True)
    * 100
)

df["nivel_prioridade_iforest_v4"] = np.select(
    [
        df["percentil_anomalia_iforest_v4"] >= 99,
        df["percentil_anomalia_iforest_v4"] >= 95,
        df["percentil_anomalia_iforest_v4"] >= 90,
    ],
    [
        "Crítica",
        "Alta",
        "Moderada",
    ],
    default="Baixa",
)


# =============================================================================
# 10. ANÁLISE DE SENSIBILIDADE DA CONTAMINAÇÃO
# =============================================================================

# A contaminação define o corte operacional de classificação, não a qualidade
# intrínseca do ranking. A tabela abaixo documenta quantos clientes seriam
# priorizados sob diferentes cortes aplicados ao mesmo ranking de anomalia.

cenarios_contaminacao = [0.01, 0.03, 0.05, 0.10]

sensibilidade_contaminacao = []

for contaminacao in cenarios_contaminacao:
    quantidade = int(
        np.ceil(len(df) * contaminacao)
    )

    sensibilidade_contaminacao.append(
        {
            "contaminacao": contaminacao,
            "percentual": contaminacao * 100,
            "clientes_priorizados_aproximados": quantidade,
        }
    )

sensibilidade_contaminacao = pd.DataFrame(
    sensibilidade_contaminacao
)


# =============================================================================
# 11. PCA PARA VISUALIZAÇÃO
# =============================================================================

resumo_pca = pd.DataFrame()

if EXECUTAR_PCA:
    if X_proc.shape[1] < 2:
        print(
            "\nPCA não executada: "
            "a matriz possui menos de duas variáveis."
        )
    else:
        pca = PCA(
            n_components=2,
            random_state=RANDOM_STATE,
        )

        componentes = pca.fit_transform(X_proc)

        df["pca_1"] = componentes[:, 0]
        df["pca_2"] = componentes[:, 1]

        variancia_pca_1 = float(
            pca.explained_variance_ratio_[0]
        )
        variancia_pca_2 = float(
            pca.explained_variance_ratio_[1]
        )
        variancia_pca_total = (
            variancia_pca_1
            + variancia_pca_2
        )

        resumo_pca = pd.DataFrame(
            {
                "componente": [
                    "PCA 1",
                    "PCA 2",
                    "PCA 1 + PCA 2",
                ],
                "variancia_explicada": [
                    variancia_pca_1,
                    variancia_pca_2,
                    variancia_pca_total,
                ],
                "variancia_explicada_percentual": [
                    variancia_pca_1 * 100,
                    variancia_pca_2 * 100,
                    variancia_pca_total * 100,
                ],
            }
        )

        print("\nVariância explicada pela PCA:")
        print(
            f"PCA 1: "
            f"{variancia_pca_1:.2%}"
        )
        print(
            f"PCA 2: "
            f"{variancia_pca_2:.2%}"
        )
        print(
            f"Total dos dois componentes: "
            f"{variancia_pca_total:.2%}"
        )


# =============================================================================
# 12. RESUMOS E ESTATÍSTICAS
# =============================================================================

resumo_geral = pd.DataFrame(
    {
        "indicador": [
            "linhas_originais",
            "clientes_apos_consolidacao",
            "linhas_reduzidas_por_consolidacao",
            "clientes_com_algum_indicio",
            "clientes_atipicos_isolation_forest",
            "percentual_atipicos_isolation_forest",
            "contaminacao_parametrizada",
            "variaveis_utilizadas_no_modelo",
            "n_estimators",
            "max_samples",
            "random_state",
        ],
        "valor": [
            linhas_originais,
            len(df),
            linhas_originais - len(df),
            int(
                (
                    df["qtd_testes_com_indicio"]
                    > 0
                ).sum()
            ),
            int(
                df[
                    "cliente_atipico_iforest_v4"
                ].sum()
            ),
            float(
                df[
                    "cliente_atipico_iforest_v4"
                ].mean()
            ),
            CONTAMINACAO,
            len(variaveis_modelo),
            300,
            "auto",
            RANDOM_STATE,
        ],
    }
)


resumo_testes = []

for i in range(1, 7):
    teste = f"teste_0{i}"
    score = f"score_teste_0{i}"
    criticidade = f"criticidade_teste_0{i}"

    if teste in df.columns:
        teste_num = pd.to_numeric(
            df[teste],
            errors="coerce",
        ).fillna(0)

        resumo_testes.append(
            {
                "teste": teste,
                "clientes_com_indicio": int(
                    teste_num.sum()
                ),
                "percentual_clientes_com_indicio": float(
                    teste_num.mean()
                ),
                "score_medio": (
                    float(
                        pd.to_numeric(
                            df[score],
                            errors="coerce",
                        )
                        .fillna(0)
                        .mean()
                    )
                    if score in df.columns
                    else np.nan
                ),
                "criticidade_media": (
                    float(
                        pd.to_numeric(
                            df[criticidade],
                            errors="coerce",
                        )
                        .fillna(0)
                        .mean()
                    )
                    if criticidade in df.columns
                    else np.nan
                ),
            }
        )

resumo_testes = pd.DataFrame(
    resumo_testes
)


variaveis_descritivas = [
    var
    for var in [
        "qtd_testes_com_indicio",
        "score_ponderado_auditoria",
        "valor_referencia_priorizacao",
        "score_anomalia_iforest_v4",
        "valor_total_titulos_vencidos_abertos_30d",
        "valor_total_estornos_cliente",
        "saldo_total_aberto_cliente",
        "valor_total_titulos_prorrogados",
        "valor_total_devolvido_cliente",
        "perc_devolucao_sobre_faturamento_recalculado",
    ]
    if var in df.columns
]

estatistica_descritiva = (
    df[variaveis_descritivas]
    .apply(
        pd.to_numeric,
        errors="coerce",
    )
    .describe(
        percentiles=[
            0.25,
            0.50,
            0.75,
            0.90,
            0.95,
            0.99,
        ]
    )
    .T
    .reset_index()
    .rename(
        columns={
            "index": "variavel",
        }
    )
)


cols_top = [
    "id_cliente",
    "nome_cliente",
    "qtd_linhas_consolidadas",
    "qtd_testes_com_indicio",
    "score_ponderado_auditoria",
    "valor_referencia_priorizacao",
    "score_anomalia_iforest_v4",
    "cliente_atipico_iforest_v4",
    "ranking_anomalia_iforest_v4",
    "nivel_prioridade_iforest_v4",
] + testes

cols_top = [
    col
    for col in cols_top
    if col in df.columns
]

top_clientes = (
    df[cols_top]
    .sort_values(
        "ranking_anomalia_iforest_v4"
    )
    .head(100)
)


if testes:
    corr = (
        df[testes]
        .apply(
            pd.to_numeric,
            errors="coerce",
        )
        .fillna(0)
        .corr()
    )
else:
    corr = pd.DataFrame()


# =============================================================================
# 13. ANÁLISE OPCIONAL DE ESTABILIDADE DOS HIPERPARÂMETROS
# =============================================================================

def analisar_estabilidade_hiperparametros(
    X_processado,
    df_referencia,
) -> pd.DataFrame:
    """
    Compara configurações simples de n_estimators e max_samples.

    A análise utiliza:
    - correlação de Spearman entre rankings;
    - sobreposição entre Top 100;
    - sobreposição entre Top 1.000.

    Atenção:
        Esta rotina treina múltiplos modelos e pode aumentar
        consideravelmente o tempo de execução.
    """
    configuracoes = [
        {
            "n_estimators": 100,
            "max_samples": "auto",
        },
        {
            "n_estimators": 200,
            "max_samples": "auto",
        },
        {
            "n_estimators": 300,
            "max_samples": "auto",
        },
        {
            "n_estimators": 500,
            "max_samples": "auto",
        },
        {
            "n_estimators": 300,
            "max_samples": 256,
        },
        {
            "n_estimators": 300,
            "max_samples": 512,
        },
    ]

    ranking_base = (
        df_referencia[
            "score_anomalia_iforest_v4"
        ]
        .rank(
            method="first",
            ascending=False,
        )
    )

    top100_base = set(
        ranking_base.nsmallest(
            min(100, len(ranking_base))
        ).index
    )

    top1000_base = set(
        ranking_base.nsmallest(
            min(1000, len(ranking_base))
        ).index
    )

    resultados = []

    for config in configuracoes:
        print(
            "\nTestando estabilidade: "
            f"n_estimators={config['n_estimators']}, "
            f"max_samples={config['max_samples']}"
        )

        if (
            config["n_estimators"] == 300
            and config["max_samples"] == "auto"
        ):
            scores_config = (
                df_referencia[
                    "score_anomalia_iforest_v4"
                ].copy()
            )
        else:
            modelo_teste = IsolationForest(
                n_estimators=config[
                    "n_estimators"
                ],
                contamination=CONTAMINACAO,
                max_samples=config[
                    "max_samples"
                ],
                random_state=RANDOM_STATE,
                n_jobs=-1,
            )

            modelo_teste.fit(
                X_processado
            )

            scores_config = pd.Series(
                -modelo_teste.decision_function(
                    X_processado
                ),
                index=df_referencia.index,
            )

        ranking_config = scores_config.rank(
            method="first",
            ascending=False,
        )

        correlacao_spearman = (
            ranking_base.corr(
                ranking_config,
                method="spearman",
            )
        )

        top100_config = set(
            ranking_config.nsmallest(
                min(
                    100,
                    len(ranking_config),
                )
            ).index
        )

        top1000_config = set(
            ranking_config.nsmallest(
                min(
                    1000,
                    len(ranking_config),
                )
            ).index
        )

        sobreposicao_top100 = (
            len(
                top100_base.intersection(
                    top100_config
                )
            )
            / max(
                1,
                len(top100_base),
            )
        )

        sobreposicao_top1000 = (
            len(
                top1000_base.intersection(
                    top1000_config
                )
            )
            / max(
                1,
                len(top1000_base),
            )
        )

        resultados.append(
            {
                "n_estimators": config[
                    "n_estimators"
                ],
                "max_samples": config[
                    "max_samples"
                ],
                "correlacao_spearman_ranking": (
                    correlacao_spearman
                ),
                "sobreposicao_top100": (
                    sobreposicao_top100
                ),
                "sobreposicao_top1000": (
                    sobreposicao_top1000
                ),
            }
        )

    return pd.DataFrame(
        resultados
    )


estabilidade_hiperparametros = (
    pd.DataFrame()
)

if EXECUTAR_ANALISE_HIPERPARAMETROS:
    estabilidade_hiperparametros = (
        analisar_estabilidade_hiperparametros(
            X_proc,
            df,
        )
    )


# =============================================================================
# 14. GERAÇÃO DE GRÁFICOS
# =============================================================================

if not resumo_testes.empty:
    plt.figure(
        figsize=(8, 4.5)
    )

    plt.bar(
        resumo_testes["teste"],
        resumo_testes[
            "clientes_com_indicio"
        ],
    )

    plt.title(
        "Clientes com indício por teste de auditoria"
    )
    plt.xlabel(
        "Teste"
    )
    plt.ylabel(
        "Quantidade de clientes"
    )
    plt.tight_layout()

    plt.savefig(
        PASTA_SAIDA
        / "fig1_clientes_por_teste_v4.png",
        dpi=200,
    )
    plt.close()


plt.figure(
    figsize=(8, 5)
)

plt.scatter(
    df["score_ponderado_auditoria"],
    df["score_anomalia_iforest_v4"],
    s=8,
    alpha=0.35,
)

plt.title(
    "Score de auditoria versus score de anomalia"
)
plt.xlabel(
    "Score ponderado de auditoria"
)
plt.ylabel(
    "Score de anomalia - Isolation Forest"
)
plt.tight_layout()

plt.savefig(
    PASTA_SAIDA
    / "fig2_score_auditoria_vs_anomalia_v4.png",
    dpi=200,
)
plt.close()


if EXECUTAR_PCA and {
    "pca_1",
    "pca_2",
}.issubset(df.columns):

    amostra = df.sample(
        min(20000, len(df)),
        random_state=RANDOM_STATE,
    )

    plt.figure(
        figsize=(8, 5)
    )

    plt.scatter(
        amostra["pca_1"],
        amostra["pca_2"],
        s=8,
        alpha=0.35,
    )

    plt.title(
        "Visualização dos clientes por PCA"
    )
    plt.xlabel(
        "Componente principal 1"
    )
    plt.ylabel(
        "Componente principal 2"
    )
    plt.tight_layout()

    plt.savefig(
        PASTA_SAIDA
        / "fig3_pca_clientes_v4.png",
        dpi=200,
    )
    plt.close()


if not corr.empty:
    plt.figure(
        figsize=(6, 5)
    )

    plt.imshow(
        corr,
        aspect="auto",
    )

    plt.colorbar(
        label="Correlação"
    )

    plt.xticks(
        range(len(testes)),
        testes,
        rotation=45,
        ha="right",
    )

    plt.yticks(
        range(len(testes)),
        testes,
    )

    plt.title(
        "Correlação entre testes de auditoria"
    )
    plt.tight_layout()

    plt.savefig(
        PASTA_SAIDA
        / "fig4_correlacao_testes_v4.png",
        dpi=200,
    )
    plt.close()


# =============================================================================
# 15. EXPORTAÇÃO DOS RESULTADOS
# =============================================================================

df.to_csv(
    ARQUIVO_SAIDA_CSV,
    index=False,
    encoding="utf-8-sig",
)


with pd.ExcelWriter(
    ARQUIVO_SAIDA_XLSX,
    engine="openpyxl",
) as writer:

    resumo_geral.to_excel(
        writer,
        sheet_name="Resumo Geral",
        index=False,
    )

    resumo_testes.to_excel(
        writer,
        sheet_name="Resumo Testes",
        index=False,
    )

    estatistica_descritiva.to_excel(
        writer,
        sheet_name="Estatistica Descritiva",
        index=False,
    )

    if not corr.empty:
        corr.reset_index().to_excel(
            writer,
            sheet_name="Correlacao Testes",
            index=False,
        )

    top_clientes.to_excel(
        writer,
        sheet_name="Top 100 Clientes",
        index=False,
    )

    ambiente_execucao.to_excel(
        writer,
        sheet_name="Ambiente",
        index=False,
    )

    medianas_imputacao.to_excel(
        writer,
        sheet_name="Medianas Imputacao",
        index=False,
    )

    sensibilidade_contaminacao.to_excel(
        writer,
        sheet_name="Sensib Contaminacao",
        index=False,
    )

    if not resumo_pca.empty:
        resumo_pca.to_excel(
            writer,
            sheet_name="PCA",
            index=False,
        )

    if not estabilidade_hiperparametros.empty:
        estabilidade_hiperparametros.to_excel(
            writer,
            sheet_name="Estabilidade Hiperparam",
            index=False,
        )


# =============================================================================
# 16. MENSAGEM FINAL
# =============================================================================

print(
    "\nModelo executado com sucesso."
)

print(
    f"Linhas originais: "
    f"{linhas_originais:,}"
)

print(
    f"Clientes após consolidação: "
    f"{len(df):,}"
)

print(
    f"Linhas reduzidas pela consolidação: "
    f"{linhas_originais - len(df):,}"
)

print(
    "Clientes com algum indício: "
    f"{int((df['qtd_testes_com_indicio'] > 0).sum()):,}"
)

print(
    "Clientes atípicos pelo Isolation Forest: "
    f"{int(df['cliente_atipico_iforest_v4'].sum()):,}"
)

print(
    "Percentual de clientes atípicos: "
    f"{df['cliente_atipico_iforest_v4'].mean():.2%}"
)

print(
    f"Variáveis utilizadas no modelo: "
    f"{len(variaveis_modelo)}"
)

print(
    f"Matriz consolidada: "
    f"{ARQUIVO_MATRIZ_CONSOLIDADA}"
)

print(
    f"Matriz com modelo: "
    f"{ARQUIVO_SAIDA_CSV}"
)

print(
    f"Resumo do modelo: "
    f"{ARQUIVO_SAIDA_XLSX}"
)

print(
    f"Ambiente de execução: "
    f"{ARQUIVO_AMBIENTE}"
)

print(
    f"Gráficos: "
    f"{PASTA_SAIDA}"
)

if EXECUTAR_PCA and not resumo_pca.empty:
    total_pca = float(
        resumo_pca.loc[
            resumo_pca["componente"]
            == "PCA 1 + PCA 2",
            "variancia_explicada_percentual",
        ].iloc[0]
    )

    print(
        "Variância explicada pelos dois "
        f"componentes da PCA: {total_pca:.2f}%"
    )

if not estabilidade_hiperparametros.empty:
    print(
        "\nAnálise de estabilidade dos "
        "hiperparâmetros concluída."
    )
