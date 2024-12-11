#!/bin/bash

###################
# 用户配置部分
###################
# Ollama 配置
OLLAMA_MODEL="llama3.2-vision"                      # 使用的模型名称
OLLAMA_MODEL_PATH="/root/.ollama/models"            # 模型存储路径
OLLAMA_HOST="0.0.0.0"                              # 服务监听地址
OLLAMA_PORT="11434"                                 # 服务端口
OLLAMA_AUTH_TOKEN="35794406"                        # 认证token
OLLAMA_KEEP_ALIVE="20h"                            # 保持连接时间
OLLAMA_ORIGINS="*"                                  # CORS设置

# Cloudflare 隧道配置
# 在运行脚本前，请先完成以下步骤：
# 1. 注册并登录 Cloudflare 账号：https://dash.cloudflare.com
# 2. 添加你的域名到 Cloudflare（如果还没有）
# 3. 在 DNS 设置中添加一个 CNAME 记录指向你的隧道域名
TUNNEL_TYPE="cloudflared"                           # 隧道类型：cloudflared
CLOUDFLARED_TUNNEL_NAME="ollama-tunnel"             # 隧道名称，可自定义
CLOUDFLARED_HOSTNAME="xxx"        # 替换为你的实际域名
CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"           # 配置目录
CLOUDFLARED_CONFIG_FILE="${CLOUDFLARED_CONFIG_DIR}/config.yml" # 配置文件路径

# 日志配置
LOG_DIR="/workspace/logs"                           # 日志目录
OLLAMA_LOG="${LOG_DIR}/ollama.log"                 # Ollama 日志文件
TUNNEL_LOG="${LOG_DIR}/tunnel.log"                 # 隧道日志文件
INSTALL_MARK="/root/.ollama_installed"             # 安装标记文件

###################
# 函数定义
###################

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a ${OLLAMA_LOG}
}

# 配置 Cloudflare 隧道
setup_cloudflare_tunnel() {
    log "配置 Cloudflare 隧道..."
    
    # 清理旧文件
    log "清理旧文件..."
    rm -f /usr/local/bin/devtunnel
    rm -rf "${CLOUDFLARED_CONFIG_DIR}"
    mkdir -p "${CLOUDFLARED_CONFIG_DIR}"
    chmod 755 "${CLOUDFLARED_CONFIG_DIR}"
    
    # 检查是否已经登录
    if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
        log "需要登录 Cloudflare 账号..."
        cloudflared login
        
        # 等待用户完成登录
        sleep 5
        
        if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
            log "错误: 登录失败或证书文件未生成"
            return 1
        fi
    fi
    
    # 删除现有隧道（如果存在）
    if cloudflared tunnel list 2>/dev/null | grep -q "${CLOUDFLARED_TUNNEL_NAME}"; then
        log "删除现有隧道..."
        EXISTING_ID=$(cloudflared tunnel list | grep "${CLOUDFLARED_TUNNEL_NAME}" | awk '{print $1}')
        cloudflared tunnel delete -f "${EXISTING_ID}" || true
        sleep 2
    fi
    
    # 创建新隧道
    log "创建新隧道: ${CLOUDFLARED_TUNNEL_NAME}"
    TUNNEL_OUTPUT=$(cloudflared tunnel create "${CLOUDFLARED_TUNNEL_NAME}" 2>&1)
    if ! echo "${TUNNEL_OUTPUT}" | grep -q "Created tunnel"; then
        log "错误: 创建隧道失败: ${TUNNEL_OUTPUT}"
        return 1
    fi
    
    # 获取隧道ID
    TUNNEL_ID=$(echo "${TUNNEL_OUTPUT}" | grep -o 'Created tunnel.*with id [^ ]*' | awk '{print $NF}')
    if [ -z "${TUNNEL_ID}" ]; then
        log "错误: 无法获取隧道ID"
        return 1
    fi
    log "隧道ID: ${TUNNEL_ID}"
    
    # 检查凭证文件
    CRED_FILE="${CLOUDFLARED_CONFIG_DIR}/${TUNNEL_ID}.json"
    if [ ! -f "$HOME/.cloudflared/${TUNNEL_ID}.json" ]; then
        log "错误: 在 $HOME/.cloudflared/ 中未找到凭证文件"
        ls -la "$HOME/.cloudflared/"
        return 1
    fi
    
    # 复制凭证文件
    log "复制凭证文件..."
    cp "$HOME/.cloudflared/${TUNNEL_ID}.json" "${CRED_FILE}"
    if [ ! -f "${CRED_FILE}" ]; then
        log "错误: 凭证文件复制失败"
        return 1
    fi
    chmod 600 "${CRED_FILE}"
    
    # 配置 DNS 记录
    log "配置 DNS 记录..."
    if ! cloudflared tunnel route dns "${CLOUDFLARED_TUNNEL_NAME}" "${CLOUDFLARED_HOSTNAME}"; then
        log "错误: DNS 记录配置失败"
        return 1
    fi
    
    # 创建配置文件
    create_tunnel_config "${TUNNEL_ID}"
    
    # 验证配置
    if ! cloudflared tunnel ingress validate "${CLOUDFLARED_CONFIG_FILE}"; then
        log "错误: 隧道配置验证失败"
        return 1
    fi
    
    return 0
}

# 创建隧道配置
create_tunnel_config() {
    local tunnel_id="$1"
    log "创建隧道配置..."
    
    cat > "${CLOUDFLARED_CONFIG_FILE}" <<EOF
# Cloudflare 隧道配置
tunnel: ${tunnel_id}
credentials-file: ${CLOUDFLARED_CONFIG_DIR}/${tunnel_id}.json
protocol: http2

# 入站规则
ingress:
  - hostname: ${CLOUDFLARED_HOSTNAME}
    service: http://localhost:${OLLAMA_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404

# 日志设置
logDirectory: ${LOG_DIR}
EOF
    
    # 设置配置文件权限
    chmod 600 "${CLOUDFLARED_CONFIG_FILE}"
    
    log "隧道配置已创建: ${CLOUDFLARED_CONFIG_FILE}"
    log "配置文件内容:"
    cat "${CLOUDFLARED_CONFIG_FILE}"
}

# 启动隧道服务
start_tunnel() {
    case ${TUNNEL_TYPE} in
        "cloudflared")
            if command -v cloudflared &> /dev/null; then
                log "启动 Cloudflared 服务..."
                # 确保没有遗留的进程
                pkill -f "cloudflared" >/dev/null 2>&1
                sleep 2
                
                # 检查配置文件
                if [ ! -f "${CLOUDFLARED_CONFIG_FILE}" ]; then
                    log "错误: 配置文件不存在: ${CLOUDFLARED_CONFIG_FILE}"
                    return 1
                fi
                
                # 检查凭证文件
                TUNNEL_ID=$(grep "tunnel:" "${CLOUDFLARED_CONFIG_FILE}" | awk '{print $2}')
                CRED_FILE="${CLOUDFLARED_CONFIG_DIR}/${TUNNEL_ID}.json"
                if [ ! -f "${CRED_FILE}" ]; then
                    log "错误: 凭证文件不存在: ${CRED_FILE}"
                    return 1
                fi
                
                # 启动隧道
                log "启动隧道..."
                log "使用配置文件: ${CLOUDFLARED_CONFIG_FILE}"
                log "使用凭证文件: ${CRED_FILE}"
                
                nohup cloudflared tunnel --config "${CLOUDFLARED_CONFIG_FILE}" run >> "${TUNNEL_LOG}" 2>&1 &
                
                # 等待隧道启动
                sleep 5
                if pgrep -f "cloudflared" > /dev/null; then
                    log "Cloudflared 服务已启动"
                    log "隧道URL: https://${CLOUDFLARED_HOSTNAME}"
                    
                    # 等待隧道完全建立
                    for i in {1..12}; do
                        if curl -s -o /dev/null -w "%{http_code}" "https://${CLOUDFLARED_HOSTNAME}" | grep -q "200\|301\|302\|404"; then
                            log "隧道连接已建立"
                            return 0
                        fi
                        log "等待隧道建立... (${i}/12)"
                        sleep 5
                    done
                    log "警告: 隧道可能未完全建立，但服务已启动"
                else
                    log "错误: Cloudflared 服务启动失败"
                    cat "${TUNNEL_LOG}"
                    return 1
                fi
            else
                log "错误: Cloudflared 未安装或无法找到"
                return 1
            fi
            ;;
        *)
            log "错误: 未知的隧道类型 ${TUNNEL_TYPE}"
            return 1
            ;;
    esac
}

# 检查隧道服务状态
check_tunnel_status() {
    case ${TUNNEL_TYPE} in
        "cloudflared")
            if pgrep -f "cloudflared" > /dev/null; then
                log "Cloudflared 服务运行中"
                log "隧道URL: https://${CLOUDFLARED_HOSTNAME}"
                
                # 检查隧道连接状态
                if cloudflared tunnel info "${CLOUDFLARED_TUNNEL_NAME}" | grep -q "ACTIVE"; then
                    log "隧道状态: 活跃"
                else
                    log "隧道状态: 未活跃"
                    tail -n 20 "${TUNNEL_LOG}"
                fi
            else
                log "警告: Cloudflared 服务未运行"
                log "最后的错误日志:"
                tail -n 20 "${TUNNEL_LOG}"
            fi
            ;;
    esac
}

# 检查并创建日志目录
setup_logging() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
    fi
    touch ${OLLAMA_LOG}
    touch ${TUNNEL_LOG}
}

# 检查并安装 Ollama
check_ollama() {
    if ! command -v ollama &> /dev/null; then
        log "安装 Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        sleep 5  # 等待安装完成
    else
        log "Ollama 已安装"
    fi
}

# 启动 Ollama 服务
start_ollama() {
    log "启动 Ollama 服务..."
    export OLLAMA_HOST=${OLLAMA_HOST}
    export OLLAMA_AUTH_TOKEN=${OLLAMA_AUTH_TOKEN}
    export OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
    export OLLAMA_ORIGINS=${OLLAMA_ORIGINS}
    
    pkill -f "ollama serve" >/dev/null 2>&1
    /usr/local/bin/ollama serve >> ${OLLAMA_LOG} 2>&1 &
    sleep 10
    
    /usr/local/bin/ollama run ${OLLAMA_MODEL} >> ${OLLAMA_LOG} 2>&1 &
    log "Ollama 服务已启动"
}

# 检查模型是否存在
check_model() {
    sleep 5  # 等待 Ollama 服务完全启动
    log "检查模型 ${OLLAMA_MODEL} ..."
    if ! ollama list | grep -q "${OLLAMA_MODEL}"; 键，然后
        log "模型不存在，开始下载 ${OLLAMA_MODEL} ..."
        ollama pull ${OLLAMA_MODEL}
    else
        log "模型 ${OLLAMA_MODEL} 已存在"
    fi
}

# 检查服务状态
check_service_status() {
    # 检查 Ollama 服务状态
    if pgrep -f "ollama serve" > /dev/null; 键，然后
        log "Ollama 服务运行中"
    else
        log "警告: Ollama 服务未运行"
    fi
}

# 安装 Cloudflared
install_cloudflared() {
    log "检查 Cloudflared 安装状态..."
    
    if ! command -v cloudflared &> /dev/null; 键，然后
        log "开始安装 Cloudflared..."
        
        # 添加 Cloudflare GPG 密钥
        mkdir -p /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --dearmor | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        
        # 添加 Cloudflare 仓库
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared focal main' | tee /etc/apt/sources.list.d/cloudflared.list
        
        # 安装 Cloudflared
        apt-get update && apt-get install -y cloudflared
        
        # 验证安装
        if command -v cloudflared &> /dev/null; 键，然后
            VERSION=$(cloudflared --version 2>&1 || echo "未知版本")
            log "Cloudflared 安装成功，版本: ${VERSION}"
            
            # 配置隧道
            setup_cloudflare_tunnel
            return 0
        else
            log "错误: Cloudflared 安装验证失败"
            return 1
        fi
    else
        VERSION=$(cloudflared --version 2>&1 || echo "未知版本")
        log "Cloudflared 已安装，版本: ${VERSION}"
        # 确保配置正确
        setup_cloudflare_tunnel
        return 0
    fi
}

# 检查依赖
check_dependencies() {
    if [ ! -f "$INSTALL_MARK" ]; 键，然后
        log "首次运行，检查并安装依赖..."
        
        if ! command -v curl &> /dev/null; 键，然后
            log "安装 curl..."
            apt-get update && apt-get install -y curl
        fi

        case ${TUNNEL_TYPE} 在
            "cloudflared")
                if ! command -v cloudflared &> /dev/null; 键，然后
                    log "安装 cloudflared..."
                    curl -O https://bin.equinox.io/c/bNyj1mQVY4c/cloudflared-v3-stable-linux-amd64.tgz
                    tar xvzf cloudflared-v3-stable-linux-amd64.tgz
                    mv cloudflared /usr/local/bin/
                    rm cloudflared-v3-stable-linux-amd64.tgz
                fi
                ;;
        esac

        touch "$INSTALL_MARK"
    fi
}

###################
# 主程序
###################
main() {
    setup_logging
    log "开始启动服务..."
    
    check_dependencies
    check_ollama
    start_ollama
    check_model
    
    # 确保 Cloudflared 已安装
    if [ "${TUNNEL_TYPE}" = "cloudflared" ]; 键，然后
        install_cloudflared || {
            log "Cloudflared 安装失败"
            exit 1
        }
    fi
    
    start_tunnel
    
    sleep 5  # 等待服务启动
    check_service_status
    check_tunnel_status
    log "所有服务启动完成"
}

main
