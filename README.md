<div align="center">

<h1>Projeto MBA USP/ESALQ</h1>

<h2>Desenvolvimento de modelo de risco de clientes para identificar anomalias na circularização em auditoria interna</h2>

</div>

<hr>

<h2>📌 Sobre o projeto</h2>

<p>
Este repositório reúne os códigos desenvolvidos para apoiar a construção de uma matriz analítica de clientes e a implementação de um algoritmo de Machine Learning voltado à priorização de clientes no processo de circularização em auditoria interna.
</p>

<p>
O projeto teve como base dados transacionais extraídos do ERP SAP, referentes aos anos de 2024 e 2025, posteriormente estruturados por meio de testes automatizados em SQL. A partir desses testes, foi construída uma matriz analítica consolidada por cliente, utilizada como entrada para a aplicação de um modelo não supervisionado de detecção de anomalias.
</p>

<p>
A finalidade do modelo não é confirmar fraude, erro ou irregularidade, mas identificar clientes com comportamento atípico e apoiar a auditoria interna na priorização dos casos que podem demandar maior atenção durante o processo de circularização.
</p>

<hr>

<h2>🎯 Objetivo</h2>

<p>
Implementar uma abordagem analítica para priorização de clientes na circularização em auditoria interna, combinando testes automatizados, score ponderado de auditoria e algoritmo de Machine Learning para detecção de anomalias.
</p>

<hr>

<h2>🧪 Testes automatizados de auditoria</h2>

<p>
A matriz analítica foi construída a partir de seis testes automatizados, desenvolvidos em SQL, cada um representando uma dimensão de risco relacionada ao processo de circularização de clientes.
</p>

<table>
  <thead>
    <tr>
      <th>Teste</th>
      <th>Descrição</th>
      <th>Dimensão de risco</th>
      <th>Arquivo</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>Teste_01</strong></td>
      <td>Títulos em aberto há mais de 30 dias</td>
      <td>Inadimplência e saldo vencido</td>
      <td><code>TCC.01 - Títulos em aberto a mais de 60 dias.sql</code></td>
    </tr>
    <tr>
      <td><strong>Teste_02</strong></td>
      <td>Cliente inadimplente na primeira compra</td>
      <td>Risco inicial de crédito</td>
      <td><code>TCC.02 - Clientes inadimplentes na primeira compra.sql</code></td>
    </tr>
    <tr>
      <td><strong>Teste_03</strong></td>
      <td>Alto volume de estornos financeiros</td>
      <td>Ajustes e reversões contábeis</td>
      <td><code>TCC.03 - Alto volume de estornos.sql</code></td>
    </tr>
    <tr>
      <td><strong>Teste_04</strong></td>
      <td>Concentração do saldo em aberto</td>
      <td>Materialidade e concentração</td>
      <td><code>TCC.04 - Concentração do aberto de clientes.sql</code></td>
    </tr>
    <tr>
      <td><strong>Teste_05</strong></td>
      <td>Múltiplas prorrogações de títulos</td>
      <td>Postergação de recebimentos</td>
      <td><code>TCC.05 - Prorrogação de Títulos.sql</code></td>
    </tr>
    <tr>
      <td><strong>Teste_06</strong></td>
      <td>Alto percentual de devolução</td>
      <td>Risco comercial e operacional</td>
      <td><code>TCC.06 - Alto percentual de Devolução.sql</code></td>
    </tr>
  </tbody>
</table>

<hr>

<h2>🤖 Algoritmo de Machine Learning</h2>

<p>
O algoritmo utilizado no projeto foi o <strong>Isolation Forest</strong>, uma técnica não supervisionada de Machine Learning voltada à detecção de anomalias.
</p>

<p>
A escolha por uma abordagem não supervisionada ocorreu porque não havia uma base histórica previamente validada com clientes classificados pela auditoria como anomalia confirmada, alto risco validado, fraude, erro ou irregularidade. Assim, o modelo foi utilizado para identificar comportamentos atípicos e gerar um ranking de priorização, sem substituir o julgamento profissional da auditoria.
</p>

<p>
As principais etapas do algoritmo foram:
</p>

<ol>
  <li>Leitura da matriz analítica consolidada;</li>
  <li>Identificação e tratamento de duplicidades por cliente;</li>
  <li>Consolidação da base em uma linha por <code>id_cliente</code>;</li>
  <li>Recalculo dos scores e indicadores de priorização;</li>
  <li>Separação das variáveis binárias, frequenciais, contínuas e ordinais;</li>
  <li>Tratamento de valores ausentes por mediana;</li>
  <li>Padronização das variáveis com <code>RobustScaler</code>;</li>
  <li>Aplicação do algoritmo <code>Isolation Forest</code>;</li>
  <li>Geração do score de anomalia;</li>
  <li>Classificação dos clientes atípicos;</li>
  <li>Criação do ranking de priorização.</li>
</ol>

<hr>

<h2>📊 Estrutura da matriz analítica</h2>

<p>
A matriz final foi composta por diferentes tipos de variáveis, permitindo que o modelo considerasse não apenas a existência de um indício, mas também sua intensidade, recorrência, materialidade e criticidade.
</p>

<table>
  <thead>
    <tr>
      <th>Tipo de variável</th>
      <th>Descrição</th>
      <th>Exemplos</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><strong>Binária</strong></td>
      <td>Indica presença ou ausência do indício</td>
      <td><code>teste_01</code>, <code>teste_02</code>, <code>teste_03</code></td>
    </tr>
    <tr>
      <td><strong>Frequencial</strong></td>
      <td>Mede quantidade de ocorrências</td>
      <td>Quantidade de estornos, títulos vencidos e devoluções</td>
    </tr>
    <tr>
      <td><strong>Contínua</strong></td>
      <td>Mede valores, percentuais e prazos</td>
      <td>Valor em aberto, valor de estornos e dias em atraso</td>
    </tr>
    <tr>
      <td><strong>Ordinal</strong></td>
      <td>Representa níveis de criticidade</td>
      <td>Criticidade do teste e score ponderado</td>
    </tr>
  </tbody>
</table>

<hr>

<h2>📈 Resultados gerais do modelo</h2>

<table>
  <thead>
    <tr>
      <th>Indicador</th>
      <th>Resultado</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Linhas originais da matriz</td>
      <td>213.981</td>
    </tr>
    <tr>
      <td>Clientes únicos após consolidação</td>
      <td>199.989</td>
    </tr>
    <tr>
      <td>Linhas reduzidas por consolidação</td>
      <td>13.992</td>
    </tr>
    <tr>
      <td>Clientes com pelo menos um indício</td>
      <td>26.035</td>
    </tr>
    <tr>
      <td>Variáveis utilizadas no modelo</td>
      <td>50</td>
    </tr>
    <tr>
      <td>Clientes classificados como atípicos</td>
      <td>10.000</td>
    </tr>
    <tr>
      <td>Percentual de clientes atípicos</td>
      <td>5,00%</td>
    </tr>
  </tbody>
</table>

<hr>

<h2>🛠️ Tecnologias utilizadas</h2>

<ul>
  <li><strong>SQL</strong> — construção dos testes automatizados de auditoria;</li>
  <li><strong>BigQuery</strong> — processamento e extração dos dados;</li>
  <li><strong>Python</strong> — tratamento da matriz analítica e implementação do algoritmo;</li>
  <li><strong>Pandas</strong> — manipulação e consolidação dos dados;</li>
  <li><strong>Scikit-learn</strong> — aplicação do Isolation Forest e pré-processamento;</li>
  <li><strong>Matplotlib</strong> — geração de gráficos de apoio à análise.</li>
</ul>

<hr>

<h2>📁 Estrutura do repositório</h2>

<pre>
Projeto_MBA_USP_ESALQ/
│
├── README.md
├── TCC.01 - Títulos em aberto a mais de 60 dias.sql
├── TCC.02 - Clientes inadimplentes na primeira compra.sql
├── TCC.03 - Alto volume de estornos.sql
├── TCC.04 - Concentração do aberto de clientes.sql
├── TCC.05 - Prorrogação de Títulos.sql
├── TCC.06 - Alto percentual de Devolução.sql
│
└── /algoritmo_machine_learning/
    ├── algoritmo_ml_tcc_consolidado_v4.py
    ├── TCC_matriz_analitica_e_modelo.csv
    ├── TCC_matriz_com_modelo_v4.csv
    ├── TCC_resumo_modelo_v4.xlsx
    └── /tcc_model_outputs_v4/
</pre>

<hr>

<h2>⚠️ Observações metodológicas</h2>

<ul>
  <li>O modelo não teve como objetivo confirmar fraude, erro ou irregularidade.</li>
  <li>A classificação de cliente atípico indicou apenas prioridade analítica para avaliação da auditoria.</li>
  <li>A ausência de uma base histórica rotulada justificou a escolha por uma abordagem não supervisionada.</li>
  <li>A consolidação da base foi realizada por <code>id_cliente</code>, evitando duplicidade de observações no modelo.</li>
  <li>A consolidação por CNPJ raiz poderá ser avaliada em etapa futura, caso essa informação seja incorporada à matriz.</li>
</ul>

<hr>

<h2>📚 Referências principais</h2>

<ul>
  <li>FÁVERO, Luiz Paulo; BELFIORE, Patrícia. <strong>Manual de análise de dados: estatística e machine learning com Excel®, SPSS®, Stata®, R® e Python®</strong>. 2. ed. Rio de Janeiro: LTC, 2025.</li>
  <li>LIU, Fei Tony; TING, Kai Ming; ZHOU, Zhi-Hua. <strong>Isolation Forest</strong>. In: 2008 Eighth IEEE International Conference on Data Mining. IEEE, 2008. p. 413-422.</li>
  <li>PEDREGOSA, Fabian et al. <strong>Scikit-learn: Machine Learning in Python</strong>. Journal of Machine Learning Research, v. 12, p. 2825-2830, 2011.</li>
</ul>

<hr>

<h2>👨‍💻 Autor</h2>

<p>
<strong>Matheus Henrique de Melo Oliveira</strong><br>
MBA USP/ESALQ em Data Science e Analytics<br>
Projeto aplicado à Auditoria Interna
</p>

<hr>

<div align="center">

<p>
  <strong>Projeto desenvolvido para fins acadêmicos no âmbito do Trabalho de Conclusão de Curso do MBA USP/ESALQ.</strong>
</p>

</div>
