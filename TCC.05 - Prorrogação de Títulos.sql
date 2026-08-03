WITH parametros AS (
    SELECT
        DATE '2024-01-01' AS data_inicio,
        DATE '2025-12-31' AS data_fim,

        -- Critério mínimo para considerar múltiplas prorrogações.
        2 AS min_prorrogacoes_moderado,

        -- Critérios para risco alto.
        5 AS min_prorrogacoes_alto_cliente,
        3 AS min_prorrogacoes_alto_titulo,
        60 AS min_dias_prorrogados_alto
),

clientes_excluidos AS (
    SELECT '1000020903' AS id_cliente UNION ALL
    SELECT '1000016271' AS id_cliente UNION ALL
    SELECT '1000033486' AS id_cliente UNION ALL
    SELECT '1000017583' AS id_cliente
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

vendedores AS (
    SELECT
        KUNNR AS id_cliente,
        ANY_VALUE(CNAME) AS vendedor
    FROM
        `Portal_do_Vendedor.Clientes_x_Vendedores`
    GROUP BY
        KUNNR
),

universo_clientes AS (
    SELECT DISTINCT
        FIN.KUNNR AS id_cliente,
        COALESCE(CLI.nome_cliente, 'SEM CADASTRO') AS nome_cliente
    FROM 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bseg` AS FIN
    LEFT JOIN clientes AS CLI
        ON FIN.MANDT = CLI.MANDT
       AND FIN.KUNNR = CLI.id_cliente
    CROSS JOIN parametros AS P
    WHERE
        NULLIF(FIN.KUNNR, '') IS NOT NULL
        AND SAFE_CAST(FIN.KUNNR AS INT64) > 1000000000
        AND FIN.KUNNR NOT IN (SELECT id_cliente FROM clientes_excluidos)
        AND FIN.SHKZG = 'S'
        AND FIN.H_BLART = 'RV'
        AND SAFE_CAST(FIN.H_BUDAT AS DATE) BETWEEN P.data_inicio AND P.data_fim
),

alteracoes_brutas AS (
    SELECT DISTINCT
        FIN.MANDT,
        FIN.BUKRS AS empresa,
        FIN.BUPLA AS local_negocios,

        EMP.BUTXT AS nome_empresa,

        FIN.KUNNR AS id_cliente,
        COALESCE(CLI.nome_cliente, 'SEM CADASTRO') AS nome_cliente,
        VEN.vendedor,

        FIN.BELNR AS documento_contabil,
        FIN.GJAHR AS exercicio,
        FIN.BUZEI AS item_contabil,

        CONCAT(
            COALESCE(CAST(FIN.BUKRS AS STRING), ''),
            '|',
            COALESCE(CAST(FIN.GJAHR AS STRING), ''),
            '|',
            COALESCE(CAST(FIN.BELNR AS STRING), ''),
            '|',
            COALESCE(CAST(FIN.BUZEI AS STRING), '')
        ) AS chave_titulo,

        SAFE_CAST(FIN.DMBTR AS NUMERIC) AS valor_titulo,
        FIN.SGTXT AS descricao,
        FIN.H_BLART AS tipo_documento_contabil,
        SAFE_CAST(FIN.H_BUDAT AS DATE) AS data_lancamento,
        SAFE_CAST(FIN.AUGDT AS DATE) AS data_compensacao,
        SAFE_CAST(FIN.NETDT AS DATE) AS data_vencimento_atual,
        FIN.ZLSCH AS forma_pagamento,

        CDHDR.CHANGENR AS documento_alteracao,
        CDHDR.USERNAME AS usuario_alteracao,
        CDHDR.TCODE AS transacao,
        CDHDR.CHANGE_IND AS tipo_modificacao,
        CDPOS.FNAME AS campo_alterado,

        -- Conversão robusta da data de alteração.
        -- Caso o campo venha como YYYYMMDD, utiliza PARSE_DATE.
        -- Caso venha como DATE, utiliza SAFE_CAST.
        CASE
            WHEN REGEXP_CONTAINS(CAST(CDHDR.UDATE AS STRING), r'^[0-9]{8}$')
                THEN SAFE.PARSE_DATE('%Y%m%d', CAST(CDHDR.UDATE AS STRING))
            ELSE SAFE_CAST(CDHDR.UDATE AS DATE)
        END AS data_alteracao,

        -- Conversão do vencimento antigo.
        CASE
            WHEN REGEXP_CONTAINS(CAST(CDPOS.VALUE_OLD AS STRING), r'^[0-9]{8}$')
                THEN SAFE.PARSE_DATE('%Y%m%d', CAST(CDPOS.VALUE_OLD AS STRING))
            ELSE SAFE_CAST(CDPOS.VALUE_OLD AS DATE)
        END AS vencimento_antigo,

        -- Conversão do vencimento novo.
        CASE
            WHEN REGEXP_CONTAINS(CAST(CDPOS.VALUE_NEW AS STRING), r'^[0-9]{8}$')
                THEN SAFE.PARSE_DATE('%Y%m%d', CAST(CDPOS.VALUE_NEW AS STRING))
            ELSE SAFE_CAST(CDPOS.VALUE_NEW AS DATE)
        END AS vencimento_novo

    FROM        
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.bseg` AS FIN

    INNER JOIN 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.cdpos` AS CDPOS
            ON CONCAT(FIN.BUKRS, FIN.BELNR, FIN.GJAHR, FIN.BUZEI) = RIGHT(CDPOS.TABKEY, 21)

    INNER JOIN
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.cdhdr` AS CDHDR
            ON CDHDR.CHANGENR = CDPOS.CHANGENR 

    INNER JOIN 
        `production-servers-magnumtires.prdmgm_sap_cdc_processed.t001` AS EMP 
            ON EMP.BUKRS = FIN.BUKRS

    LEFT JOIN clientes AS CLI
        ON CLI.MANDT = FIN.MANDT
       AND CLI.id_cliente = FIN.KUNNR

    LEFT JOIN vendedores AS VEN
        ON VEN.id_cliente = FIN.KUNNR

    WHERE
        NULLIF(FIN.KUNNR, '') IS NOT NULL
        AND SAFE_CAST(FIN.KUNNR AS INT64) > 1000000000
        AND FIN.KUNNR NOT IN (SELECT id_cliente FROM clientes_excluidos)

        -- Filtros de negócio do teste.
        AND FIN.SHKZG = 'S'
        AND FIN.H_BLART = 'RV'

        -- Campo alterado: data base para pagamento.
        AND CDPOS.FNAME = 'ZFBDT'
        AND CDPOS.TABNAME = 'BSEG'
),

alteracoes_prorrogacao AS (
    SELECT
        A.*,

        DATE_DIFF(A.vencimento_novo, A.vencimento_antigo, DAY) AS dias_prorrogados,

        CASE 
            WHEN A.tipo_modificacao = 'U' THEN 'Atualização'
            WHEN A.tipo_modificacao = 'I' THEN 'Inserido'
            WHEN A.tipo_modificacao = 'D' THEN 'Deletado'
            ELSE 'Não classificado'
        END AS descricao_tipo_alteracao

    FROM alteracoes_brutas AS A
    CROSS JOIN parametros AS P
    WHERE
        A.data_alteracao BETWEEN P.data_inicio AND P.data_fim
        AND A.vencimento_antigo IS NOT NULL
        AND A.vencimento_novo IS NOT NULL

        -- FILTRO PRINCIPAL DO TESTE:
        -- considera apenas alterações em que o novo vencimento ficou posterior ao vencimento antigo,
        -- ou seja, houve prorrogação efetiva do título.
        AND DATE_DIFF(A.vencimento_novo, A.vencimento_antigo, DAY) > 0
),

prorrogacoes_unicas AS (
    SELECT
        empresa,
        local_negocios,
        nome_empresa,

        id_cliente,
        nome_cliente,
        vendedor,

        documento_contabil,
        exercicio,
        item_contabil,
        chave_titulo,

        documento_alteracao,
        usuario_alteracao,
        transacao,
        tipo_modificacao,
        descricao_tipo_alteracao,

        MIN(data_alteracao) AS data_alteracao,
        MIN(vencimento_antigo) AS vencimento_antigo,
        MAX(vencimento_novo) AS vencimento_novo,

        MAX(dias_prorrogados) AS dias_prorrogados,

        MAX(valor_titulo) AS valor_titulo,
        ANY_VALUE(descricao) AS descricao,
        ANY_VALUE(tipo_documento_contabil) AS tipo_documento_contabil,
        ANY_VALUE(data_lancamento) AS data_lancamento,
        ANY_VALUE(data_compensacao) AS data_compensacao,
        ANY_VALUE(data_vencimento_atual) AS data_vencimento_atual,
        ANY_VALUE(forma_pagamento) AS forma_pagamento

    FROM alteracoes_prorrogacao

    GROUP BY
        empresa,
        local_negocios,
        nome_empresa,
        id_cliente,
        nome_cliente,
        vendedor,
        documento_contabil,
        exercicio,
        item_contabil,
        chave_titulo,
        documento_alteracao,
        usuario_alteracao,
        transacao,
        tipo_modificacao,
        descricao_tipo_alteracao
),

prorrogacao_por_titulo AS (
    SELECT
        empresa,
        local_negocios,
        nome_empresa,

        id_cliente,
        nome_cliente,
        vendedor,

        documento_contabil,
        exercicio,
        item_contabil,
        chave_titulo,

        MAX(valor_titulo) AS valor_titulo,

        MIN(data_lancamento) AS data_lancamento,
        MAX(data_compensacao) AS data_compensacao,
        MAX(data_vencimento_atual) AS data_vencimento_atual,

        MIN(vencimento_antigo) AS primeiro_vencimento_identificado,
        MAX(vencimento_novo) AS ultimo_vencimento_identificado,

        COUNT(DISTINCT documento_alteracao) AS qtd_prorrogacoes_titulo,

        SUM(dias_prorrogados) AS dias_prorrogados_acumulados_titulo,

        MAX(dias_prorrogados) AS maior_prorrogacao_dias_titulo,

        COUNT(DISTINCT usuario_alteracao) AS qtd_usuarios_alteracao_titulo,

        STRING_AGG(DISTINCT usuario_alteracao, ', ') AS usuarios_alteracao_titulo,
        STRING_AGG(DISTINCT transacao, ', ') AS transacoes_utilizadas

    FROM prorrogacoes_unicas

    GROUP BY
        empresa,
        local_negocios,
        nome_empresa,
        id_cliente,
        nome_cliente,
        vendedor,
        documento_contabil,
        exercicio,
        item_contabil,
        chave_titulo
),

resumo_prorrogacoes_cliente AS (
    SELECT
        id_cliente,
        MAX(nome_cliente) AS nome_cliente,

        STRING_AGG(DISTINCT empresa, ', ') AS empresas_com_prorrogacao,
        STRING_AGG(DISTINCT local_negocios, ', ') AS locais_negocio_com_prorrogacao,
        STRING_AGG(DISTINCT vendedor, ', ') AS vendedores_relacionados,

        COUNT(DISTINCT chave_titulo) AS qtd_titulos_prorrogados_cliente,

        SUM(qtd_prorrogacoes_titulo) AS qtd_prorrogacoes_cliente,

        SUM(valor_titulo) AS valor_total_titulos_prorrogados,

        MAX(valor_titulo) AS maior_valor_titulo_prorrogado,

        MAX(qtd_prorrogacoes_titulo) AS maior_qtd_prorrogacoes_mesmo_titulo,

        SUM(dias_prorrogados_acumulados_titulo) AS dias_prorrogados_total_cliente,

        MAX(dias_prorrogados_acumulados_titulo) AS maior_dias_prorrogados_mesmo_titulo,

        MAX(maior_prorrogacao_dias_titulo) AS maior_prorrogacao_individual_dias,

        COUNT(DISTINCT usuarios_alteracao_titulo) AS qtd_grupos_usuarios_alteracao

    FROM prorrogacao_por_titulo

    GROUP BY
        id_cliente
),

resultado_teste_05_base AS (
    SELECT
        U.id_cliente,
        U.nome_cliente,

        COALESCE(R.empresas_com_prorrogacao, 'Sem ocorrência') AS empresas_com_prorrogacao,
        COALESCE(R.locais_negocio_com_prorrogacao, 'Sem ocorrência') AS locais_negocio_com_prorrogacao,
        COALESCE(R.vendedores_relacionados, 'Sem ocorrência') AS vendedores_relacionados,

        COALESCE(R.qtd_titulos_prorrogados_cliente, 0) AS qtd_titulos_prorrogados_cliente,
        COALESCE(R.qtd_prorrogacoes_cliente, 0) AS qtd_prorrogacoes_cliente,
        COALESCE(R.valor_total_titulos_prorrogados, 0) AS valor_total_titulos_prorrogados,
        COALESCE(R.maior_valor_titulo_prorrogado, 0) AS maior_valor_titulo_prorrogado,
        COALESCE(R.maior_qtd_prorrogacoes_mesmo_titulo, 0) AS maior_qtd_prorrogacoes_mesmo_titulo,
        COALESCE(R.dias_prorrogados_total_cliente, 0) AS dias_prorrogados_total_cliente,
        COALESCE(R.maior_dias_prorrogados_mesmo_titulo, 0) AS maior_dias_prorrogados_mesmo_titulo,
        COALESCE(R.maior_prorrogacao_individual_dias, 0) AS maior_prorrogacao_individual_dias,

        CASE
            WHEN COALESCE(R.qtd_prorrogacoes_cliente, 0) >= P.min_prorrogacoes_moderado
                THEN 1
            ELSE 0
        END AS flag_multiplas_prorrogacoes_cliente,

        CASE
            WHEN COALESCE(R.maior_qtd_prorrogacoes_mesmo_titulo, 0) >= P.min_prorrogacoes_moderado
                THEN 1
            ELSE 0
        END AS flag_multiplas_prorrogacoes_mesmo_titulo,

        CASE
            WHEN COALESCE(R.qtd_prorrogacoes_cliente, 0) >= P.min_prorrogacoes_alto_cliente
                THEN 1
            ELSE 0
        END AS flag_qtd_prorrogacoes_alta_cliente,

        CASE
            WHEN COALESCE(R.maior_qtd_prorrogacoes_mesmo_titulo, 0) >= P.min_prorrogacoes_alto_titulo
                THEN 1
            ELSE 0
        END AS flag_qtd_prorrogacoes_alta_titulo,

        CASE
            WHEN COALESCE(R.maior_dias_prorrogados_mesmo_titulo, 0) >= P.min_dias_prorrogados_alto
              OR COALESCE(R.maior_prorrogacao_individual_dias, 0) >= P.min_dias_prorrogados_alto
                THEN 1
            ELSE 0
        END AS flag_dias_prorrogados_relevante

    FROM universo_clientes AS U

    CROSS JOIN parametros AS P

    LEFT JOIN resumo_prorrogacoes_cliente AS R
        ON U.id_cliente = R.id_cliente
),

resultado_teste_05 AS (
    SELECT
        id_cliente,
        nome_cliente,

        empresas_com_prorrogacao,
        locais_negocio_com_prorrogacao,
        vendedores_relacionados,

        qtd_titulos_prorrogados_cliente,
        qtd_prorrogacoes_cliente,
        valor_total_titulos_prorrogados,
        maior_valor_titulo_prorrogado,
        maior_qtd_prorrogacoes_mesmo_titulo,
        dias_prorrogados_total_cliente,
        maior_dias_prorrogados_mesmo_titulo,
        maior_prorrogacao_individual_dias,

        flag_multiplas_prorrogacoes_cliente,
        flag_multiplas_prorrogacoes_mesmo_titulo,
        flag_qtd_prorrogacoes_alta_cliente,
        flag_qtd_prorrogacoes_alta_titulo,
        flag_dias_prorrogados_relevante,

        CASE
            WHEN flag_multiplas_prorrogacoes_cliente = 1
              OR flag_multiplas_prorrogacoes_mesmo_titulo = 1
                THEN 1
            ELSE 0
        END AS teste_05_multiplas_prorrogacoes_titulos,

        CASE
            WHEN flag_qtd_prorrogacoes_alta_cliente = 1
              OR flag_qtd_prorrogacoes_alta_titulo = 1
              OR flag_dias_prorrogados_relevante = 1
                THEN 2

            WHEN flag_multiplas_prorrogacoes_cliente = 1
              OR flag_multiplas_prorrogacoes_mesmo_titulo = 1
                THEN 1

            ELSE 0
        END AS criticidade_teste_05,

        CASE
            WHEN flag_qtd_prorrogacoes_alta_cliente = 1
              OR flag_qtd_prorrogacoes_alta_titulo = 1
              OR flag_dias_prorrogados_relevante = 1
                THEN 'Risco alto'

            WHEN flag_multiplas_prorrogacoes_cliente = 1
              OR flag_multiplas_prorrogacoes_mesmo_titulo = 1
                THEN 'Risco moderado'

            WHEN qtd_prorrogacoes_cliente = 1
                THEN 'Prorrogação isolada'

            ELSE 'Sem ocorrência'
        END AS nivel_risco_teste_05,

        CASE
            WHEN flag_qtd_prorrogacoes_alta_cliente = 1
              OR flag_qtd_prorrogacoes_alta_titulo = 1
              OR flag_dias_prorrogados_relevante = 1
                THEN 3

            WHEN flag_multiplas_prorrogacoes_cliente = 1
              OR flag_multiplas_prorrogacoes_mesmo_titulo = 1
                THEN 2

            ELSE 0
        END AS score_teste_05,

        'Alto' AS impacto_esperado_teste_05

    FROM resultado_teste_05_base
)

SELECT
    id_cliente,
    nome_cliente,

    empresas_com_prorrogacao,
    locais_negocio_com_prorrogacao,
    vendedores_relacionados,

    qtd_titulos_prorrogados_cliente,
    qtd_prorrogacoes_cliente,
    valor_total_titulos_prorrogados,
    maior_valor_titulo_prorrogado,
    maior_qtd_prorrogacoes_mesmo_titulo,
    dias_prorrogados_total_cliente,
    maior_dias_prorrogados_mesmo_titulo,
    maior_prorrogacao_individual_dias,

    flag_multiplas_prorrogacoes_cliente,
    flag_multiplas_prorrogacoes_mesmo_titulo,
    flag_qtd_prorrogacoes_alta_cliente,
    flag_qtd_prorrogacoes_alta_titulo,
    flag_dias_prorrogados_relevante,

    teste_05_multiplas_prorrogacoes_titulos,
    criticidade_teste_05,
    nivel_risco_teste_05,
    score_teste_05,
    impacto_esperado_teste_05

FROM resultado_teste_05

ORDER BY
    teste_05_multiplas_prorrogacoes_titulos DESC,
    criticidade_teste_05 DESC,
    qtd_prorrogacoes_cliente DESC,
    dias_prorrogados_total_cliente DESC,
    valor_total_titulos_prorrogados DESC;
