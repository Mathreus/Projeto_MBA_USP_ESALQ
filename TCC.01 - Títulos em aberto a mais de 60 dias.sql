DECLARE data_referencia DATE DEFAULT DATE '2025-12-31';
DECLARE data_inicio DATE DEFAULT DATE '2024-01-01';
DECLARE data_fim DATE DEFAULT DATE '2025-12-31';
DECLARE dias_corte INT64 DEFAULT 30;

WITH universo_clientes AS (
    SELECT DISTINCT
        B.BUKRS AS centro,
        B.KUNNR AS id_cliente,
        CAD.NAME1 AS nome_cliente
    FROM 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bseg` AS B
    INNER JOIN 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.kna1` AS CAD
            ON B.MANDT = CAD.MANDT
           AND B.KUNNR = CAD.KUNNR
    WHERE
        NULLIF(B.KUNNR, '') IS NOT NULL
        AND B.KUNNR NOT IN ('1000020903', '1000016271', '1000033486', '1000017583', '1000002790', '1000300196', '1000016115',
        '1000033858', '1000033859', '1000033864', '1000033867', '1000033871', '1000033874', '1000033875', '1000033876', '1000033877', '1000033883',
        '1000033885', '1000033887', '1000033893', '1000033900', '1000046889', '1000132331', '1000132642', '6000081629', '6000081632')
        AND SAFE_CAST(B.KUNNR AS INT64) > 1000000000
        AND SAFE_CAST(B.H_BUDAT AS DATE) BETWEEN data_inicio AND data_fim
),

base_titulos AS (
    SELECT DISTINCT
        AB.BUKRS AS centro,
        AB.KUNNR AS id_cliente,
        CAD.NAME1 AS nome_cliente,

        SAFE_CAST(AB.BUDAT AS DATE) AS data_lancamento,
        SAFE_CAST(AB.AUGDT AS DATE) AS data_compensacao,

        AB.BELNR AS documento,
        AB.GJAHR AS exercicio,
        AB.BUZEI AS parcela,

        AB.BLART AS tipo_documento,
        AB.ZLSCH AS forma_pagamento,
        AB.SHKZG AS indicador_debito_credito,

        COALESCE(
            SAFE_CAST(AB.ZFBDT AS DATE),
            SAFE_CAST(AB.BUDAT AS DATE)
        ) AS data_base_vencimento,

        COALESCE(SAFE_CAST(AB.ZBD1T AS INT64), 0) AS dias_condicao_pagamento,

        DATE_ADD(
            COALESCE(
                SAFE_CAST(AB.ZFBDT AS DATE),
                SAFE_CAST(AB.BUDAT AS DATE)
            ),
            INTERVAL COALESCE(SAFE_CAST(AB.ZBD1T AS INT64), 0) DAY
        ) AS data_vencimento,

        data_referencia AS data_referencia,

        DATE_DIFF(
            data_referencia,
            DATE_ADD(
                COALESCE(
                    SAFE_CAST(AB.ZFBDT AS DATE),
                    SAFE_CAST(AB.BUDAT AS DATE)
                ),
                INTERVAL COALESCE(SAFE_CAST(AB.ZBD1T AS INT64), 0) DAY
            ),
            DAY
        ) AS dias_vencido,

        SAFE_CAST(AB.DMBTR AS NUMERIC) AS valor_titulo

    FROM 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bsid` AS AB
    INNER JOIN 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.kna1` AS CAD
            ON AB.MANDT = CAD.MANDT
           AND AB.KUNNR = CAD.KUNNR
    WHERE 
        NULLIF(AB.KUNNR, '') IS NOT NULL
        AND AB.KUNNR NOT IN ('1000020903', '1000016271', '1000033486', '1000017583')
        AND SAFE_CAST(AB.KUNNR AS INT64) > 1000000000
        AND AB.SHKZG = 'S'
        AND AB.BLART = 'RV'
        AND SAFE_CAST(AB.BUDAT AS DATE) BETWEEN data_inicio AND data_fim
),

ocorrencias_teste_01 AS (
    SELECT
        *,
        CASE
            WHEN dias_vencido <= 0 THEN 'A vencer'
            WHEN dias_vencido <= 30 THEN '1 a 30 dias'
            WHEN dias_vencido <= 60 THEN '31 a 60 dias'
            WHEN dias_vencido <= 90 THEN '61 a 90 dias'
            WHEN dias_vencido <= 120 THEN '91 a 120 dias'
            WHEN dias_vencido <= 180 THEN '121 a 180 dias'
            WHEN dias_vencido <= 360 THEN '181 a 360 dias'
            WHEN dias_vencido <= 720 THEN '361 a 720 dias'
            ELSE 'Acima de 720 dias'
        END AS faixa_aging
    FROM base_titulos
    WHERE dias_vencido > dias_corte
)

SELECT
    U.centro,
    U.id_cliente,
    U.nome_cliente,

    CASE
        WHEN COUNT(O.documento) > 0 THEN 1
        ELSE 0
    END AS teste_01_titulos_vencidos_abertos_mais_30_dias,

    COUNT(
        DISTINCT CONCAT(
            COALESCE(CAST(O.centro AS STRING), ''),
            '|',
            COALESCE(CAST(O.exercicio AS STRING), ''),
            '|',
            COALESCE(CAST(O.documento AS STRING), ''),
            '|',
            COALESCE(CAST(O.parcela AS STRING), '')
        )
    ) AS qtd_titulos_vencidos_abertos_30d,

    COALESCE(SUM(ABS(O.valor_titulo)), 0) AS valor_total_titulos_vencidos_abertos_30d,

    COALESCE(MAX(O.dias_vencido), 0) AS maior_dias_vencido_teste_01,

    CASE
        WHEN COALESCE(MAX(O.dias_vencido), 0) = 0 THEN 'Sem ocorrência'
        WHEN COALESCE(MAX(O.dias_vencido), 0) <= 60 THEN '31 a 60 dias'
        WHEN COALESCE(MAX(O.dias_vencido), 0) <= 90 THEN '61 a 90 dias'
        WHEN COALESCE(MAX(O.dias_vencido), 0) <= 120 THEN '91 a 120 dias'
        WHEN COALESCE(MAX(O.dias_vencido), 0) <= 180 THEN '121 a 180 dias'
        WHEN COALESCE(MAX(O.dias_vencido), 0) <= 360 THEN '181 a 360 dias'
        WHEN COALESCE(MAX(O.dias_vencido), 0) <= 720 THEN '361 a 720 dias'
        ELSE 'Acima de 720 dias'
    END AS faixa_maior_aging_teste_01,

    'Alto' AS impacto_esperado_teste_01,

    CASE
        WHEN COUNT(O.documento) > 0 THEN 3
        ELSE 0
    END AS score_teste_01

FROM universo_clientes AS U

LEFT JOIN ocorrencias_teste_01 AS O
    ON U.centro = O.centro
   AND U.id_cliente = O.id_cliente

GROUP BY
    U.centro,
    U.id_cliente,
    U.nome_cliente

ORDER BY
    teste_01_titulos_vencidos_abertos_mais_30_dias DESC,
    score_teste_01 DESC,
    valor_total_titulos_vencidos_abertos_30d DESC,
    maior_dias_vencido_teste_01 DESC;
