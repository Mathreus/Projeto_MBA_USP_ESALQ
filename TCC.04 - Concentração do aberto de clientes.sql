WITH parametros AS (
    SELECT
        DATE '2024-01-01' AS data_inicio,
        DATE '2025-12-31' AS data_fim,
        0.05 AS percentual_concentracao_moderada,
        0.10 AS percentual_concentracao_alta
),

clientes_excluidos AS (
    SELECT '1000016115' AS id_cliente UNION ALL
    SELECT '1000300196' AS id_cliente UNION ALL
    SELECT '1000002790' AS id_cliente UNION ALL
    SELECT '5200000001' AS id_cliente
),

base_aberto AS (
    SELECT DISTINCT
        ABT.MANDT,
        ABT.BUKRS AS empresa,
        ABT.BUPLA AS local_negocios,

        CONCAT(
            SUBSTR(ABT.BUKRS, 1, 2),
            SUBSTR(ABT.BUPLA, -2)
        ) AS centro,

        ABT.KUNNR AS id_cliente,

        ABT.BELNR AS documento,
        ABT.GJAHR AS exercicio,
        ABT.BUZEI AS item_documento,

        SAFE_CAST(ABT.BUDAT AS DATE) AS data_lancamento,
        ABT.XBLNR AS referencia,
        ABT.SGTXT AS texto,
        ABT.BLART AS tipo_documento,
        ABT.SHKZG AS indicador_debito_credito,

        -- Valor com sinal econômico.
        -- Débito aumenta o saldo em aberto; crédito reduz.
        CASE
            WHEN ABT.SHKZG = 'H' THEN -ABS(SAFE_CAST(ABT.DMBTR AS NUMERIC))
            ELSE ABS(SAFE_CAST(ABT.DMBTR AS NUMERIC))
        END AS valor_saldo_aberto,

        ABS(SAFE_CAST(ABT.DMBTR AS NUMERIC)) AS valor_absoluto

    FROM 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bsid` AS ABT
    CROSS JOIN parametros AS P
    WHERE
        ABT.BUKRS IN (
            '2000', '2100', '2200', '2300', '2400', '2500', '2600',
            '2700', '2800', '2900', '3000', '3100', '3200', '3300'
        )
        AND NULLIF(ABT.KUNNR, '') IS NOT NULL
        AND SAFE_CAST(ABT.KUNNR AS INT64) > 1000000000
        AND ABT.KUNNR NOT IN (SELECT id_cliente FROM clientes_excluidos)
        AND ABT.BLART = 'RV'
        AND NULLIF(ABT.BUPLA, '') IS NOT NULL
        AND SAFE_CAST(ABT.BUDAT AS DATE) BETWEEN P.data_inicio AND P.data_fim
),

clientes AS (
    SELECT
        MANDT,
        KUNNR AS id_cliente,
        ANY_VALUE(NAME1) AS nome_cliente
    FROM 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.kna1`
    GROUP BY
        MANDT,
        KUNNR
),

aberto_por_cliente_centro AS (
    SELECT
        B.empresa,
        B.local_negocios,
        B.centro,
        B.id_cliente,
        COALESCE(C.nome_cliente, 'SEM CADASTRO') AS nome_cliente,

        COUNT(
            DISTINCT CONCAT(
                COALESCE(CAST(B.empresa AS STRING), ''),
                '|',
                COALESCE(CAST(B.exercicio AS STRING), ''),
                '|',
                COALESCE(CAST(B.documento AS STRING), ''),
                '|',
                COALESCE(CAST(B.item_documento AS STRING), '')
            )
        ) AS qtd_titulos_abertos_cliente_centro,

        SUM(B.valor_saldo_aberto) AS saldo_aberto_cliente_centro,
        SUM(B.valor_absoluto) AS valor_absoluto_cliente_centro

    FROM base_aberto AS B

    LEFT JOIN clientes AS C
        ON B.MANDT = C.MANDT
       AND B.id_cliente = C.id_cliente

    GROUP BY
        B.empresa,
        B.local_negocios,
        B.centro,
        B.id_cliente,
        nome_cliente
),

total_centro AS (
    SELECT
        empresa,
        local_negocios,
        centro,

        SUM(saldo_aberto_cliente_centro) AS total_saldo_aberto_centro,
        SUM(valor_absoluto_cliente_centro) AS total_valor_absoluto_centro

    FROM aberto_por_cliente_centro

    GROUP BY
        empresa,
        local_negocios,
        centro
),

ranking_clientes_centro AS (
    SELECT
        A.empresa,
        A.local_negocios,
        A.centro,
        A.id_cliente,
        A.nome_cliente,

        A.qtd_titulos_abertos_cliente_centro,
        A.saldo_aberto_cliente_centro,
        A.valor_absoluto_cliente_centro,

        TC.total_saldo_aberto_centro,
        TC.total_valor_absoluto_centro,

        SAFE_DIVIDE(
            A.saldo_aberto_cliente_centro,
            TC.total_saldo_aberto_centro
        ) AS perc_cliente_sobre_centro,

        ROW_NUMBER() OVER (
            PARTITION BY A.empresa, A.centro
            ORDER BY A.saldo_aberto_cliente_centro DESC, A.id_cliente
        ) AS ranking_centro

    FROM aberto_por_cliente_centro AS A

    INNER JOIN total_centro AS TC
        ON A.empresa = TC.empresa
       AND A.local_negocios = TC.local_negocios
       AND A.centro = TC.centro

    WHERE
        A.saldo_aberto_cliente_centro > 0
        AND TC.total_saldo_aberto_centro > 0
),

limiares_concentracao AS (
    SELECT
        COALESCE(APPROX_QUANTILES(saldo_aberto_cliente_centro, 100)[OFFSET(75)], 0) AS saldo_aberto_p75,
        COALESCE(APPROX_QUANTILES(saldo_aberto_cliente_centro, 100)[OFFSET(90)], 0) AS saldo_aberto_p90,

        COALESCE(APPROX_QUANTILES(perc_cliente_sobre_centro, 100)[OFFSET(75)], 0) AS perc_centro_p75,
        COALESCE(APPROX_QUANTILES(perc_cliente_sobre_centro, 100)[OFFSET(90)], 0) AS perc_centro_p90

    FROM ranking_clientes_centro
    WHERE saldo_aberto_cliente_centro > 0
),

classificacao_cliente_centro AS (
    SELECT
        R.*,

        L.saldo_aberto_p75,
        L.saldo_aberto_p90,
        L.perc_centro_p75,
        L.perc_centro_p90,

        CASE
            WHEN R.ranking_centro <= 10 THEN 1
            ELSE 0
        END AS flag_top10_centro,

        CASE
            WHEN R.ranking_centro <= 5 THEN 1
            ELSE 0
        END AS flag_top5_centro,

        CASE
            WHEN R.perc_cliente_sobre_centro >= P.percentual_concentracao_moderada THEN 1
            ELSE 0
        END AS flag_perc_centro_acima_5,

        CASE
            WHEN R.perc_cliente_sobre_centro >= P.percentual_concentracao_alta THEN 1
            ELSE 0
        END AS flag_perc_centro_acima_10,

        CASE
            WHEN R.saldo_aberto_cliente_centro >= L.saldo_aberto_p75 THEN 1
            ELSE 0
        END AS flag_saldo_acima_p75,

        CASE
            WHEN R.saldo_aberto_cliente_centro >= L.saldo_aberto_p90 THEN 1
            ELSE 0
        END AS flag_saldo_acima_p90,

        CASE
            WHEN R.perc_cliente_sobre_centro >= L.perc_centro_p75 THEN 1
            ELSE 0
        END AS flag_concentracao_acima_p75,

        CASE
            WHEN R.perc_cliente_sobre_centro >= L.perc_centro_p90 THEN 1
            ELSE 0
        END AS flag_concentracao_acima_p90

    FROM ranking_clientes_centro AS R

    CROSS JOIN limiares_concentracao AS L

    CROSS JOIN parametros AS P
),

resumo_cliente AS (
    SELECT
        id_cliente,
        MAX(nome_cliente) AS nome_cliente,

        STRING_AGG(DISTINCT empresa, ', ') AS empresas_com_saldo_aberto,
        STRING_AGG(DISTINCT centro, ', ') AS centros_com_saldo_aberto,

        COUNT(DISTINCT centro) AS qtd_centros_com_saldo_aberto,

        SUM(qtd_titulos_abertos_cliente_centro) AS qtd_titulos_abertos_cliente,

        SUM(saldo_aberto_cliente_centro) AS saldo_total_aberto_cliente,

        MAX(saldo_aberto_cliente_centro) AS maior_saldo_aberto_em_um_centro,

        MAX(perc_cliente_sobre_centro) AS maior_perc_cliente_sobre_centro,

        MIN(ranking_centro) AS melhor_ranking_centro,

        MAX(flag_top10_centro) AS flag_top10_centro,
        MAX(flag_top5_centro) AS flag_top5_centro,

        MAX(flag_perc_centro_acima_5) AS flag_perc_centro_acima_5,
        MAX(flag_perc_centro_acima_10) AS flag_perc_centro_acima_10,

        MAX(flag_saldo_acima_p75) AS flag_saldo_acima_p75,
        MAX(flag_saldo_acima_p90) AS flag_saldo_acima_p90,

        MAX(flag_concentracao_acima_p75) AS flag_concentracao_acima_p75,
        MAX(flag_concentracao_acima_p90) AS flag_concentracao_acima_p90,

        MAX(saldo_aberto_p75) AS saldo_aberto_p75,
        MAX(saldo_aberto_p90) AS saldo_aberto_p90,
        MAX(perc_centro_p75) AS perc_centro_p75,
        MAX(perc_centro_p90) AS perc_centro_p90

    FROM classificacao_cliente_centro

    GROUP BY
        id_cliente
),

resultado_teste_04 AS (
    SELECT
        id_cliente,
        nome_cliente,

        empresas_com_saldo_aberto,
        centros_com_saldo_aberto,

        qtd_centros_com_saldo_aberto,
        qtd_titulos_abertos_cliente,
        saldo_total_aberto_cliente,
        maior_saldo_aberto_em_um_centro,
        maior_perc_cliente_sobre_centro,
        melhor_ranking_centro,

        saldo_aberto_p75,
        saldo_aberto_p90,
        perc_centro_p75,
        perc_centro_p90,

        flag_top10_centro,
        flag_top5_centro,
        flag_perc_centro_acima_5,
        flag_perc_centro_acima_10,
        flag_saldo_acima_p75,
        flag_saldo_acima_p90,
        flag_concentracao_acima_p75,
        flag_concentracao_acima_p90,

        CASE
            WHEN flag_top10_centro = 1
             AND (
                    flag_perc_centro_acima_5 = 1
                 OR flag_saldo_acima_p75 = 1
                 OR flag_concentracao_acima_p75 = 1
             )
                THEN 1
            ELSE 0
        END AS teste_04_concentracao_saldo_aberto_cliente,

        CASE
            WHEN flag_top5_centro = 1
             AND (
                    flag_perc_centro_acima_10 = 1
                 OR flag_saldo_acima_p90 = 1
                 OR flag_concentracao_acima_p90 = 1
             )
                THEN 2

            WHEN flag_top10_centro = 1
             AND (
                    flag_perc_centro_acima_5 = 1
                 OR flag_saldo_acima_p75 = 1
                 OR flag_concentracao_acima_p75 = 1
             )
                THEN 1

            ELSE 0
        END AS criticidade_teste_04,

        CASE
            WHEN flag_top5_centro = 1
             AND (
                    flag_perc_centro_acima_10 = 1
                 OR flag_saldo_acima_p90 = 1
                 OR flag_concentracao_acima_p90 = 1
             )
                THEN 'Risco alto'

            WHEN flag_top10_centro = 1
             AND (
                    flag_perc_centro_acima_5 = 1
                 OR flag_saldo_acima_p75 = 1
                 OR flag_concentracao_acima_p75 = 1
             )
                THEN 'Risco moderado'

            WHEN saldo_total_aberto_cliente > 0
                THEN 'Saldo em aberto sem concentração relevante'

            ELSE 'Sem saldo em aberto'
        END AS nivel_risco_teste_04,

        CASE
            WHEN flag_top5_centro = 1
             AND (
                    flag_perc_centro_acima_10 = 1
                 OR flag_saldo_acima_p90 = 1
                 OR flag_concentracao_acima_p90 = 1
             )
                THEN 3

            WHEN flag_top10_centro = 1
             AND (
                    flag_perc_centro_acima_5 = 1
                 OR flag_saldo_acima_p75 = 1
                 OR flag_concentracao_acima_p75 = 1
             )
                THEN 2

            ELSE 0
        END AS score_teste_04,

        'Médio' AS impacto_esperado_teste_04

    FROM resumo_cliente
)

SELECT
    id_cliente,
    nome_cliente,

    empresas_com_saldo_aberto,
    centros_com_saldo_aberto,

    qtd_centros_com_saldo_aberto,
    qtd_titulos_abertos_cliente,
    saldo_total_aberto_cliente,
    maior_saldo_aberto_em_um_centro,
    maior_perc_cliente_sobre_centro,
    melhor_ranking_centro,

    saldo_aberto_p75,
    saldo_aberto_p90,
    perc_centro_p75,
    perc_centro_p90,

    flag_top10_centro,
    flag_top5_centro,
    flag_perc_centro_acima_5,
    flag_perc_centro_acima_10,
    flag_saldo_acima_p75,
    flag_saldo_acima_p90,
    flag_concentracao_acima_p75,
    flag_concentracao_acima_p90,

    teste_04_concentracao_saldo_aberto_cliente,
    criticidade_teste_04,
    nivel_risco_teste_04,
    score_teste_04,
    impacto_esperado_teste_04

FROM resultado_teste_04

ORDER BY
    teste_04_concentracao_saldo_aberto_cliente DESC,
    criticidade_teste_04 DESC,
    saldo_total_aberto_cliente DESC,
    maior_perc_cliente_sobre_centro DESC;
