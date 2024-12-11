#!/bin/bash

###################
# 用户配置部分
###################
# Ollama 配置
OLLAMA_MODEL="llama3.2-vision"                      # 使用的模型名称
OLLAMA_MODEL_PATH="/root/.ollama/models"            # 模型存储路径
OLLAMA_HOST="0.0.0.0"                              # 服务监听地址
OLLAMA_PORT="11434"                                 # 服务端口
OLLAMA_AUTH_TOKEN="XXX"                        # 认证token
OLLAMA_KEEP_ALIVE="20h"                            # 保持连接时间
OLLAMA_ORIGINS="*"                                  # CORS设置

# Ngrok 配置
NGROK_AUTH_TOKEN="xxx"           # ngrok authtoken
NGROK_DOMAIN="xxx"  # 静态域名

# 日志配置
LOG_DIR="/workspace/logs"
OLLAMA_LOG="${LOG_DIR}/ollama.log"
NGROK_LOG="${LOG_DIR}/ngrok.log"
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

# 检查并安装依赖
check_dependencies() {
    # 只在首次安装时执行
    if [ ! -f "$INSTALL_MARK" ]; then
        log "首次运行，检查并安装依赖..."
        
        # 安装 curl（如果需要）
        if ! command -v curl &> /dev/null; then
            log "安装 curl..."
            apt-get update && apt-get install -y curl
        fi

        # 安装 ngrok
        if ! command -v ngrok &> /dev/null; then
            log "安装 ngrok..."
            curl -O https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
            tar xvzf ngrok-v3-stable-linux-amd64.tgz
            mv ngrok /usr/local/bin/
            rm ngrok-v3-stable-linux-amd64.tgz
        fi

        # 创建安装标记
        touch "$INSTALL_MARK"
    fi
}

# 检查并安装 Ollama
check_ollama() {
    if ! command -v ollama &> /dev/null; then
        log "安装 Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
    fi
}

# 检查模型是否存在
check_model() {
    # 等待 Ollama 服务启动
    sleep 5
    log "检查模型 ${OLLAMA_MODEL} ..."
    if ! ollama list | grep -q "${OLLAMA_MODEL}"; then
        log "模型不存在，开始下载 ${OLLAMA_MODEL} ..."
        ollama pull ${OLLAMA_MODEL}
    else
        log "模型 ${OLLAMA_MODEL} 已存在"
    fi
}

# 配置 Ngrok
setup_ngrok() {
    if [ -x "$(command -v ngrok)" ]; then
        log "配置 Ngrok..."
        ngrok config add-authtoken ${NGROK_AUTH_TOKEN}
    else
        log "错误: Ngrok 未安装成功"
        return 1
    fi
}

# 启动 Ollama 服务
start_ollama() {
    log "启动 Ollama 服务..."
    export OLLAMA_HOST=${OLLAMA_HOST}
    export OLLAMA_AUTH_TOKEN=${OLLAMA_AUTH_TOKEN}
    export OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
    export OLLAMA_ORIGINS=${OLLAMA_ORIGINS}
    
    pkill -f "ollama serve" >/dev/null 2>&1  # 确保旧进程已关闭
    /usr/local/bin/ollama serve >> ${OLLAMA_LOG} 2>&1 &
    sleep 10
    
    /usr/local/bin/ollama run ${OLLAMA_MODEL} >> ${OLLAMA_LOG} 2>&1 &
    log "Ollama 服务已启动"
}

# 启动 Ngrok
start_ngrok() {
    if [ -x "$(command -v ngrok)" ]; then
        log "启动 Ngrok 服务..."
        pkill -f "ngrok" >/dev/null 2>&1  # 确保旧进程已关闭
        nohup ngrok http --domain=${NGROK_DOMAIN} ${OLLAMA_PORT} >> ${NGROK_LOG} 2>&1 &
        log "Ngrok 服务已启动"
    else
        log "错误: 无法启动 Ngrok 服务"
    fi
}

# 检查服务状态
check_service_status() {
    sleep 5
    if pgrep -f "ollama serve" > /dev/null; then
        log "Ollama 服务运行中"
    else
        log "警告: Ollama 服务未运行"
    fi

    if pgrep -f "ngrok" > /dev/null; then
        log "Ngrok 服务运行中"
    else
        log "警告: Ngrok 服务未运行"
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
    setup_ngrok
    start_ngrok
    
    check_service_status
    log "所有服务启动完成"
}

main
