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

# 隧道配置
TUNNEL_TYPE="ngrok"                                # 隧道类型：ngrok 或 devtunnel
# Ngrok 配置
NGROK_AUTH_TOKEN="your_ngrok_auth_token"           # ngrok authtoken
NGROK_DOMAIN="your-domain.ngrok-free.app"          # 静态域名

# DevTunnel 配置
DEVTUNNEL_NAME="ollama-tunnel"                     # 隧道名称
DEVTUNNEL_ACCESS="public"                          # 访问权限：public 或 private

# 日志配置
LOG_DIR="/workspace/logs"
OLLAMA_LOG="${LOG_DIR}/ollama.log"
TUNNEL_LOG="${LOG_DIR}/tunnel.log"
INSTALL_MARK="/root/.ollama_installed"              # 安装标记文件

###################
# 函数定义
###################

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a ${OLLAMA_LOG}
}

# 检查并创建日志目录
setup_logging() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
    fi
    touch ${OLLAMA_LOG}
    touch ${NGROK_LOG}
}

# 安装 DevTunnel
install_devtunnel() {
    if ! command -v devtunnel &> /dev/null; then
        log "安装 DevTunnel..."
        curl -sL https://aka.ms/DevTunnelCli-Linux | bash
    fi
}

# 配置隧道服务
setup_tunnel() {
    case ${TUNNEL_TYPE} in
        "ngrok")
            if [ -x "$(command -v ngrok)" ]; then
                log "配置 Ngrok..."
                ngrok config add-authtoken ${NGROK_AUTH_TOKEN}
            else
                log "错误: Ngrok 未安装成功"
                return 1
            fi
            ;;
        "devtunnel")
            if [ -x "$(command -v devtunnel)" ]; then
                log "配置 DevTunnel..."
                devtunnel user login
            else
                log "错误: DevTunnel 未安装成功"
                return 1
            fi
            ;;
        *)
            log "错误: 未知的隧道类型 ${TUNNEL_TYPE}"
            return 1
            ;;
    esac
}

# 启动隧道服务
start_tunnel() {
    case ${TUNNEL_TYPE} in
        "ngrok")
            if [ -x "$(command -v ngrok)" ]; then
                log "启动 Ngrok 服务..."
                pkill -f "ngrok" >/dev/null 2>&1
                nohup ngrok http --domain=${NGROK_DOMAIN} ${OLLAMA_PORT} >> ${TUNNEL_LOG} 2>&1 &
                log "Ngrok 服务已启动"
            else
                log "错误: 无法启动 Ngrok 服务"
            fi
            ;;
        "devtunnel")
            if [ -x "$(command -v devtunnel)" ]; then
                log "启动 DevTunnel 服务..."
                pkill -f "devtunnel" >/dev/null 2>&1
                nohup devtunnel host -p ${OLLAMA_PORT} --allow-anonymous --access ${DEVTUNNEL_ACCESS} --name ${DEVTUNNEL_NAME} >> ${TUNNEL_LOG} 2>&1 &
                log "DevTunnel 服务已启动"
            else
                log "错误: 无法启动 DevTunnel 服务"
            fi
            ;;
    esac
}

# 检查隧道服务状态
check_tunnel_status() {
    case ${TUNNEL_TYPE} in
        "ngrok")
            if pgrep -f "ngrok" > /dev/null; then
                log "Ngrok 服务运行中"
                # 显示隧道URL
                sleep 2
                TUNNEL_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"[^"]*' | grep -o 'https://.*')
                log "Ngrok 隧道URL: ${TUNNEL_URL}"
            else
                log "警告: Ngrok 服务未运行"
            fi
            ;;
        "devtunnel")
            if pgrep -f "devtunnel" > /dev/null; then
                log "DevTunnel 服务运行中"
                # 获取隧道URL（需要根据实际输出格式调整）
                sleep 2
                TUNNEL_URL=$(grep -o 'https://.*\.devtunnels\.ms' ${TUNNEL_LOG} | tail -1)
                log "DevTunnel 隧道URL: ${TUNNEL_URL}"
            else
                log "警告: DevTunnel 服务未运行"
            fi
            ;;
    esac
}

# 检查依赖
check_dependencies() {
    if [ ! -f "$INSTALL_MARK" ]; then
        log "首次运行，检查并安装依赖..."
        
        if ! command -v curl &> /dev/null; then
            log "安装 curl..."
            apt-get update && apt-get install -y curl
        fi

        case ${TUNNEL_TYPE} in
            "ngrok")
                if ! command -v ngrok &> /dev/null; then
                    log "安装 ngrok..."
                    curl -O https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
                    tar xvzf ngrok-v3-stable-linux-amd64.tgz
                    mv ngrok /usr/local/bin/
                    rm ngrok-v3-stable-linux-amd64.tgz
                fi
                ;;
            "devtunnel")
                install_devtunnel
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
    setup_tunnel
    start_tunnel
    
    check_service_status
    check_tunnel_status
    log "所有服务启动完成"
}

main
