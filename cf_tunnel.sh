#!/bin/bash
#
# Cloudflare Tunnel 自动配置脚本
# 功能：自动创建和配置 Cloudflare Tunnel，支持自动DNS配置
# 使用方法：./cf.sh
#

# --- 严格模式设置 ---
# 允许某些命令失败但继续执行
set -u  # 使用未定义的变量时报错
trap 'error_handler $? $LINENO $BASH_LINENO "$BASH_COMMAND" $(printf "::%s" ${FUNCNAME[@]:-})' ERR

# --- 配置参数 (请修改这些参数) ---
TUNNEL_NAME="tx-openwebui"  # 隧道名称
DOMAIN_NAME="tx.apt.us.kg" # 你的二级域名
LOCAL_PORT="8080"       # 本地服务端口
LOCAL_IP="127.0.0.1"   # 本地监听IP，可选：127.0.0.1（仅本机）或 0.0.0.0（所有网卡）
API_TOKEN="xx" # Cloudflare API Token

# --- 常量定义 ---
readonly CLOUDFLARED_URL='https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64'
readonly CLOUDFLARED_BIN='/usr/local/bin/cloudflared'
readonly CONFIG_DIR='/etc/cloudflared'
readonly CRED_DIR='/root/.cloudflared'
readonly LOG_FILE='/var/log/cloudflared.log'
readonly PID_FILE='/var/run/cloudflared.pid'

# --- 颜色定义 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly RESET='\033[0m'

# --- 函数：打印消息 ---
print_message() {
    echo -e "${1}${2}${RESET}"
}

# --- 函数：安装依赖 ---
install_dependencies() {
    print_message "${YELLOW}" "正在安装依赖..."
    if command -v apt-get >/dev/null; then
        apt-get update >/dev/null 2>&1
        apt-get install -y curl jq >/dev/null 2>&1
    elif command -v yum >/dev/null; then
        yum install -y curl jq >/dev/null 2>&1
    fi
    print_message "${GREEN}" "依赖安装完成"
}

# --- 函数：清理旧隧道 ---
cleanup_tunnel() {
    local tunnel_id=$1
    print_message "${YELLOW}" "正在清理隧道 ${tunnel_id}..."
    
    # 先尝试停止所有运行中的程
    if [[ -f "${PID_FILE}" ]]; then
        local old_pid=$(cat "${PID_FILE}")
        if kill -0 "${old_pid}" 2>/dev/null; then
            print_message "${YELLOW}" "停止运行中的隧道进程..."
            kill "${old_pid}" 2>/dev/null || true
            sleep 5
        fi
        rm -f "${PID_FILE}"
    fi

    # 查找并终止所有cloudflared进程
    print_message "${YELLOW}" "检查运行中的cloudflared进程..."
    pkill -f "cloudflared.*tunnel.*run" || true
    sleep 2

    # 运行cleanup命令
    print_message "${YELLOW}" "清理隧道连接..."
    ${CLOUDFLARED_BIN} tunnel cleanup "${tunnel_id}" >/dev/null 2>&1 || true
    sleep 2

    # 现在尝试删除隧道
    print_message "${YELLOW}" "删除隧道..."
    DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/tunnels/${tunnel_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if ! echo "${DELETE_RESPONSE}" | jq -e '.success' >/dev/null; then
        local error_msg=$(echo "${DELETE_RESPONSE}" | jq -r '.errors[0].message // "未知错误"')
        if [[ "${error_msg}" == *"active connections"* ]]; then
            print_message "${YELLOW}" "仍有活动连接，等待后重试..."
            sleep 10
            ${CLOUDFLARED_BIN} tunnel cleanup "${tunnel_id}" >/dev/null 2>&1 || true
            sleep 2
            DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/tunnels/${tunnel_id}" \
                -H "Authorization: Bearer ${API_TOKEN}" \
                -H "Content-Type: application/json")
            
            if ! echo "${DELETE_RESPONSE}" | jq -e '.success' >/dev/null; then
                print_message "${RED}" "删除隧道失败: $(echo "${DELETE_RESPONSE}" | jq -r '.errors[0].message // "未知错误"')"
                return 1
            fi
        else
            print_message "${RED}" "删除隧道失败: ${error_msg}"
            return 1
        fi
    fi
    
    print_message "${GREEN}" "隧道清理完成"
    return 0
}

# --- 函数：显示配置信息 ---
show_config() {
    print_message "${BLUE}" "当前配置信息:"
    echo -e "${GREEN}隧道名称:${RESET} ${TUNNEL_NAME}"
    echo -e "${GREEN}域名:${RESET} ${DOMAIN_NAME}"
    echo -e "${GREEN}本地端口:${RESET} ${LOCAL_PORT}"
    echo -e "${GREEN}本地监听IP:${RESET} ${LOCAL_IP}"
    echo
}

# --- 函数：验证配置 ---
validate_config() {
    # ���证IP地址格式
    if [[ ! "${LOCAL_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_message "${RED}" "错误: 无效的IP地址格式: ${LOCAL_IP}"
        exit 1
    fi
    
    # 验证是否是有效的监听地址
    if [[ "${LOCAL_IP}" != "127.0.0.1" && "${LOCAL_IP}" != "0.0.0.0" ]]; then
        print_message "${YELLOW}" "警告: 建议使用 127.0.0.1（仅本机）或 0.0.0.0（所有网卡）作为监听地址"
    fi
}

# --- 函数：安装和配置 cloudflared ---
install_cloudflared() {
    # 安装 cloudflared
    if [[ ! -f "${CLOUDFLARED_BIN}" ]]; then
        print_message "${YELLOW}" "正在安装 cloudflared..."
        curl -sL "${CLOUDFLARED_URL}" -o "${CLOUDFLARED_BIN}"
        chmod +x "${CLOUDFLARED_BIN}"
        print_message "${GREEN}" "cloudflared 安装完成"
    fi
    
    # 清理旧配置
    print_message "${YELLOW}" "正在清理旧配置..."
    rm -rf "${CONFIG_DIR}" "${CRED_DIR}"
    mkdir -p "${CONFIG_DIR}" "${CRED_DIR}"
    
    # 获取账户信息
    print_message "${YELLOW}" "正在获取账户信息..."
    ACCOUNT_INFO=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    ACCOUNT_ID=$(echo "${ACCOUNT_INFO}" | jq -r '.result[0].id')
    
    if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "null" ]]; then
        print_message "${RED}" "获取账户信息失败，请检查API Token是否有效"
        exit 1
    fi

    # 创建隧道
    print_message "${YELLOW}" "正在创建隧道..."
    
    # 先检查是否存在同名隧道
    print_message "${YELLOW}" "检查是否存在同名隧道..."
    
    # 使用正确的API端点获取隧道列表
    TUNNELS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/tunnels?is_deleted=false" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if ! echo "${TUNNELS_RESPONSE}" | jq -e '.success' >/dev/null; then
        print_message "${RED}" "获取隧道列表失败: $(echo "${TUNNELS_RESPONSE}" | jq -r '.errors[0].message // "未知错误"')"
        exit 1
    fi
    
    EXISTING_TUNNEL=$(echo "${TUNNELS_RESPONSE}" | jq -r --arg name "${TUNNEL_NAME}" '.result[] | select(.name==$name) | .id')

    if [[ ! -z "${EXISTING_TUNNEL}" ]]; then
        print_message "${YELLOW}" "发现同名隧道，正在删除..."
        if ! cleanup_tunnel "${EXISTING_TUNNEL}"; then
            print_message "${RED}" "无法清理旧隧道��请手动处理或稍后重试"
            exit 1
        fi
    fi
    
    # 创建新隧道
    print_message "${YELLOW}" "正在创建新隧道..."
    MAX_CREATE_RETRIES=3
    for i in $(seq 1 $MAX_CREATE_RETRIES); do
        print_message "${YELLOW}" "尝试创建隧道... (尝试 ${i}/${MAX_CREATE_RETRIES})"
        
        # 生成随机的隧道密钥
        TUNNEL_SECRET=$(openssl rand -hex 32)
        
        TUNNEL_CREATE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/tunnels" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"${TUNNEL_NAME}\",
                \"tunnel_secret\": \"${TUNNEL_SECRET}\"
            }")
        
        if ! echo "${TUNNEL_CREATE_RESPONSE}" | jq -e '.success' >/dev/null; then
            ERROR_MSG=$(echo "${TUNNEL_CREATE_RESPONSE}" | jq -r '.errors[0].message // "未知错误"')
            if [[ $i -eq $MAX_CREATE_RETRIES ]]; then
                print_message "${RED}" "创建隧道失败: ${ERROR_MSG}"
                exit 1
            else
                print_message "${YELLOW}" "创建失败，等待后重试... (20秒)"
                sleep 20
                continue
            fi
        fi
        
        TUNNEL_ID=$(echo "${TUNNEL_CREATE_RESPONSE}" | jq -r '.result.id')
        
        if [[ ! -z "${TUNNEL_ID}" && "${TUNNEL_ID}" != "null" ]]; then
            print_message "${GREEN}" "隧道创建成功，ID: ${TUNNEL_ID}"
            
            # 创建凭证文件
            print_message "${YELLOW}" "正在创建隧道凭证..."
            mkdir -p "${CRED_DIR}"
            cat > "${CRED_DIR}/${TUNNEL_ID}.json" <<EOL
{
    "AccountTag": "${ACCOUNT_ID}",
    "TunnelID": "${TUNNEL_ID}",
    "TunnelName": "${TUNNEL_NAME}",
    "TunnelSecret": "${TUNNEL_SECRET}"
}
EOL
            chmod 600 "${CRED_DIR}/${TUNNEL_ID}.json"
            
            # 更新配置文件
            cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_DIR}/${TUNNEL_ID}.json
ingress:
  - hostname: ${DOMAIN_NAME}
    service: http://${LOCAL_IP}:${LOCAL_PORT}
  - service: http_status:404
protocol: http2
metrics: localhost:20241
EOL
            chmod 600 "${CONFIG_DIR}/config.yml"
            
            break
        fi
    done

    # 配置 DNS
    print_message "${YELLOW}" "正在配置DNS记录..."
    
    # 修改域名解析逻辑
    print_message "${YELLOW}" "正在解析域名结构..."
    
    # 获取所有zones
    ZONES_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    # 调试输出
    echo "Zones Response: ${ZONES_RESPONSE}" > /tmp/cf_debug.log
    
    # 从最长到最短尝试匹配域名
    DOMAIN_PARTS=(${DOMAIN_NAME//./ })
    DOMAIN_LENGTH=${#DOMAIN_PARTS[@]}
    ZONE_ID=""
    ZONE_NAME=""
    
    # 从完整域名开始，逐步尝试更短的域名组合
    for ((i=1; i<=${DOMAIN_LENGTH}-1; i++)); do
        # 从后往前取i个部分组成域名
        POSSIBLE_DOMAIN=""
        for ((j=DOMAIN_LENGTH-i; j<DOMAIN_LENGTH; j++)); do
            if [[ -z "${POSSIBLE_DOMAIN}" ]]; then
                POSSIBLE_DOMAIN="${DOMAIN_PARTS[j]}"
            else
                POSSIBLE_DOMAIN="${POSSIBLE_DOMAIN}.${DOMAIN_PARTS[j]}"
            fi
        done
        
        print_message "${YELLOW}" "尝试查找域名: ${POSSIBLE_DOMAIN}"
        
        # 查找匹配的zone
        TEMP_ZONE_ID=$(echo "${ZONES_RESPONSE}" | jq -r --arg domain "${POSSIBLE_DOMAIN}" '.result[] | select(.name==$domain) | .id')
        
        if [[ ! -z "${TEMP_ZONE_ID}" && "${TEMP_ZONE_ID}" != "null" ]]; then
            ZONE_ID="${TEMP_ZONE_ID}"
            ZONE_NAME="${POSSIBLE_DOMAIN}"
            break
        fi
    done

    if [[ -z "${ZONE_ID}" ]]; then
        print_message "${RED}" "无法找到有效的Zone，尝试过的域名组合："
        for ((i=1; i<=${DOMAIN_LENGTH}-1; i++)); do
            POSSIBLE_DOMAIN=""
            for ((j=DOMAIN_LENGTH-i; j<DOMAIN_LENGTH; j++)); do
                if [[ -z "${POSSIBLE_DOMAIN}" ]]; then
                    POSSIBLE_DOMAIN="${DOMAIN_PARTS[j]}"
                else
                    POSSIBLE_DOMAIN="${POSSIBLE_DOMAIN}.${DOMAIN_PARTS[j]}"
                fi
            done
            print_message "${RED}" "- ${POSSIBLE_DOMAIN}"
        done
        print_message "${RED}" "请确保您的API Token有权限访问正确的域名Zone"
        exit 1
    fi

    print_message "${GREEN}" "找到匹配的Zone: ${ZONE_NAME} (ID: ${ZONE_ID})"

    # 删除可能存在的旧DNS记录
    print_message "${YELLOW}" "正在清理旧的DNS记录..."
    OLD_RECORDS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DOMAIN_NAME}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" | jq -r '.result[].id')
    
    for record_id in $OLD_RECORDS; do
        print_message "${YELLOW}" "删除DNS记录: ${record_id}"
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" >/dev/null 2>&1
    done

    # 创建CNAME记录
    print_message "${YELLOW}" "正在创建新的DNS记录: ${DOMAIN_NAME} -> ${TUNNEL_ID}.cfargotunnel.com"
    DNS_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"CNAME\",
            \"name\": \"${DOMAIN_NAME}\",
            \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
            \"proxied\": true
        }")

    if ! echo "${DNS_RESPONSE}" | jq -e '.success' >/dev/null; then
        print_message "${RED}" "配置DNS记录失败"
        print_message "${RED}" "错误信息: $(echo "${DNS_RESPONSE}" | jq -r '.errors[0].message // "未知错误"')"
        exit 1
    fi

    print_message "${GREEN}" "DNS记录配置完成"
}

# --- 函数：启动隧道服务 ---
start_tunnel() {
    print_message "${YELLOW}" "正在启动隧道服务..."
    
    # 配置系统参数
    print_message "${YELLOW}" "配置系统参数..."
    if [ "$(id -u)" -eq 0 ]; then
        # 设置系统参数，允许失败
        ulimit -n 65535 2>/dev/null || true
        sysctl -w net.core.rmem_max=2500000 >/dev/null 2>&1 || true
        sysctl -w net.core.wmem_max=2500000 >/dev/null 2>&1 || true
        sysctl -w net.core.rmem_default=1000000 >/dev/null 2>&1 || true
        sysctl -w net.core.wmem_default=1000000 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_rmem="4096 87380 2500000" >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_wmem="4096 87380 2500000" >/dev/null 2>&1 || true
    else
        print_message "${YELLOW}" "警告: 非root用户，无法设置系统参数"
    fi
    
    # 检查是否真正支持 systemd
    if ps --no-headers -o comm 1 2>/dev/null | grep -q systemd; then
        print_message "${YELLOW}" "使用 systemd 启动服务..."
        # 创建系统服务
        cat > "/etc/systemd/system/cloudflared.service" <<EOL
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${CONFIG_DIR}/config.yml run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

        if systemctl daemon-reload && \
           systemctl enable cloudflared >/dev/null 2>&1 && \
           systemctl restart cloudflared && \
           systemctl is-active cloudflared >/dev/null 2>&1; then
            print_message "${GREEN}" "systemd 服务启动成功"
        else
            print_message "${YELLOW}" "systemd 服务启动失败，尝试其他方式..."
            USE_ALTERNATIVE=true
        fi
    else
        print_message "${YELLOW}" "系统不支持 systemd，使用替代方式..."
        USE_ALTERNATIVE=true
    fi

    # 如果 systemd 不可用或启动失败，使用替代方式
    if [[ "${USE_ALTERNATIVE}" == "true" ]]; then
        # 创建必要的目录
        mkdir -p "/var/run" "/var/log"
        
        # 检查是否已经运行
        if [[ -f "/var/run/cloudflared.pid" ]]; then
            OLD_PID=$(cat "/var/run/cloudflared.pid")
            if kill -0 "${OLD_PID}" 2>/dev/null; then
                print_message "${YELLOW}" "发现运行中的进程，正在停止..."
                kill "${OLD_PID}" 2>/dev/null
                sleep 2
            fi
            rm -f "/var/run/cloudflared.pid"
        fi

        print_message "${YELLOW}" "使用后台进程方式启动服务..."
        
        # 创建启动脚本
        cat > "${CONFIG_DIR}/start.sh" <<EOL
#!/bin/bash
# 设置环境变量
export TUNNEL_METRICS="localhost:20241"
export TUNNEL_LOGLEVEL="info"
export TUNNEL_RETRIES=5
export TUNNEL_GRACE_PERIOD=30s

# 启动服务
exec ${CLOUDFLARED_BIN} tunnel --config ${CONFIG_DIR}/config.yml run
EOL
        chmod +x "${CONFIG_DIR}/start.sh"
        
        # 启动服务
        nohup "${CONFIG_DIR}/start.sh" > /var/log/cloudflared.log 2>&1 &
        NEW_PID=$!
        echo ${NEW_PID} > /var/run/cloudflared.pid
        
        # 等待检查服务是否启动
        print_message "${YELLOW}" "等待服务启动..."
        for i in {1..12}; do
            sleep 5
            if ! kill -0 "${NEW_PID}" 2>/dev/null; then
                print_message "${RED}" "服务启动失败，错误日志："
                tail -n 10 /var/log/cloudflared.log
                exit 1
            fi
            
            # 检查日志中的成功标记，允许更多的成功标记
            if grep -q "Registered tunnel connection" /var/log/cloudflared.log 2>/dev/null || \
               grep -q "Connection registered" /var/log/cloudflared.log 2>/dev/null || \
               grep -q "Initial protocol http2" /var/log/cloudflared.log 2>/dev/null; then
                print_message "${GREEN}" "服务启动成功"
                return 0
            fi
            
            # 检查是否凭证错误
            if grep -q "Invalid tunnel secret" /var/log/cloudflared.log 2>/dev/null; then
                print_message "${RED}" "隧道凭证无效，请检查凭证文件..."
                exit 1
            fi
            
            if [[ $i -eq 12 ]]; then
                print_message "${RED}" "服务启动超时，最近的日志："
                tail -n 10 /var/log/cloudflared.log
                exit 1
            fi
            
            print_message "${YELLOW}" "等待服务启动中... (${i}/12)"
        done
    fi

    print_message "${GREEN}" "隧道服务已启动"
    print_message "${GREEN}" "域名 ${DOMAIN_NAME} 已配置完成，请等待DNS生效（通常需要几分钟）"
    print_message "${GREEN}" "服务日志位置: /var/log/cloudflared.log"
    print_message "${YELLOW}" "提示: 如需查看实时日志，请运行: tail -f /var/log/cloudflared.log"
}

# --- 函数：检查必要条件 ---
check_prerequisites() {
    # 检查是否为root用户
    if [ "$(id -u)" != "0" ]; then
        print_message "${RED}" "错误: 此脚本需要root权限运行"
        exit 1
    fi

    # 检查必要的命令
    local required_commands=("curl" "jq")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            print_message "${RED}" "错误: 未找到命令 '$cmd'"
            exit 1
        fi
    done
}

# --- 函数：显示使用说明 ---
show_usage() {
    echo -e "${BLUE}Cloudflare Tunnel 配置脚本使用说明${RESET}

${GREEN}配置文件位置:${RESET}
  - 主配置文件: ${CONFIG_DIR}/config.yml
  - 凭证文件: ${CRED_DIR}/<tunnel-id>.json
  - 日志文件: ${LOG_FILE}
  - PID文件: ${PID_FILE}

${GREEN}当前配置:${RESET}
  - 监听地址: ${LOCAL_IP}:${LOCAL_PORT}
  - 域名: ${DOMAIN_NAME}
  - 隧道名称: ${TUNNEL_NAME}

${GREEN}常用命令:${RESET}
  查看隧道状态:
    cloudflared tunnel status
  
  查看实时日志:
    tail -f ${LOG_FILE}
  
  停止隧道服务:
    kill \$(cat ${PID_FILE})
  
  重启隧道服务:
    kill \$(cat ${PID_FILE}); ./cf.sh

${GREEN}故障排除:${RESET}
  1. 检查隧道状态:
     cloudflared tunnel info
  
  2. 检查日志文件:
     tail -n 50 ${LOG_FILE}
  
  3. 验证DNS记录:
     dig ${DOMAIN_NAME}
  
  4. 检查本地服务:
     curl -v http://${LOCAL_IP}:${LOCAL_PORT}

${GREEN}注意事项:${RESET}
  - DNS生效可能需要几分钟时间
  - 确保本地服务在 ${LOCAL_IP}:${LOCAL_PORT} 正常运行
  - 如需修改配置，请编辑 ${CONFIG_DIR}/config.yml
  - 使用 127.0.0.1 仅允许本机访问
  - 使用 0.0.0.0 允许所有网卡访问

${YELLOW}API Tokens权限配置${RESET}
   Account > Cloudflare Tunnel > Edit
   Account > SSL and Certificates > Edit
   Zone > DNS > Edit
   Zone > Zone > Read"
}

# --- 函数：清理资源 ---
cleanup() {
    # 只在真正的错误发生时执行清理
    local exit_code=$?
    case $exit_code in
        0|100|130|137|143) return ;;
    esac

    print_message "${RED}" "脚本执行失败，退出码: $exit_code"
    if [ -f "${LOG_FILE}" ]; then
        print_message "${YELLOW}" "最后的日志内容:"
        tail -n 10 "${LOG_FILE}"
    fi
}

# --- 函数：错误处理 ---
error_handler() {
    local exit_code=$1
    local line_no=$2
    local bash_lineno=$3
    local last_command=$4
    local func_trace=$5

    # 某些错误是可以忽略的
    case $exit_code in
        0) return ;;  # 不是错误
        100) return ;;  # cloudflared 的正常退出
        130) return ;;  # Ctrl+C
        137) return ;;  # kill -9
        143) return ;;  # kill
    esac

    # 如果是系统命令失败，不终止脚本
    if [[ "$last_command" =~ ^(sysctl|ulimit|kill|systemctl) ]]; then
        return
    fi

    # 其他错误则显示错误信息
    print_message "${RED}" "错误: 命令 '$last_command' 失败"
    print_message "${RED}" "位置: 第 $line_no 行"
    print_message "${RED}" "退出码: $exit_code"

    if [ -f "${LOG_FILE}" ]; then
        print_message "${YELLOW}" "最后的日志内容:"
        tail -n 10 "${LOG_FILE}"
    fi
}

# --- 主程序 ---
main() {
    # 设置清理钩子
    trap cleanup EXIT

    # 检查必要条件
    check_prerequisites

    # 执行主要功能
    install_dependencies
    install_cloudflared
    start_tunnel

    # 显示使用说明
    show_usage
}

# --- 主程序开始前设置 ---
# 设置脚本使用UTF-8编码
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 执行主程序
main "$@"
