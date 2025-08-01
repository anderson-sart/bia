#!/bin/bash

# Script de Deploy ECS - Projeto BIA
# Autor: Amazon Q
# Versão: 1.0.0

set -e

# Configurações padrão
DEFAULT_REGION="us-east-1"
DEFAULT_CLUSTER="cluster-bia2"
DEFAULT_SERVICE="service-bia2"
DEFAULT_TASK_FAMILY="task-def-bia"
DEFAULT_ECR_REPO="bia"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir help
show_help() {
    cat << EOF
${BLUE}Script de Deploy ECS - Projeto BIA${NC}

${YELLOW}DESCRIÇÃO:${NC}
    Script para build, tag e deploy de aplicações no Amazon ECS.
    Cada imagem é taggeada com o hash do commit atual para permitir rollback.

${YELLOW}USO:${NC}
    $0 [OPÇÕES] COMANDO

${YELLOW}COMANDOS:${NC}
    build       Faz build da imagem Docker com tag do commit
    deploy      Faz deploy da imagem atual para o ECS
    rollback    Faz rollback para uma versão específica
    list        Lista as últimas 10 versões disponíveis no ECR
    help        Exibe esta ajuda

${YELLOW}OPÇÕES:${NC}
    -r, --region REGION         Região AWS (padrão: $DEFAULT_REGION)
    -c, --cluster CLUSTER       Nome do cluster ECS (padrão: $DEFAULT_CLUSTER)
    -s, --service SERVICE       Nome do serviço ECS (padrão: $DEFAULT_SERVICE)
    -f, --family FAMILY         Família da task definition (padrão: $DEFAULT_TASK_FAMILY)
    -e, --ecr-repo REPO         Nome do repositório ECR (padrão: $DEFAULT_ECR_REPO)
    -t, --tag TAG               Tag específica para rollback
    -h, --help                  Exibe esta ajuda

${YELLOW}EXEMPLOS:${NC}
    # Build da imagem atual
    $0 build

    # Deploy da versão atual
    $0 deploy

    # Deploy com configurações customizadas
    $0 --region us-west-2 --cluster meu-cluster deploy

    # Rollback para uma versão específica
    $0 rollback --tag a1b2c3d

    # Listar versões disponíveis
    $0 list

${YELLOW}VARIÁVEIS DE AMBIENTE:${NC}
    AWS_ACCOUNT_ID    ID da conta AWS (obrigatório)
    AWS_REGION        Região AWS (opcional, padrão: $DEFAULT_REGION)

${YELLOW}PRÉ-REQUISITOS:${NC}
    - AWS CLI configurado
    - Docker instalado
    - Permissões para ECR, ECS e IAM
    - Estar no diretório raiz do projeto

EOF
}

# Função para log colorido
log() {
    local level=$1
    shift
    case $level in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $*" >&2 ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $*" >&2 ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $*" >&2 ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} $*" >&2 ;;
    esac
}

# Função para verificar pré-requisitos
check_prerequisites() {
    log "INFO" "Verificando pré-requisitos..."
    
    # Verificar se está no diretório correto
    if [[ ! -f "package.json" ]] || [[ ! -f "Dockerfile" ]]; then
        log "ERROR" "Execute o script no diretório raiz do projeto (onde estão package.json e Dockerfile)"
        exit 1
    fi
    
    # Verificar AWS CLI
    if ! command -v aws &> /dev/null; then
        log "ERROR" "AWS CLI não encontrado. Instale o AWS CLI primeiro."
        exit 1
    fi
    
    # Verificar Docker
    if ! command -v docker &> /dev/null; then
        log "ERROR" "Docker não encontrado. Instale o Docker primeiro."
        exit 1
    fi
    
    # Verificar AWS_ACCOUNT_ID
    if [[ -z "$AWS_ACCOUNT_ID" ]]; then
        log "ERROR" "Variável AWS_ACCOUNT_ID não definida"
        log "INFO" "Execute: export AWS_ACCOUNT_ID=\$(aws sts get-caller-identity --query Account --output text)"
        exit 1
    fi
    
    log "INFO" "Pré-requisitos verificados com sucesso"
}

# Função para obter commit hash
get_commit_hash() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git rev-parse --short=7 HEAD
    else
        log "WARN" "Não é um repositório Git. Usando timestamp como tag."
        date +%s | tail -c 8
    fi
}

# Função para fazer login no ECR
ecr_login() {
    log "INFO" "Fazendo login no ECR..."
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
}

# Função para build da imagem
build_image() {
    local commit_hash=$(get_commit_hash)
    local image_tag="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$commit_hash"
    local latest_tag="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:latest"
    
    log "INFO" "Iniciando build da imagem..."
    log "INFO" "Commit hash: $commit_hash"
    log "INFO" "Tag da imagem: $image_tag"
    
    # Build da imagem
    docker build -t $image_tag -t $latest_tag .
    
    # Login no ECR
    ecr_login
    
    # Push da imagem
    log "INFO" "Fazendo push da imagem para ECR..."
    docker push $image_tag
    docker push $latest_tag
    
    log "INFO" "Build concluído com sucesso!"
    log "INFO" "Imagem disponível: $image_tag"
    
    # Salvar tag atual para deploy
    echo $commit_hash > .last-build-tag
}

# Função para criar nova task definition
create_task_definition() {
    local image_tag=$1
    local image_uri="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$image_tag"
    
    log "INFO" "Criando nova task definition..."
    log "INFO" "Imagem: $image_uri"
    
    # Obter task definition atual
    local current_td=$(aws ecs describe-task-definition --task-definition $TASK_FAMILY --region $REGION --query 'taskDefinition' --output json)
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Erro ao obter task definition atual: $TASK_FAMILY"
        exit 1
    fi
    
    # Criar nova task definition com a nova imagem
    local new_td=$(echo $current_td | jq --arg IMAGE "$image_uri" '
        .containerDefinitions[0].image = $IMAGE |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ')
    
    # Registrar nova task definition
    local temp_file=$(mktemp)
    echo "$new_td" > "$temp_file"
    local new_td_arn=$(aws ecs register-task-definition --region $REGION --cli-input-json "file://$temp_file" --query 'taskDefinition.taskDefinitionArn' --output text)
    rm "$temp_file"
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Nova task definition criada: $new_td_arn"
        echo $new_td_arn
    else
        log "ERROR" "Erro ao criar nova task definition"
        exit 1
    fi
}

# Função para fazer deploy
deploy_service() {
    local tag=${1:-$(cat .last-build-tag 2>/dev/null)}
    
    if [[ -z "$tag" ]]; then
        log "ERROR" "Tag não especificada e nenhum build recente encontrado"
        log "INFO" "Execute 'build' primeiro ou especifique uma tag com --tag"
        exit 1
    fi
    
    log "INFO" "Iniciando deploy para ECS..."
    log "INFO" "Tag: $tag"
    
    # Criar nova task definition
    local new_td_arn=$(create_task_definition $tag)
    
    # Atualizar serviço
    log "INFO" "Atualizando serviço ECS..."
    aws ecs update-service \
        --cluster $CLUSTER \
        --service $SERVICE \
        --task-definition $new_td_arn \
        --region $REGION \
        --query 'service.serviceName' \
        --output text
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Deploy iniciado com sucesso!"
        log "INFO" "Aguardando estabilização do serviço..."
        
        # Aguardar estabilização
        aws ecs wait services-stable \
            --cluster $CLUSTER \
            --services $SERVICE \
            --region $REGION
        
        log "INFO" "Deploy concluído com sucesso!"
        log "INFO" "Serviço: $SERVICE"
        log "INFO" "Cluster: $CLUSTER"
        log "INFO" "Tag deployada: $tag"
    else
        log "ERROR" "Erro durante o deploy"
        exit 1
    fi
}

# Função para listar versões
list_versions() {
    log "INFO" "Listando últimas 10 versões no ECR..."
    
    aws ecr describe-images \
        --repository-name $ECR_REPO \
        --region $REGION \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' \
        --output table
}

# Função para rollback
rollback_service() {
    local tag=$1
    
    if [[ -z "$tag" ]]; then
        log "ERROR" "Tag para rollback não especificada"
        log "INFO" "Use: $0 rollback --tag <commit-hash>"
        exit 1
    fi
    
    log "INFO" "Iniciando rollback para tag: $tag"
    
    # Verificar se a imagem existe no ECR
    aws ecr describe-images \
        --repository-name $ECR_REPO \
        --image-ids imageTag=$tag \
        --region $REGION \
        --query 'imageDetails[0].imageTags[0]' \
        --output text > /dev/null
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Imagem com tag '$tag' não encontrada no ECR"
        log "INFO" "Use '$0 list' para ver versões disponíveis"
        exit 1
    fi
    
    # Fazer deploy da versão específica
    deploy_service $tag
}

# Parsing de argumentos
REGION=$DEFAULT_REGION
CLUSTER=$DEFAULT_CLUSTER
SERVICE=$DEFAULT_SERVICE
TASK_FAMILY=$DEFAULT_TASK_FAMILY
ECR_REPO=$DEFAULT_ECR_REPO
TAG=""
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -f|--family)
            TASK_FAMILY="$2"
            shift 2
            ;;
        -e|--ecr-repo)
            ECR_REPO="$2"
            shift 2
            ;;
        -t|--tag)
            TAG="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        build|deploy|rollback|list|help)
            COMMAND="$1"
            shift
            ;;
        *)
            log "ERROR" "Opção desconhecida: $1"
            show_help
            exit 1
            ;;
    esac
done

# Verificar se comando foi especificado
if [[ -z "$COMMAND" ]]; then
    log "ERROR" "Comando não especificado"
    show_help
    exit 1
fi

# Definir AWS_ACCOUNT_ID se não estiver definido
if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
fi

# Executar comando
case $COMMAND in
    "help")
        show_help
        ;;
    "build")
        check_prerequisites
        build_image
        ;;
    "deploy")
        check_prerequisites
        deploy_service $TAG
        ;;
    "rollback")
        check_prerequisites
        rollback_service $TAG
        ;;
    "list")
        check_prerequisites
        list_versions
        ;;
    *)
        log "ERROR" "Comando inválido: $COMMAND"
        show_help
        exit 1
        ;;
esac
