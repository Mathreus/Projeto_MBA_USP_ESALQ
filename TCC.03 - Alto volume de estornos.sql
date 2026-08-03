WITH parametros AS (
    SELECT
        DATE '2024-01-01' AS data_inicio,
        DATE '2025-12-31' AS data_fim
),

clientes_excluidos AS (
    SELECT '1000020903' AS id_cliente UNION ALL
    SELECT '1000016271' AS id_cliente UNION ALL
    SELECT '1000033486' AS id_cliente UNION ALL
    SELECT '1000017583' AS id_cliente
),

universo_clientes AS (
    SELECT DISTINCT
        FIN.KUNNR AS id_cliente,
        CLI.NAME1 AS nome_cliente
    FROM
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bseg` AS FIN
    INNER JOIN
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.kna1` AS CLI
            ON FIN.MANDT = CLI.MANDT
           AND FIN.KUNNR = CLI.KUNNR
    CROSS JOIN parametros AS P
    WHERE
        NULLIF(FIN.KUNNR, '') IS NOT NULL
        AND SAFE_CAST(FIN.KUNNR AS INT64) > 1000000000
        AND FIN.KUNNR NOT IN (SELECT id_cliente FROM clientes_excluidos)
        AND SAFE_CAST(FIN.H_BUDAT AS DATE) BETWEEN P.data_inicio AND P.data_fim
),

base_estornos AS (
    SELECT
        FIN.MANDT,
        FIN.BUKRS AS empresa,
        FIN.KUNNR AS id_cliente,
        CLI.NAME1 AS nome_cliente,

        FIN.GJAHR AS exercicio_documento,
        FIN.BELNR AS documento,
        FAT.AWREF_REV AS documento_referenciado_estorno,

        SAFE_CAST(FAT.BLDAT AS DATE) AS data_documento,
        SAFE_CAST(FIN.H_BLDAT AS DATE) AS data_lancamento,

        FAT.USNAM AS usuario,
        FAT.XREVERSING AS flag_documento_estorno,

        FIN.HKONT AS conta_contabil,
        FIN.BUZEI AS item_documento,
        FIN.SHKZG AS indicador_debito_credito,

        SAFE_CAST(FIN.DMBTR AS NUMERIC) AS valor_parcela

    FROM
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bseg` AS FIN

    LEFT JOIN
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bkpf` AS FAT
            ON FIN.MANDT = FAT.MANDT
           AND FIN.BUKRS = FAT.BUKRS
           AND FIN.BELNR = FAT.BELNR
           AND FIN.GJAHR = FAT.GJAHR

    LEFT JOIN
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.kna1` AS CLI
            ON FIN.MANDT = CLI.MANDT
           AND FIN.KUNNR = CLI.KUNNR

    CROSS JOIN parametros AS P

    WHERE
        NULLIF(FIN.KUNNR, '') IS NOT NULL
        AND SAFE_CAST(FIN.KUNNR AS INT64) > 1000000000
        AND FIN.KUNNR NOT IN (SELECT id_cliente FROM clientes_excluidos)

        -- Período analisado para identificação dos estornos.
        AND SAFE_CAST(FAT.BLDAT AS DATE) BETWEEN P.data_inicio AND P.data_fim

        -- Conta contábil analisada no teste de estornos.
        AND FIN.HKONT = '1010201001'

        -- Filtro principal do teste:
        -- identifica documentos marcados como documentos de estorno.
        AND FAT.XREVERSING = 'X'

        -- Garante que o documento de estorno possui referência ao documento original.
        AND NULLIF(FAT.AWREF_REV, '') IS NOT NULL
),

documentos_estorno_agrupados AS (
    SELECT
        empresa,
        id_cliente,
        nome_cliente,
        exercicio_documento,
        documento,
        documento_referenciado_estorno,

        MIN(data_documento) AS data_documento,
        MIN(data_lancamento) AS data_lancamento,

        STRING_AGG(DISTINCT usuario, ', ') AS usuarios_envolvidos,

        COUNT(DISTINCT item_documento) AS qtd_itens_documento,

        SUM(ABS(valor_parcela)) AS valor_documento

    FROM base_estornos

    GROUP BY
        empresa,
        id_cliente,
        nome_cliente,
        exercicio_documento,
        documento,
        documento_referenciado_estorno
),

pares_normalizados AS (
    SELECT
        empresa,
        id_cliente,
        nome_cliente,
        exercicio_documento,

        documento,
        documento_referenciado_estorno,

        data_documento,
        data_lancamento,
        usuarios_envolvidos,
        qtd_itens_documento,
        valor_documento,

        -- Normalização do par de estorno:
        -- evita duplicidade caso o documento A referencie B e o documento B referencie A.
        LEAST(documento, documento_referenciado_estorno) AS documento_par_a,
        GREATEST(documento, documento_referenciado_estorno) AS documento_par_b,

        CONCAT(
            empresa,
            '|',
            exercicio_documento,
            '|',
            LEAST(documento, documento_referenciado_estorno),
            '|',
            GREATEST(documento, documento_referenciado_estorno)
        ) AS chave_par_estorno

    FROM documentos_estorno_agrupados
),

estornos_unicos AS (
    SELECT
        empresa,
        id_cliente,
        nome_cliente,
        exercicio_documento,

        documento_par_a,
        documento_par_b,
        chave_par_estorno,

        MIN(data_documento) AS data_primeiro_registro,
        MAX(data_documento) AS data_ultimo_registro,

        STRING_AGG(DISTINCT documento, ', ') AS documentos_encontrados,
        STRING_AGG(DISTINCT documento_referenciado_estorno, ', ') AS documentos_referenciados,
        STRING_AGG(DISTINCT usuarios_envolvidos, ', ') AS usuarios_envolvidos,

        COUNT(DISTINCT documento) AS qtd_pernas_encontradas,

        -- Valor sem duplicidade:
        -- utiliza o maior valor encontrado para o par, evitando somar original + estorno.
        MAX(valor_documento) AS valor_estorno_sem_duplicidade,

        -- Campo de conferência, não deve ser usado como valor principal do modelo.
        SUM(valor_documento) AS valor_somado_das_pernas,

        MIN(valor_documento) AS menor_valor_perna,
        MAX(valor_documento) AS maior_valor_perna,

        ABS(MAX(valor_documento) - MIN(valor_documento)) AS diferenca_valor_entre_pernas,

        CASE
            WHEN COUNT(DISTINCT documento) = 2 THEN 'Duas pernas localizadas'
            WHEN COUNT(DISTINCT documento) = 1 THEN 'Apenas uma perna localizada'
            ELSE 'Não classificado'
        END AS status_relacao_estorno

    FROM pares_normalizados

    GROUP BY
        empresa,
        id_cliente,
        nome_cliente,
        exercicio_documento,
        documento_par_a,
        documento_par_b,
        chave_par_estorno
),

resumo_estornos_cliente AS (
    SELECT
        id_cliente,
        MAX(nome_cliente) AS nome_cliente,

        STRING_AGG(DISTINCT empresa, ', ') AS empresas_com_estorno,

        COUNT(DISTINCT chave_par_estorno) AS qtd_estornos_cliente,

        SUM(valor_estorno_sem_duplicidade) AS valor_total_estornos_cliente,

        MAX(valor_estorno_sem_duplicidade) AS maior_valor_estorno_cliente,

        MIN(data_primeiro_registro) AS data_primeiro_estorno_cliente,

        MAX(data_ultimo_registro) AS data_ultimo_estorno_cliente,

        COUNT(DISTINCT usuarios_envolvidos) AS qtd_usuarios_estorno,

        COUNTIF(status_relacao_estorno = 'Duas pernas localizadas') AS qtd_estornos_duas_pernas_localizadas,

        COUNTIF(status_relacao_estorno = 'Apenas uma perna localizada') AS qtd_estornos_uma_perna_localizada

    FROM estornos_unicos

    GROUP BY
        id_cliente
),

limiares_estornos AS (
    SELECT
        COALESCE(APPROX_QUANTILES(qtd_estornos_cliente, 100)[OFFSET(75)], 0) AS qtd_estornos_p75,
        COALESCE(APPROX_QUANTILES(qtd_estornos_cliente, 100)[OFFSET(90)], 0) AS qtd_estornos_p90,

        COALESCE(APPROX_QUANTILES(valor_total_estornos_cliente, 100)[OFFSET(75)], 0) AS valor_estornos_p75,
        COALESCE(APPROX_QUANTILES(valor_total_estornos_cliente, 100)[OFFSET(90)], 0) AS valor_estornos_p90
    FROM resumo_estornos_cliente
    WHERE qtd_estornos_cliente > 0
),

resultado_teste_03_base AS (
    SELECT
        U.id_cliente,
        U.nome_cliente,

        COALESCE(R.empresas_com_estorno, 'Sem ocorrência') AS empresas_com_estorno,

        COALESCE(R.qtd_estornos_cliente, 0) AS qtd_estornos_cliente,
        COALESCE(R.valor_total_estornos_cliente, 0) AS valor_total_estornos_cliente,
        COALESCE(R.maior_valor_estorno_cliente, 0) AS maior_valor_estorno_cliente,

        R.data_primeiro_estorno_cliente,
        R.data_ultimo_estorno_cliente,

        COALESCE(R.qtd_usuarios_estorno, 0) AS qtd_usuarios_estorno,

        COALESCE(R.qtd_estornos_duas_pernas_localizadas, 0) AS qtd_estornos_duas_pernas_localizadas,
        COALESCE(R.qtd_estornos_uma_perna_localizada, 0) AS qtd_estornos_uma_perna_localizada,

        L.qtd_estornos_p75,
        L.qtd_estornos_p90,
        L.valor_estornos_p75,
        L.valor_estornos_p90,

        CASE
            WHEN COALESCE(R.qtd_estornos_cliente, 0) > 0
                 AND COALESCE(R.qtd_estornos_cliente, 0) >= L.qtd_estornos_p75
                THEN 1
            ELSE 0
        END AS flag_alta_quantidade_estornos,

        CASE
            WHEN COALESCE(R.valor_total_estornos_cliente, 0) > 0
                 AND COALESCE(R.valor_total_estornos_cliente, 0) >= L.valor_estornos_p75
                THEN 1
            ELSE 0
        END AS flag_alto_valor_estornos,

        CASE
            WHEN COALESCE(R.qtd_estornos_cliente, 0) > 0
                 AND COALESCE(R.qtd_estornos_cliente, 0) >= L.qtd_estornos_p90
                THEN 1
            ELSE 0
        END AS flag_quantidade_estornos_muito_alta,

        CASE
            WHEN COALESCE(R.valor_total_estornos_cliente, 0) > 0
                 AND COALESCE(R.valor_total_estornos_cliente, 0) >= L.valor_estornos_p90
                THEN 1
            ELSE 0
        END AS flag_valor_estornos_muito_alto

    FROM universo_clientes AS U

    CROSS JOIN limiares_estornos AS L

    LEFT JOIN resumo_estornos_cliente AS R
        ON U.id_cliente = R.id_cliente
),

resultado_teste_03 AS (
    SELECT
        id_cliente,
        nome_cliente,

        empresas_com_estorno,

        qtd_estornos_cliente,
        valor_total_estornos_cliente,
        maior_valor_estorno_cliente,

        data_primeiro_estorno_cliente,
        data_ultimo_estorno_cliente,

        qtd_usuarios_estorno,

        qtd_estornos_duas_pernas_localizadas,
        qtd_estornos_uma_perna_localizada,

        qtd_estornos_p75,
        qtd_estornos_p90,
        valor_estornos_p75,
        valor_estornos_p90,

        flag_alta_quantidade_estornos,
        flag_alto_valor_estornos,
        flag_quantidade_estornos_muito_alta,
        flag_valor_estornos_muito_alto,

        CASE
            WHEN flag_alta_quantidade_estornos = 1
              OR flag_alto_valor_estornos = 1
                THEN 1
            ELSE 0
        END AS teste_03_alto_volume_estornos_financeiros,

        CASE
            WHEN flag_quantidade_estornos_muito_alta = 1
              OR flag_valor_estornos_muito_alto = 1
                THEN 2
            WHEN flag_alta_quantidade_estornos = 1
              OR flag_alto_valor_estornos = 1
                THEN 1
            ELSE 0
        END AS criticidade_teste_03,

        CASE
            WHEN flag_quantidade_estornos_muito_alta = 1
              OR flag_valor_estornos_muito_alto = 1
                THEN 'Risco alto'
            WHEN flag_alta_quantidade_estornos = 1
              OR flag_alto_valor_estornos = 1
                THEN 'Risco moderado'
            WHEN qtd_estornos_cliente > 0
                THEN 'Estornos abaixo do limiar de alto volume'
            ELSE 'Sem ocorrência'
        END AS nivel_risco_teste_03,

        CASE
            WHEN flag_quantidade_estornos_muito_alta = 1
              OR flag_valor_estornos_muito_alto = 1
                THEN 3
            WHEN flag_alta_quantidade_estornos = 1
              OR flag_alto_valor_estornos = 1
                THEN 2
            ELSE 0
        END AS score_teste_03,

        'Alto' AS impacto_esperado_teste_03

    FROM resultado_teste_03_base
)

SELECT
    id_cliente,
    nome_cliente,

    empresas_com_estorno,

    qtd_estornos_cliente,
    valor_total_estornos_cliente,
    maior_valor_estorno_cliente,

    data_primeiro_estorno_cliente,
    data_ultimo_estorno_cliente,

    qtd_usuarios_estorno,

    qtd_estornos_duas_pernas_localizadas,
    qtd_estornos_uma_perna_localizada,

    qtd_estornos_p75,
    qtd_estornos_p90,
    valor_estornos_p75,
    valor_estornos_p90,

    flag_alta_quantidade_estornos,
    flag_alto_valor_estornos,
    flag_quantidade_estornos_muito_alta,
    flag_valor_estornos_muito_alto,

    teste_03_alto_volume_estornos_financeiros,
    criticidade_teste_03,
    nivel_risco_teste_03,
    score_teste_03,
    impacto_esperado_teste_03

FROM resultado_teste_03

ORDER BY
    teste_03_alto_volume_estornos_financeiros DESC,
    criticidade_teste_03 DESC,
    valor_total_estornos_cliente DESC,
    qtd_estornos_cliente DESC;
