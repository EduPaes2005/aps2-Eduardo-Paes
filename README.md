# Dossiê de Arquitetura Viva e Modelagem Comportamental as-Code
**Projeto:** Plataforma de Gestão de Estágios UniSENAI  
**Funcionalidade Crítica:** Algoritmo de Conciliação (*Match*) de Competências  
**Autor:** Eduardo Luciano Paes  

---

## 1. Contextualização da Funcionalidade Crítica
O **Algoritmo de Conciliação (Match) de Competências** é o núcleo decisório da Plataforma de Gestão de Estágios do UniSENAI. Sua responsabilidade é cruzar, de forma auditável e semântica, a matriz de requisitos técnicos (*Hard Skills*) e comportamentais (*Soft Skills*) exigidos por uma vaga de estágio com o histórico acadêmico oficial (validado junto ao SGA UniSENAI) e o portfólio prático dos estudantes.

Para evitar a **Deriva Arquitetural (*Architectural Drift*)**, toda a especificação comportamental e estrutural deste módulo é mantida sob o paradigma *Diagrams-as-Code (DaC)* e *Models-as-Code (MaC)*.

---

## 2. Contrato de Classes/Interfaces e Matriz de Consistência (Regra de Consistência)
Em conformidade com a regra de consistência da UML, todas as mensagens trafegadas no **Diagrama de Sequência** correspondem estritamente a operações públicas declaradas nas interfaces do sistema e respeitam as guardas do **Diagrama de Atividades** e as transições da **Máquina de Estados**:

| Linha de Vida / Componente | Operação Pública Declarada (Assinatura) | Entrada (DTO / Parâmetros) | Retorno / Efeito | Correspondência na Máquina de Estados |
| :--- | :--- | :--- | :--- | :--- |
| `MatchController` | `+ solicitarConciliacao()` | `SolicitacaoMatchDTO` | `RelatorioConciliacaoVagaDTO` | Transição `[*] --> Recebida` |
| `MatchEngineService` | `+ executarConciliacaoVaga()` | `SolicitacaoMatchDTO` | `RelatorioConciliacaoVagaDTO` | Transição `Recebida --> EmConciliacao` |
| `SgaIntegrationAdapter` | `+ validarSituacaoAcademica()` | `raEstudante: string` | `HistoricoAcademicoDTO` ou `ErroValidacaoAcademicaDTO` | Subestado `ValidandoElegibilidadeSGA` |
| `CompetenciaRepository` | `+ buscarRequisitosVaga()` | `vagaId: UUID` | `VagaCompetenciasDTO` | Subestado `CalculandoVetoresCompetencia` |
| `CompetenciaRepository` | `+ listarCandidatosPreElegiveis()` | `cursoId: UUID, semestreMinimo: int` | `List<CandidatoBaseDTO>` | Filtro relacional inicial |
| `CompetenciaRepository` | `+ calcularSimilaridadeVetorial()` | `VagaCompetenciasDTO, HistoricoAcademicoDTO` | `ResultadoScoreDTO` | Subestado `PonderandoScoreFinal` |
| `CompetenciaRepository` | `+ salvarResultadoMatch()` | `MatchConsolidadoDTO` | `MatchPersistidoDTO` | Transição `EmConciliacao --> AptaParaEntrevista` |
| `CompetenciaRepository` | `+ registrarRetencaoTalento()` | `MatchConsolidadoDTO` | `MatchPersistidoDTO` | Transição `EmConciliacao --> RetidaBancoTalentos` |
| `EventBrokerPublisher` | `+ publicarEventoMatchAprovado()` | `EventoMatchConcluidoDTO` | *Assíncrono (AMQP)* | Efeito `/ emitirEventoMatchAprovado()` |
| `EventBrokerPublisher` | `+ publicarSugestaoTrilhaCapacitacao()` | `EventoGapCompetenciaDTO` | *Assíncrono (AMQP)* | Efeito `/ gerarDiagnosticoGaps()` |
| `EventBrokerPublisher` | `+ publicarAlertaInconsistenciaSGA()` | `EventoAuditoriaErroDTO` | *Assíncrono (AMQP)* | Transição `--> FalhaIntegracaoExterna` |

---

## 3. Artefato 1 — Diagrama de Sequência (`docs/diagrams/sequencia.mmd`)

Mapeia a interação cronológica em tempo de execução, destacando chamadas síncronas bloqueantes (`->>`), retornos com DTOs (`-->>`), chamadas assíncronas via RabbitMQ (`-)`) e fragmentos combinados (`loop` e `alt/else`).

```mermaid
sequenceDiagram
    autonumber
    actor Recrutador as Recrutador / Empresa
    participant API as MatchController
    participant Engine as MatchEngineService
    participant SGA as SgaIntegrationAdapter
    participant Repo as CompetenciaRepository
    participant Broker as EventBrokerPublisher

    Recrutador->>API: solicitarConciliacao(SolicitacaoMatchDTO)
    activate API
    API->>Engine: executarConciliacaoVaga(SolicitacaoMatchDTO)
    activate Engine

    Engine->>Repo: buscarRequisitosVaga(vagaId)
    activate Repo
    Repo-->>Engine: VagaCompetenciasDTO
    deactivate Repo

    Engine->>Repo: listarCandidatosPreElegiveis(cursoId, semestreMinimo)
    activate Repo
    Repo-->>Engine: List~CandidatoBaseDTO~
    deactivate Repo

    loop Para cada CandidatoBaseDTO na lista de pré-elegíveis
        Engine->>SGA: validarSituacaoAcademica(raEstudante)
        activate SGA

        alt Matrícula ativa e frequência regular no SGA
            SGA-->>Engine: HistoricoAcademicoDTO (ativo=true, freq>=75%)
            deactivate SGA

            Engine->>Repo: calcularSimilaridadeVetorial(VagaCompetenciasDTO, HistoricoAcademicoDTO)
            activate Repo
            Repo-->>Engine: ResultadoScoreDTO (scoreHardSkills, scoreSoftSkills, scoreFinal)
            deactivate Repo

            alt scoreFinal >= 70.0 (Candidato Apto para a Vaga)
                Engine->>Repo: salvarResultadoMatch(MatchConsolidadoDTO)
                activate Repo
                Repo-->>Engine: MatchPersistidoDTO (status="APTO_ENTREVISTA")
                deactivate Repo

                Engine-)Broker: publicarEventoMatchAprovado(EventoMatchConcluidoDTO)
                Note right of Broker: Mensageria Assíncrona (RabbitMQ)<br/>Dispara notificação ao aluno e log de auditoria
            else scoreFinal < 70.0 (Retido no Banco de Talentos)
                Engine->>Repo: registrarRetencaoTalento(MatchConsolidadoDTO)
                activate Repo
                Repo-->>Engine: MatchPersistidoDTO (status="RETIDO_BANCO_TALENTOS")
                deactivate Repo

                Engine-)Broker: publicarSugestaoTrilhaCapacitacao(EventoGapCompetenciaDTO)
            end

        else Matrícula inativa ou falha de timeout no SGA
            SGA-->>Engine: ErroValidacaoAcademicaDTO (codigoErro, mensagem)
            Engine-)Broker: publicarAlertaInconsistenciaSGA(EventoAuditoriaErroDTO)
        end
    end

    Engine-->>API: RelatorioConciliacaoVagaDTO (totalProcessados, listaAptosDTO)
    deactivate Engine
    API-->>Recrutador: HTTP 200 OK (RelatorioConciliacaoVagaDTO)
    deactivate API
```

---

## 4. Artefato 2 — Diagrama de Atividades com Raias (`docs/diagrams/atividades.mmd`)

Representa o *workflow* dividido em 3 Raias de Partição (*Swimlanes*), contendo decisões com Condições de Guarda booleanas mutuamente exclusivas e processamento concorrente com **Barra de Fork** e **Barra de Join**.

```mermaid
flowchart TD
    subgraph Raia_Empresa ["Raia 1: Portal da Empresa / Recrutador"]
        Inicio(("● Início")) --> PublicarVaga["Configurar Pesos de Competências e Disparar Conciliação"]
        VisualizarRanking["Visualizar Ranking de Candidatos e Convocar para Entrevista"] --> FimSucesso(("◉ Fim"))
    end

    subgraph Raia_Backend ["Raia 2: Motor de Conciliação Back-End (MatchEngine)"]
        PublicarVaga --> CarregarVaga["Carregar Matriz de Competências da Vaga (Hard/Soft Skills)"]
        CarregarVaga --> ConsultarSGA["Solicitar Validação Acadêmica e Matriz Curricular"]

        DecisaoElegivel{"Candidato Elegível?"}
        DecisaoElegivel -- "[matriculaAtiva == false || frequencia < 75.0]" --> DescartarCandidato["Descartar da Conciliação e Registrar Motivo"]
        DescartarCandidato --> FimDescarte(("◉ Fim"))

        DecisaoElegivel -- "[matriculaAtiva == true && frequencia >= 75.0]" --> ForkBar[["═══ BARRA DE FORK (Execução Paralela) ═══"]]

        ForkBar --> CalcHard["Calcular Similaridade Vetorial de Hard Skills (pgvector)"]
        ForkBar --> CalcSoft["Avaliar Aderência de Soft Skills e Projetos Práticos"]
        ForkBar --> CalcGeo["Calcular Índice de Mobilidade / Turno Escolar"]

        CalcHard --> JoinBar[["═══ BARRA DE JOIN (Sincronização) ═══"]]
        CalcSoft --> JoinBar
        CalcGeo --> JoinBar

        JoinBar --> ConsolidarScore["Consolidar Score Ponderado Final (0 a 100)"]
        ConsolidarScore --> DecisaoCorte{"Atingiu Nota de Corte?"}

        DecisaoCorte -- "[scoreFinal >= 70.0]" --> ClassificarApto["Atualizar Estado para APTO_ENTREVISTA"]
        DecisaoCorte -- "[scoreFinal < 70.0]" --> ClassificarRetido["Atualizar Estado para RETIDO_BANCO_TALENTOS"]

        ClassificarApto --> ForkNotificacao[["═══ BARRA DE FORK (Pós-Processamento) ═══"]]
        ForkNotificacao --> GerarRanking["Ordenar Candidato no Ranking da Vaga"]
        GerarRanking --> JoinNotificacao[["═══ BARRA DE JOIN ═══"]]
        JoinNotificacao --> VisualizarRanking
    end

    subgraph Raia_Externo ["Raia 3: Serviços Externos (SGA UniSENAI & Mensageria RabbitMQ)"]
        ConsultarSGA --> ValidarAPI["Validar RA e Histórico no WebService SGA UniSENAI"]
        ValidarAPI --> DecisaoElegivel

        ForkNotificacao --> PublicarEventoApto["Publicar Evento Assíncrono (RabbitMQ): Notificar Estudante"]
        PublicarEventoApto --> JoinNotificacao

        ClassificarRetido --> GerarTrilha["Publicar Evento Assíncrono: Recomendar Microcertificações SENAI"]
        GerarTrilha --> FimRetido(("◉ Fim"))
    end

    style ForkBar fill:#1e293b,stroke:#0f172a,color:#ffffff,stroke-width:2px
    style JoinBar fill:#1e293b,stroke:#0f172a,color:#ffffff,stroke-width:2px
    style ForkNotificacao fill:#1e293b,stroke:#0f172a,color:#ffffff,stroke-width:2px
    style JoinNotificacao fill:#1e293b,stroke:#0f172a,color:#ffffff,stroke-width:2px
```

---

## 5. Artefato 3 — Diagrama de Transição de Estados (`docs/diagrams/estados.mmd`)

Modela o ciclo de vida da entidade `CandidaturaMatch`, utilizando subestados compostos, compartimentos de ações internas (`entry /`, `do /`, `exit /`) e transições governadas pela sintaxe formal `Gatilho [CondiçãoDeGuarda] / AçãoDeEfeito()`.

```mermaid
stateDiagram-v2
    [*] --> Recebida : criarIntencaoMatch() [vagaAberta == true] / gerarIdRastreabilidade()

    state Recebida {
        Recebida : entry / registrarTimestampCriacao()
        Recebida : do / aguardarJanelaProcessamento()
        Recebida : exit / bloquearEdicaoCurriculoSnapshot()
    }

    Recebida --> EmConciliacao : iniciarProcessamento() [candidatoAtivo == true] / alocarWorkerPool()
    Recebida --> CanceladaPorInconsistencia : validarPreRequisitos() [vagaEncerrada == true] / notificarCancelamento()

    state EmConciliacao {
        EmConciliacao : entry / inicializarContextoTransacional()
        EmConciliacao : do / monitorarTimeoutExecucao()
        EmConciliacao : exit / persistirMetricasTelemetria()

        [*] --> ValidandoElegibilidadeSGA
        ValidandoElegibilidadeSGA --> CalculandoVetoresCompetencia : confirmarDadosSGA() [matriculaAtiva == true && frequencia >= 75.0] / anexarHistoricoOficial()
        CalculandoVetoresCompetencia --> PonderandoScoreFinal : processarEmbeddings() [vetoresValidos == true] / calcularDistanciaCosseno()
        PonderandoScoreFinal --> [*] : concluirCalculo() [pesosNormalizados == 1.0] / consolidarNota()
    }

    EmConciliacao --> AptaParaEntrevista : finalizarConciliacao() [scoreFinal >= 70.0] / emitirEventoMatchAprovado()
    EmConciliacao --> RetidaBancoTalentos : finalizarConciliacao() [scoreFinal < 70.0] / gerarDiagnosticoGaps()
    EmConciliacao --> FalhaIntegracaoExterna : capturarExcecaoSGA() [tentativasRetry >= 3] / abrirCircuitBreaker()

    FalhaIntegracaoExterna --> EmConciliacao : reprocessarJobFilaDLQ() [sgaDisponivel == true] / incrementarContadorRetry()
    FalhaIntegracaoExterna --> CanceladaPorInconsistencia : abortarJob() [tempoEsperaHoras > 24] / registrarIncidenteOperacional()

    state AptaParaEntrevista {
        AptaParaEntrevista : entry / reservarPosicaoRanking()
        AptaParaEntrevista : do / contabilizarPrazoRespostaEmpresa()
        AptaParaEntrevista : exit / atualizarAuditoriaStatus()
    }

    AptaParaEntrevista --> ConvocadaSelecao : aprovarPreSelecaoEmpresa() [dentroDoPrazo == true] / enviarConviteEntrevista()
    AptaParaEntrevista --> ExpiradaPorInatividade : verificarTTL() [diasSemInteracao > 15] / liberarPosicaoRanking()

    ConvocadaSelecao --> ContratadaEstagio : formalizarTermoCompromisso() [documentacaoAprovada == true] / emitirContratoFAB()
    ConvocadaSelecao --> RetidaBancoTalentos : encerrarEntrevistaSemAprovacao() [feedbackRegistrado == true] / atualizarHistoricoSelecao()

    ContratadaEstagio --> [*]
    RetidaBancoTalentos --> [*]
    ExpiradaPorInatividade --> [*]
    CanceladaPorInconsistencia --> [*]
```

---

## 6. Artefato 4 — Visão Arquitetural Macro C4 (`docs/architecture/workspace.dsl`)

Abaixo está a renderização da **Visão de Contêineres (C4 Nível 2)** em sintaxe declarativa Mermaid (`C4Container`), refletindo fielmente o modelo definido em `docs/architecture/workspace.dsl`.

```mermaid
C4Container
    title Diagrama de Contêineres (C4 Nível 2) - Gestão de Estágios UniSENAI (Motor de Match)

    Person(estudante, "Estudante UniSENAI", "Cadastra portfólio, competências e acompanha convocações de estágio.")
    Person(recrutador, "Recrutador / Empresa", "Publica vagas com pesos de competências e convoca candidatos aptos.")

    System_Ext(sga, "SGA UniSENAI", "Sistema Acadêmico Legado: valida matrícula ativa, semestre e frequência escolar.")
    System_Ext(smtp, "Provedor SMTP / Push", "SendGrid: envio de e-mails transacionais e notificações.")

    Container_Boundary(c1, "Plataforma de Gestão de Estágios UniSENAI") {
        Container(spa, "Portal Web Front-End", "React 18, TypeScript, TailwindCSS", "SPA para gestão de vagas, painéis de compatibilidade e trilhas.")
        Container(gateway, "API Gateway / BFF", "Kong / NGINX", "Autenticação OAuth2/JWT, rate limiting e roteamento.")
        Container(match_api, "Motor de Conciliação (Match Engine)", "Node.js 20, NestJS, TypeScript", "Orquestra elegibilidade, cálculo de similaridade vetorial e publicação de eventos.")
        Container(worker, "Worker de Notificações e Trilhas", "Node.js 20, NestJS Microservice", "Processa eventos assíncronos de convocação e recomendação de cursos.")
        ContainerDb(postgres, "Banco Relacional e Vetorial", "PostgreSQL 16 + pgvector", "Armazena vagas, candidaturas, estados e embeddings vetoriais (HNSW).")
        ContainerDb(redis, "Cache Distribuído", "Redis 7", "Cache de respostas do SGA (TTL 15m) e controle de idempotência.")
        ContainerQueue(rabbit, "Message Broker", "RabbitMQ 3.13", "Filas AMQP para eventos de domínio e Dead-Letter Queue (DLQ).")
    }

    Rel(estudante, spa, "Acessa painel e trilhas", "HTTPS")
    Rel(recrutador, spa, "Dispara conciliação e visualiza ranking", "HTTPS")
    Rel(spa, gateway, "Consome API", "HTTPS / REST (JSON)")
    Rel(gateway, match_api, "Roteia requisições autenticadas", "HTTP/2 / REST (JSON)")

    Rel(match_api, postgres, "Persiste estados e executa busca vetorial (<=>)", "TCP / SQL (TLS)")
    Rel(match_api, redis, "Consulta cache de elegibilidade e locks", "TCP / RESP")
    Rel(match_api, sga, "Valida matrícula e frequência do aluno", "HTTPS / REST (JSON)")
    Rel(match_api, rabbit, "Publica EventoMatchConcluidoDTO e EventoGapCompetenciaDTO", "TCP / AMQP 0-9-1")

    Rel(rabbit, worker, "Consome eventos da fila", "TCP / AMQP 0-9-1")
    Rel(worker, smtp, "Envia alertas e recomendações de capacitação", "HTTPS / REST API")
```

---

## 7. Artefato 5 — Registro de Decisão Arquitetural (`docs/architecture/adr-0001.md`)

O documento completo encontra-se em [`docs/architecture/adr-0001.md`](docs/architecture/adr-0001.md) e formaliza a decisão pelo uso conjunto de **PostgreSQL 16 + `pgvector`** (eliminando *dual-write* entre bancos relacionais e vetoriais) e **RabbitMQ** (garantindo baixa latência na resposta ao recrutador e resiliência via *Dead-Letter Queues*).