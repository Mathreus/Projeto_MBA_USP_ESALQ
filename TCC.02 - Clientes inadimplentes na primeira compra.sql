WITH parametros AS (
    SELECT
        DATE '2025-12-31' AS data_referencia,
        DATE '2024-01-01' AS data_inicio_cadastro,
        DATE '2025-12-31' AS data_fim_cadastro,
        DATE '2024-01-01' AS data_inicio_movimento,
        DATE '2025-12-31' AS data_fim_movimento
),

clientes_excluidos AS (
    SELECT '1000020903' AS id_cliente UNION ALL
    SELECT '1000016271' AS id_cliente UNION ALL
    SELECT '1000033486' AS id_cliente UNION ALL
    SELECT '1000017583' AS id_cliente
),

universo_clientes AS (
    SELECT DISTINCT
        CLI.KUNNR AS id_cliente,
        CLI.NAME1 AS nome_cliente,
        SAFE_CAST(CLI.ERDAT AS DATE) AS data_cadastro
    FROM 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.kna1` AS CLI
    CROSS JOIN parametros AS P
    WHERE
        NULLIF(CLI.KUNNR, '') IS NOT NULL
        AND SAFE_CAST(CLI.KUNNR AS INT64) > 1000000000
        AND CLI.KUNNR NOT IN (SELECT id_cliente FROM clientes_excluidos)
        AND SAFE_CAST(CLI.ERDAT AS DATE) BETWEEN P.data_inicio_cadastro AND P.data_fim_cadastro
),

base_titulos_clientes AS (
    SELECT
        FIN.BUKRS AS centro,
        FIN.KUNNR AS id_cliente,

        FIN.BELNR AS documento,
        FIN.GJAHR AS exercicio,
        FIN.BUZEI AS item_documento,

        SAFE_CAST(FIN.H_BUDAT AS DATE) AS data_lancamento,

        COALESCE(
            SAFE_CAST(FIN.NETDT AS DATE),
            DATE_ADD(
                SAFE_CAST(FIN.H_BUDAT AS DATE),
                INTERVAL COALESCE(SAFE_CAST(FIN.ZBD1T AS INT64), 0) DAY
            )
        ) AS data_vencimento,

        SAFE_CAST(FIN.AUGDT AS DATE) AS data_compensacao,

        FIN.ZLSCH AS forma_pagamento,
        FIN.H_BLART AS tipo_documento,
        FIN.SHKZG AS indicador_debito_credito,

        SAFE_CAST(FIN.DMBTR AS NUMERIC) AS valor_titulo

    FROM 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bseg` AS FIN
    CROSS JOIN parametros AS P
    WHERE
        NULLIF(FIN.KUNNR, '') IS NOT NULL
        AND SAFE_CAST(FIN.KUNNR AS INT64) > 1000000000
        AND FIN.KUNNR NOT IN (SELECT id_cliente FROM clientes_excluidos)

        -- Filtros de negócio do teste:
        -- considera documentos de venda/faturamento de clientes.
        AND FIN.ZLSCH = 'E'
        AND FIN.H_BLART = 'RV'
        AND FIN.SHKZG = 'S'

        AND SAFE_CAST(FIN.H_BUDAT AS DATE) BETWEEN P.data_inicio_movimento AND P.data_fim_movimento
),

primeira_compra_cliente AS (
    SELECT
        BTC.*,

        ROW_NUMBER() OVER (
            PARTITION BY BTC.id_cliente
            ORDER BY 
                BTC.data_lancamento ASC,
                BTC.documento ASC,
                BTC.item_documento ASC
        ) AS ordem_compra

    FROM base_titulos_clientes AS BTC
),

avaliacao_primeira_compra AS (
    SELECT
        PCC.centro,
        PCC.id_cliente,

        PCC.documento AS documento_primeira_compra,
        PCC.exercicio AS exercicio_primeira_compra,
        PCC.item_documento AS item_primeira_compra,

        PCC.data_lancamento AS data_primeira_compra,
        PCC.data_vencimento AS data_vencimento_primeira_compra,
        PCC.data_compensacao AS data_compensacao_primeira_compra,

        PCC.forma_pagamento,
        PCC.tipo_documento,
        PCC.indicador_debito_credito,

        PCC.valor_titulo AS valor_primeira_compra,

        CASE
            WHEN PCC.data_compensacao IS NULL THEN 'Em aberto'
            ELSE 'Compensado'
        END AS status_compensacao_primeira_compra,

        CASE
            WHEN PCC.data_compensacao IS NULL
                THEN DATE_DIFF(P.data_referencia, PCC.data_vencimento, DAY)
            ELSE DATE_DIFF(PCC.data_compensacao, PCC.data_vencimento, DAY)
        END AS dias_atraso_primeira_compra,

        CASE
            WHEN PCC.data_compensacao IS NULL
                 AND DATE_DIFF(P.data_referencia, PCC.data_vencimento, DAY) > 0
                THEN 'Em aberto e vencida'

            WHEN PCC.data_compensacao IS NULL
                 AND DATE_DIFF(P.data_referencia, PCC.data_vencimento, DAY) <= 0
                THEN 'Em aberto e a vencer'

            WHEN PCC.data_compensacao IS NOT NULL
                 AND DATE_DIFF(PCC.data_compensacao, PCC.data_vencimento, DAY) > 0
                THEN 'Compensada com atraso'

            WHEN PCC.data_compensacao IS NOT NULL
                 AND DATE_DIFF(PCC.data_compensacao, PCC.data_vencimento, DAY) <= 0
                THEN 'Compensada no prazo'

            ELSE 'Não classificado'
        END AS classificacao_primeira_compra

    FROM primeira_compra_cliente AS PCC
    CROSS JOIN parametros AS P
    WHERE 
        PCC.ordem_compra = 1
),

resultado_teste_02 AS (
    SELECT
        U.id_cliente,
        U.nome_cliente,
        U.data_cadastro,

        A.centro,
        A.documento_primeira_compra,
        A.exercicio_primeira_compra,
        A.item_primeira_compra,

        A.data_primeira_compra,
        A.data_vencimento_primeira_compra,
        A.data_compensacao_primeira_compra,

        A.forma_pagamento,
        A.tipo_documento,
        A.indicador_debito_credito,

        A.status_compensacao_primeira_compra,

        COALESCE(A.classificacao_primeira_compra, 'Sem primeira compra identificada') AS classificacao_primeira_compra,

        COALESCE(A.valor_primeira_compra, 0) AS valor_primeira_compra,

        COALESCE(A.dias_atraso_primeira_compra, 0) AS dias_atraso_primeira_compra,

        CASE
            WHEN A.classificacao_primeira_compra IN ('Compensada com atraso', 'Em aberto e vencida')
                THEN 1
            ELSE 0
        END AS teste_02_cliente_inadimplente_primeira_compra,

        CASE
            WHEN A.classificacao_primeira_compra = 'Compensada com atraso'
                THEN 1
            ELSE 0
        END AS flag_primeira_compra_compensada_com_atraso,

        CASE
            WHEN A.classificacao_primeira_compra = 'Em aberto e vencida'
                THEN 1
            ELSE 0
        END AS flag_primeira_compra_em_aberto_vencida,

        CASE
            WHEN A.classificacao_primeira_compra = 'Compensada no prazo'
                THEN 0
            WHEN A.classificacao_primeira_compra = 'Em aberto e a vencer'
                THEN 0
            WHEN A.classificacao_primeira_compra = 'Compensada com atraso'
                THEN 1
            WHEN A.classificacao_primeira_compra = 'Em aberto e vencida'
                THEN 2
            ELSE 0
        END AS criticidade_teste_02,

        CASE
            WHEN A.classificacao_primeira_compra = 'Compensada no prazo'
                THEN 'Sem risco identificado'
            WHEN A.classificacao_primeira_compra = 'Em aberto e a vencer'
                THEN 'Sem risco identificado'
            WHEN A.classificacao_primeira_compra = 'Compensada com atraso'
                THEN 'Risco moderado'
            WHEN A.classificacao_primeira_compra = 'Em aberto e vencida'
                THEN 'Risco alto'
            ELSE 'Sem classificação'
        END AS nivel_risco_teste_02,

        CASE
            WHEN A.classificacao_primeira_compra = 'Compensada com atraso'
                THEN 2
            WHEN A.classificacao_primeira_compra = 'Em aberto e vencida'
                THEN 3
            ELSE 0
        END AS score_teste_02,

        'Alto' AS impacto_esperado_teste_02

    FROM universo_clientes AS U

    LEFT JOIN avaliacao_primeira_compra AS A
        ON U.id_cliente = A.id_cliente
)

SELECT
    id_cliente,
    nome_cliente,
    data_cadastro,

    centro,
    documento_primeira_compra,
    exercicio_primeira_compra,
    item_primeira_compra,

    data_primeira_compra,
    data_vencimento_primeira_compra,
    data_compensacao_primeira_compra,

    forma_pagamento,
    tipo_documento,
    indicador_debito_credito,

    status_compensacao_primeira_compra,
    classificacao_primeira_compra,

    valor_primeira_compra,
    dias_atraso_primeira_compra,

    teste_02_cliente_inadimplente_primeira_compra,
    flag_primeira_compra_compensada_com_atraso,
    flag_primeira_compra_em_aberto_vencida,
    criticidade_teste_02,
    nivel_risco_teste_02,
    score_teste_02,
    impacto_esperado_teste_02

FROM resultado_teste_02

ORDER BY
    teste_02_cliente_inadimplente_primeira_compra DESC,
    criticidade_teste_02 DESC,
    dias_atraso_primeira_compra DESC,
    valor_primeira_compra DESC;
