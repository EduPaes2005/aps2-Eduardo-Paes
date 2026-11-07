workspace "Gestão de Estágios UniSENAI" "Arquitetura do Motor de Conciliação (Match) de Competências" {

    model {
        estudante = person "Estudante UniSENAI" "Aluno matriculado que cadastra portfólio, projetos e competências buscando vagas de estágio."
        recrutador = person "Recrutador / Empresa Parceira" "Gestor que publica vagas com matriz de competências e avalia o ranking de candidatos compatíveis."

        sgaUnisenai = softwareSystem "SGA UniSENAI (Sistema de Gestão Acadêmica)" "Sistema legado externo que detém matrículas, frequência escolar e notas oficiais." "External System"
        servicoEmail = softwareSystem "Provedor SMTP / Push (SendGrid)" "Serviço externo para envio de e-mails transacionais e alertas." "External System"

        sistemaEstagios = softwareSystem "Plataforma de Gestão de Estágios UniSENAI" "Realiza a conciliação automatizada entre competências de estudantes e demandas de vagas de estágio." {

            spaWeb = container "Portal Web Front-End" "Interface para empresas gerenciarem vagas e alunos acompanharem o status do Match." "React 18, TypeScript, TailwindCSS" "Web Browser"
            apiGateway = container "API Gateway / BFF" "Roteamento, autenticação JWT (OAuth2), rate limiting e agregação de payloads." "NGINX / Kong"

            matchService = container "Serviço Motor de Conciliação (Match Engine)" "Executa o algoritmo híbrido de conciliação de competências, validação acadêmica e cálculo vetorial." "Node.js 20, NestJS, TypeScript" {
                matchController = component "MatchController" "Expõe endpoints REST para disparo e consulta de relatórios de conciliação." "NestJS REST Controller"
                matchEngineService = component "MatchEngineService" "Orquestra o fluxo de conciliação, regras de corte e despacho de eventos." "Domain Service"
                sgaAdapter = component "SgaIntegrationAdapter" "Cliente resiliente com Circuit Breaker para consulta de elegibilidade no SGA." "Axios + Opossum Circuit Breaker"
                competenciaRepo = component "CompetenciaRepository" "Executa queries de similaridade por cosseno e persistência transacional." "Prisma ORM + pgvector SQL"
                eventPublisher = component "EventBrokerPublisher" "Publica eventos de domínio assíncronos no broker de mensageria." "amqplib / RabbitMQ Client"
            }

            workerNotificacao = container "Worker de Notificações e Trilhas" "Consome eventos de match aprovado ou gaps de competência para notificar alunos." "Node.js 20, NestJS Microservice"
            dbPrincipal = container "Banco de Dados Relacional e Vetorial" "Armazena vagas, currículos, estados do match e embeddings vetoriais de competências." "PostgreSQL 16 + extensão pgvector" "Database"
            cacheRedis = container "Cache Distribuído" "Armazena cache de consultas ao SGA e locks distribuídos de processamento." "Redis 7" "Database"
            messageBroker = container "Message Broker" "Gerencia filas assíncronas de eventos de domínio e Dead-Letter Queues (DLQ)." "RabbitMQ 3.13 (AMQP 0-9-1)" "Message Bus"
        }

        # Relacionamentos Nível Contêiner
        estudante -> spaWeb "Consulta compatibilidade e trilhas recomendadas via" "HTTPS / JSON"
        recrutador -> spaWeb "Publica vagas e solicita conciliação de candidatos via" "HTTPS / JSON"
        spaWeb -> apiGateway "Realiza chamadas de API via" "HTTPS / REST (JSON)"
        apiGateway -> matchService "Encaminha requisições autenticadas para" "HTTP/2 / REST (JSON)"

        matchService -> dbPrincipal "Persiste candidaturas e executa busca vetorial por cosseno em" "TCP / PostgreSQL Wire Protocol (TLS)"
        matchService -> cacheRedis "Lê/grava cache de validação acadêmica e locks em" "TCP / RESP Protocol"
        matchService -> sgaUnisenai "Valida matrícula ativa e frequência escolar via" "HTTPS / REST (JSON)"
        matchService -> messageBroker "Publica eventos (EventoMatchConcluidoDTO, EventoGapCompetenciaDTO) em" "TCP / AMQP 0-9-1"

        messageBroker -> workerNotificacao "Entrega mensagens de eventos para" "TCP / AMQP 0-9-1"
        workerNotificacao -> servicoEmail "Dispara e-mails de convocação ou plano de estudos via" "HTTPS / REST API"

        # Relacionamentos Nível Componente (Match Engine)
        apiGateway -> matchController "Invoca solicitarConciliacao(SolicitacaoMatchDTO)" "HTTPS / REST"
        matchController -> matchEngineService "Chama executarConciliacaoVaga()" "Chamada Síncrona In-Process"
        matchEngineService -> competenciaRepo "Chama buscarRequisitosVaga() e calcularSimilaridadeVetorial()" "Chamada Síncrona"
        matchEngineService -> sgaAdapter "Chama validarSituacaoAcademica(raEstudante)" "Chamada Síncrona"
        matchEngineService -> eventPublisher "Chama publicarEventoMatchAprovado()" "Assíncrono / Fire-and-Forget"
        competenciaRepo -> dbPrincipal "Executa queries SQL + operador <=> (pgvector)" "TCP / SQL"
        sgaAdapter -> sgaUnisenai "GET /api/v1/alunos/{ra}/elegibilidade" "HTTPS / JSON"
        sgaAdapter -> cacheRedis "Cacheia resposta do SGA (TTL 15 min)" "TCP / RESP"
        eventPublisher -> messageBroker "Publica na exchange 'estagios.match.events'" "AMQP 0-9-1"
    }

    views {
        container sistemaEstagios "C4_Containers" "Visão de Contêineres (C4 Nível 2) - Plataforma de Gestão de Estágios UniSENAI" {
            include *
            autoLayout lr
        }

        component matchService "C4_Components" "Visão de Componentes (C4 Nível 3) - Motor de Conciliação de Competências" {
            include *
            autoLayout tb
        }

        styles {
            element "Person" {
                shape Person
                background #08427b
                color #ffffff
            }
            element "External System" {
                background #999999
                color #ffffff
            }
            element "Database" {
                shape Cylinder
                background #438dd5
                color #ffffff
            }
            element "Message Bus" {
                shape Pipe
                background #85bbf0
                color #000000
            }
        }
    }
}