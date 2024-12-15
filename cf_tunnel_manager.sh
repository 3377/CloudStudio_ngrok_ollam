#!/bin/bash
#
# Cloudflare Tunnel 管理工具
# 功能：管理和配置 Cloudflare Tunnel，支持多隧道管理
# 使用方法：./cf.sh
#

# --- 严格模式设置 ---
set -u
trap 'error_handler $? $LINENO $BASH_LINENO "$BASH_COMMAND" $(printf "::%s" ${FUNCNAME[@]:-})' ERR

# --- 配置参数 (默认值) ---
TUNNEL_NAME="tx-openwebui"  # 默认隧道名称
DOMAIN_NAME="tx.apt.us.kg" # 默认二级域名
LOCAL_PORT="8080"       # 默认本地服务端口
LOCAL_IP="0.0.0.0"   # 默认本地监听IP
API_TOKEN="" # 默认 Cloudflare API Token

# --- 常量定义 ---
readonly CLOUDFLARED_URL='https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64'
readonly CLOUDFLARED_BIN='/usr/local/bin/cloudflared'
readonly CONFIG_DIR='/etc/cloudflared'
readonly CRED_DIR='/root/.cloudflared'
readonly LOG_FILE='/var/log/cloudflared.log'
readonly PID_FILE='/var/run/cloudflared.pid'
readonly SERVICE_FILE='/etc/systemd/system/cloudflared.service'
readonly RC_LOCAL_FILE='/etc/rc.local'
readonly INIT_SCRIPT='/etc/init.d/cloudflared'

# --- 颜色定义 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

# --- 函数：打印消息 ---
print_message() {
    echo -e "${1}${2}${RESET}"
}

# --- 函数：显示主菜单 ---
show_main_menu() {
    clear
    echo -e "${BLUE}=== Cloudflare Tunnel 管理工具 ===${RESET}\n"
    echo -e "${GREEN}1.${RESET} 查看隧道状态"
    echo -e "${GREEN}2.${RESET} 新增隧道"
    echo -e "${GREEN}3.${RESET} 服务管理"
    echo -e "${GREEN}0.${RESET} 退出\n"
    echo -n "请选择操作 [0-3]: "
}

# --- 函数：显示隧道状态 ---
show_tunnel_status() {
    while true; do
        clear
        echo -e "${BLUE}=== 隧道状态 ===${RESET}\n"
        
        # 获取账户信息
        local account_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        local account_id=$(echo "${account_info}" | jq -r '.result[0].id')
        
        if [[ -z "${account_id}" || "${account_id}" == "null" ]]; then
            print_message "${RED}" "获取账户信息失败，请检查API Token是否有效"
            return 1
        fi
        
        # 获取所有隧道
        local tunnels_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        if ! echo "${tunnels_response}" | jq -e '.success' >/dev/null; then
            print_message "${RED}" "获取隧道列表失败"
            return 1
        fi
        
        # 获取所有区域信息
        local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        # 显示表头
        printf "序号  ID                                         名称           类型     状态             域名                            自启动\n"
        printf "%s\n" "======================================================================================================================"
        
        # 创建关联数组存储隧道ID
        declare -A tunnel_ids
        local index=1
        
        # 处理每个隧道
        while read -r tunnel_b64; do
            # 解码隧道信息
            local tunnel_json=$(echo "${tunnel_b64}" | base64 --decode)
            local tunnel_id=$(echo "${tunnel_json}" | jq -r '.id')
            local tunnel_name=$(echo "${tunnel_json}" | jq -r '.name')
            local tunnel_status=$(echo "${tunnel_json}" | jq -r '.status')
            
            # 存储隧道ID和序号的对应关系
            tunnel_ids[$index]="${tunnel_id}"
            
            # 获取隧道的DNS记录
            local tunnel_hostnames=""
            local tunnel_cname="${tunnel_id}.cfargotunnel.com"
            
            # 遍历所有区域查找CNAME记录
            while read -r zone_id; do
                if [[ -n "${zone_id}" ]]; then
                    local dns_records=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME" \
                        -H "Authorization: Bearer ${API_TOKEN}" \
                        -H "Content-Type: application/json")
                    
                    # 提取指向此隧道的所有域名
                    local zone_domains=$(echo "${dns_records}" | jq -r --arg cname "${tunnel_cname}" '.result[] | select(.content == $cname) | .name' | sort -u | paste -sd "," -)
                    
                    if [[ -n "${zone_domains}" && "${zone_domains}" != "null" ]]; then
                        if [[ -n "${tunnel_hostnames}" ]]; then
                            tunnel_hostnames="${tunnel_hostnames},${zone_domains}"
                        else
                            tunnel_hostnames="${zone_domains}"
                        fi
                    fi
                fi
            done < <(echo "${zones_response}" | jq -r '.result[].id')
            
            # 如果没有找到DNS记录，尝试从配置中获取
            if [[ -z "${tunnel_hostnames}" || "${tunnel_hostnames}" == "null" ]]; then
                local config_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}/configurations" \
                    -H "Authorization: Bearer ${API_TOKEN}" \
                    -H "Content-Type: application/json")
                
                if echo "${config_response}" | jq -e '.success' >/dev/null; then
                    tunnel_hostnames=$(echo "${config_response}" | jq -r '.result.config.ingress[] | select(.hostname != null and .hostname != "") | .hostname' 2>/dev/null | sort -u | paste -sd "," -)
                fi
            fi
            
            # 如果还是没有找到域名，标记为未配置
            if [[ -z "${tunnel_hostnames}" || "${tunnel_hostnames}" == "null" ]]; then
                tunnel_hostnames="未配置"
            fi
            
            # 检查自启动状态
            local autostart="否"
            if is_tunnel_autostart "${tunnel_id}"; then
                autostart="是"
            fi
            
            # 如果域名太长，截断并添加省略号
            if [[ ${#tunnel_hostnames} -gt 32 ]]; then
                tunnel_hostnames="${tunnel_hostnames:0:29}..."
            fi
            
            # 获取隧道类型
            local tunnel_type="HTTPS"
            local config_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}/configurations" \
                -H "Authorization: Bearer ${API_TOKEN}" \
                -H "Content-Type: application/json")
            
            # 首先尝试从配置中获取实际类型
            if echo "${config_response}" | jq -e '.success' >/dev/null; then
                # 获取所有配置的服务类型
                local services=$(echo "${config_response}" | jq -r '.result.config.ingress[] | select(.service != null) | .service')
                
                # 根据服务配置判断类型
                if echo "${services}" | grep -q "ssh://"; then
                    tunnel_type="SSH"
                elif echo "${services}" | grep -q "rdp://"; then
                    tunnel_type="RDP"
                elif echo "${services}" | grep -q "tcp://"; then
                    tunnel_type="TCP"
                elif echo "${services}" | grep -q "udp://"; then
                    tunnel_type="UDP"
                elif echo "${services}" | grep -q "unix://"; then
                    tunnel_type="UNIX"
                elif echo "${services}" | grep -q "bastion"; then
                    tunnel_type="BASTION"
                elif echo "${services}" | grep -q "http://\|https://"; then
                    tunnel_type="HTTPS"
                fi
                
                # 如果没有找到匹配的类型，尝试从其他字段获取
                if [[ "${tunnel_type}" == "HTTPS" ]]; then
                    # 检查是否有特殊的配置标记
                    if echo "${config_response}" | jq -e '.result.config.warp_routing' >/dev/null 2>&1; then
                        tunnel_type="WARP"
                    elif echo "${config_response}" | jq -e '.result.config.proxy_type == "socks"' >/dev/null 2>&1; then
                        tunnel_type="SOCKS"
                    fi
                fi
            fi
            
            # 显示隧道信息（修改格式以包含类型）
            printf "%-5d %-39s    %-14s %-8s %-13s %-32s %5s\n" \
                "${index}" \
                "${tunnel_id}" \
                "${tunnel_name}" \
                "${tunnel_type}" \
                "${tunnel_status}" \
                "${tunnel_hostnames}" \
                "${autostart}"
            
            ((index++))
        done < <(echo "${tunnels_response}" | jq -r '.result[] | select(.deleted_at == null) | @base64')
        
        echo -e "\n${GREEN}1.${RESET} 删除隧道"
        echo -e "${GREEN}2.${RESET} 查看隧道详细信息"
        echo -e "${GREEN}0.${RESET} 返回主菜单"
        
        echo -n "请选择操作 [0-2]: "
        read -r choice
        
        case $choice in
            1)
                echo -n "请输入要删除的隧道序号（多个序号用空格分隔）: "
                read -r tunnel_indexes
                local success=true
                
                # 遍历每个序号
                for tunnel_index in $tunnel_indexes; do
                    if [[ -n "${tunnel_ids[$tunnel_index]}" ]]; then
                        if ! cleanup_tunnel "${tunnel_ids[$tunnel_index]}" "${account_id}"; then
                            print_message "${RED}" "隧道 ${tunnel_index} 删除失败"
                            success=false
                        else
                            print_message "${GREEN}" "隧道 ${tunnel_index} 删除成功"
                        fi
                    else
                        print_message "${RED}" "无效的隧道序号: ${tunnel_index}"
                        success=false
                    fi
                done
                
                if $success; then
                    print_message "${GREEN}" "所有选中的隧道删除完成"
                else
                    print_message "${YELLOW}" "部分隧道删除失败"
                fi
                sleep 2
                continue
                ;;
            2)
                echo -n "请输入要查看的隧道序号: "
                read -r tunnel_index
                if [[ -n "${tunnel_ids[$tunnel_index]}" ]]; then
                    show_tunnel_detail "${tunnel_ids[$tunnel_index]}" "${account_id}"
                    continue
                else
                    print_message "${RED}" "无效的隧道序号"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                print_message "${RED}" "无效的选择"
                ;;
        esac
        
        echo -e "\n按任意键继续..."
        read -n 1
    done
}

# --- 函数：显示连接器信息 ---
show_connector_info() {
    local conn_response=$1
    echo -e "\n${GREEN}连接器信息:${RESET}"
    if echo "${conn_response}" | jq -e '.result[0]' >/dev/null 2>&1; then
        while read -r conn; do
            if [[ -n "${conn}" ]]; then
                # 尝试从不同路径获取连接信息
                local conn_id=$(echo "${conn}" | jq -r '.id')
                local conn_data=$(echo "${conn}" | jq -r '.conns[0] // empty')
                
                if [[ -n "${conn_data}" ]]; then
                    local origin_ip=$(echo "${conn_data}" | jq -r '.clientIp // empty')
                    local platform=$(echo "${conn_data}" | jq -r '.os // .arch // empty')
                    local private_ip=$(echo "${conn_data}" | jq -r '.localIp // empty')
                    local hostname=$(echo "${conn_data}" | jq -r '.hostname // empty')
                    local version=$(echo "${conn_data}" | jq -r '.version // empty')
                    local location=$(echo "${conn_data}" | jq -r '.coloName // empty')
                    local protocol=$(echo "${conn_data}" | jq -r '.type // empty')
                    local uptime=$(echo "${conn_data}" | jq -r '.duration // empty')
                    local created_at=$(echo "${conn_data}" | jq -r '.connectedAt // empty')
                else
                    local origin_ip=$(echo "${conn}" | jq -r '.originIp // empty')
                    local platform=$(echo "${conn}" | jq -r '.arch // empty')
                    local private_ip=$(echo "${conn}" | jq -r '.localIp // empty')
                    local hostname=$(echo "${conn}" | jq -r '.hostname // empty')
                    local version=$(echo "${conn}" | jq -r '.version // empty')
                    local location=$(echo "${conn}" | jq -r '.location // empty')
                    local protocol=$(echo "${conn}" | jq -r '.protocol // empty')
                    local uptime=$(echo "${conn}" | jq -r '.uptime // empty')
                    local created_at=$(echo "${conn}" | jq -r '.createdAt // empty')
                fi
                
                echo -e "- Connector ID: ${conn_id}"
                [[ -n "${origin_ip}" ]] && echo -e "  Origin IP: ${origin_ip}"
                [[ -n "${platform}" ]] && echo -e "  Platform: ${platform}"
                [[ -n "${private_ip}" ]] && echo -e "  Private IP: ${private_ip}"
                [[ -n "${hostname}" ]] && echo -e "  Hostname: ${hostname}"
                [[ -n "${version}" ]] && echo -e "  Version: ${version}"
                [[ -n "${location}" ]] && echo -e "  Location: ${location}"
                [[ -n "${protocol}" ]] && echo -e "  Protocol: ${protocol}"
                [[ -n "${uptime}" ]] && echo -e "  Uptime: ${uptime}"
                [[ -n "${created_at}" ]] && echo -e "  Connected At: ${created_at}"
                
                # 调试信息
                echo -e "\n${YELLOW}原始连接数据:${RESET}"
                echo "${conn}" | jq '.'
            fi
        done < <(echo "${conn_response}" | jq -c '.result[]')
    else
        echo -e "无活动连接"
        # 调试信息
        echo -e "\n${YELLOW}原始响应数据:${RESET}"
        echo "${conn_response}" | jq '.'
    fi
}

# --- 函数：显示SSH客户端配置 ---
show_ssh_client_config() {
    local domain_name=$1
    echo -e "\n${GREEN}SSH 客户端配置:${RESET}"
    echo -e "1. Windows 系统:"
    echo -e "   a) 下载 cloudflared: https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    echo -e "   b) 重命名为 cloudflared.exe 并移动到 C:\\Windows\\System32\\"
    echo -e "   c) 连接命令: ssh -o ProxyCommand=\"C:\\Windows\\System32\\cloudflared.exe access ssh --hostname %h\" root@${domain_name}"
    echo -e "\n2. Linux/macOS 系统:"
    echo -e "   a) 安装 cloudflared:"
    echo -e "      检测系统架构..."
    echo -e "      arch=\$(uname -m)"
    echo -e "      case \"\${arch}\" in"
    echo -e "          x86_64|amd64)"
    echo -e "              curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
    echo -e "              ;;"
    echo -e "          aarch64|arm64)"
    echo -e "              curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
    echo -e "              ;;"
    echo -e "          armv7l)"
    echo -e "              curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm.deb"
    echo -e "              ;;"
    echo -e "          *)"
    echo -e "              echo \"不支持的架构: \${arch}\""
    echo -e "              exit 1"
    echo -e "              ;;"
    echo -e "      esac"
    echo -e "      sudo dpkg -i cloudflared.deb"
    echo -e "      macOS:"
    echo -e "      brew install cloudflare/cloudflare/cloudflared"
    echo -e "   b) 连接命令: ssh -o ProxyCommand=\"cloudflared access ssh --hostname %h\" root@${domain_name}"
    echo -e "\n3. 一键安装脚本:"
    echo -e "   Windows (管理员 PowerShell):"
    echo -e "   \$url = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'"
    echo -e "   Invoke-WebRequest -Uri \$url -OutFile C:\\Windows\\System32\\cloudflared.exe"
    echo -e "\n   Linux/macOS:"
    echo -e "   # 自动检测架构并安装"
    echo -e "   arch=\$(uname -m)"
    echo -e "   case \"\${arch}\" in"
    echo -e "       x86_64|amd64)"
    echo -e "           pkg_url=\"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb\""
    echo -e "           ;;"
    echo -e "       aarch64|arm64)"
    echo -e "           pkg_url=\"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb\""
    echo -e "           ;;"
    echo -e "       armv7l)"
    echo -e "           pkg_url=\"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm.deb\""
    echo -e "           ;;"
    echo -e "       *)"
    echo -e "           echo \"不支持的架构: \${arch}\""
    echo -e "           exit 1"
    echo -e "           ;;"
    echo -e "   esac"
    echo -e "   curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null"
    echo -e "   echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main' | sudo tee /etc/apt/sources.list.d/cloudflared.list"
    echo -e "   sudo apt update && sudo apt install cloudflared"
    echo -e "   # 如果 apt 安装失败，尝试直接下载 deb 包"
    echo -e "   if [ \$? -ne 0 ]; then"
    echo -e "       curl -L --output cloudflared.deb \"\${pkg_url}\""
    echo -e "       sudo dpkg -i cloudflared.deb"
    echo -e "   fi"
}

# --- 函数：显示隧道详细信息 ---
show_tunnel_detail() {
    local tunnel_id=$1
    local account_id=$2
    
    while true; do
        clear
        echo -e "${BLUE}=== 隧道详细信息 ===${RESET}\n"
        
        # 获取隧道基本信息
        local tunnel_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        # 获取隧道配置信息
        local config_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}/configurations" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        # 获取隧道连接信息
        local conn_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}/connections" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        # 提取基本信息
        local name=$(echo "${tunnel_info}" | jq -r '.result.name')
        local status=$(echo "${tunnel_info}" | jq -r '.result.status')
        local created_at=$(echo "${tunnel_info}" | jq -r '.result.created_at')
        local tunnel_type="HTTP"
        
        # 判断隧道类型
        if echo "${config_response}" | jq -e '.result.config.ingress[] | select(.service | contains("ssh://"))' >/dev/null 2>&1; then
            tunnel_type="SSH"
        fi
        
        echo -e "${GREEN}基本信息:${RESET}"
        echo -e "ID: ${tunnel_id}"
        echo -e "名称: ${name}"
        echo -e "类型: ${tunnel_type}"
        echo -e "状态: ${status}"
        echo -e "创建时间: ${created_at}"
        
        # 显示连接器信息
        show_connector_info "${conn_response}"
        
        # 如果是 SSH 隧道，显示客户端配置说明
        if [[ "${tunnel_type}" == "SSH" ]]; then
            show_ssh_client_config "${DOMAIN_NAME}"
        fi
        
        echo -e "\n${GREEN}0.${RESET} 返回上一级"
        echo -n "请选择 [0]: "
        read -r choice
        
        case $choice in
            0|"")
                break
                ;;
            *)
                continue
                ;;
        esac
    done
}

# --- 函数：新增隧道菜单 ---
show_new_tunnel_menu() {
    clear
    echo -e "${BLUE}=== 新增隧道 ===${RESET}\n"
    echo -e "${GREEN}1.${RESET} 静默方式（用默认配置）"
    echo -e "${GREEN}2.${RESET} 引导式新增"
    echo -e "${GREEN}0.${RESET} 返回主菜单\n"
    echo -n "请选择操作 [0-2]: "
    
    read -r choice
    case $choice in
        1)
            create_tunnel "silent"
            ;;
        2)
            create_tunnel "guided"
            ;;
        0)
            return 0
            ;;
        *)
            print_message "${RED}" "无效的选择"
            ;;
    esac
    
    echo -e "\n按任意键继续..."
    read -n 1
}

# --- 函数：服务管理菜单 ---
show_service_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== 服务管理 ===${RESET}\n"
        
        # 获取所有隧道服务
        local services=($(systemctl list-units --type=service --all | grep 'cloudflared-' | awk '{print $1}'))
        
        echo -e "当前隧道服务列表:"
        if [ ${#services[@]} -eq 0 ]; then
            echo -e "${YELLOW}未发现任何隧道服务${RESET}"
        else
            echo -e "\n序号  服务名称                状态      自启动"
            echo -e "================================================="
            local index=1
            for service in "${services[@]}"; do
                local status=$(systemctl is-active "${service}")
                local enabled=$(systemctl is-enabled "${service}" 2>/dev/null)
                printf "%-5d %-24s %-10s %s\n" "${index}" "${service}" "${status}" "${enabled}"
                ((index++))
            done
        fi
        
        echo -e "\n${GREEN}1.${RESET} 启动服务"
        echo -e "${GREEN}2.${RESET} 停止服务"
        echo -e "${GREEN}3.${RESET} 重启服务"
        echo -e "${GREEN}4.${RESET} 查看服务状态"
        echo -e "${GREEN}5.${RESET} 查看服务日志"
        echo -e "${GREEN}6.${RESET} 设置开机自启"
        echo -e "${GREEN}0.${RESET} 返回主菜单\n"
        echo -n "请选择操作 [0-6]: "
        
        read -r choice
        case $choice in
            1|2|3|4|5)
                if [ ${#services[@]} -eq 0 ]; then
                    print_message "${RED}" "没有可用的隧道服务"
                    sleep 2
                    continue
                fi
                echo -n "请输入服务序号: "
                read -r service_index
                if [ "$service_index" -ge 1 ] && [ "$service_index" -le ${#services[@]} ]; then
                    local selected_service="${services[$((service_index-1))]}"
                    case $choice in
                        1)
                            systemctl start "${selected_service}"
                            print_message "${GREEN}" "服务已启动"
                            ;;
                        2)
                            systemctl stop "${selected_service}"
                            print_message "${GREEN}" "服务已停止"
                            ;;
                        3)
                            systemctl restart "${selected_service}"
                            print_message "${GREEN}" "服务已重启"
                            ;;
                        4)
                            clear
                            systemctl status "${selected_service}"
                            echo -e "\n按任意键继续..."
                            read -n 1
                            ;;
                        5)
                            clear
                            local log_file="/var/log/${selected_service%.*}.log"
                            if [ -f "${log_file}" ]; then
                                tail -f "${log_file}"
                            else
                                journalctl -u "${selected_service}" -f
                            fi
                            ;;
                    esac
                else
                    print_message "${RED}" "无效的服务序号"
                fi
                ;;
            6)
                if [ ${#services[@]} -eq 0 ]; then
                    print_message "${RED}" "没有可用的隧道服务"
                    sleep 2
                    continue
                fi
                echo -n "请输入服务序号: "
                read -r service_index
                if [ "$service_index" -ge 1 ] && [ "$service_index" -le ${#services[@]} ]; then
                    local selected_service="${services[$((service_index-1))]}"
                    systemctl enable "${selected_service}"
                    print_message "${GREEN}" "服务已设置为开机自启"
                else
                    print_message "${RED}" "无效的服务序号"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                print_message "${RED}" "无效的选择"
                ;;
        esac
        
        echo -e "\n按任意键继续..."
        read -n 1
    done
}

# --- 函数：创建新隧道 ---
create_tunnel() {
    local mode=${1:-"silent"}  # 添加默认值
    local tunnel_name=${TUNNEL_NAME}
    local domain_name=${DOMAIN_NAME}
    local local_port=${LOCAL_PORT}
    local local_ip=${LOCAL_IP}
    local api_token=${API_TOKEN}
    local service_type="http"  # 默认为http
    local tunnel_id=""  # 初始化tunnel_id变量
    
    # 确保 cloudflared 已安装
    if ! ensure_cloudflared; then
        print_message "${RED}" "无法继续：cloudflared 未安装或安装失败"
        return 1
    fi
    
    if [[ "${mode}" == "guided" ]]; then
        echo -e "\n${YELLOW}请输入隧道配置信息（直接回车使用默认值）：${RESET}"
        
        echo -n "隧道名称 [${tunnel_name}]: "
        read -r input
        [[ -n "${input}" ]] && tunnel_name="${input}"
        
        # 检查隧道名称是否已存在
        local account_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
            -H "Authorization: Bearer ${api_token}" \
            -H "Content-Type: application/json")
        local account_id=$(echo "${account_info}" | jq -r '.result[0].id')
        
        local existing_tunnel=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels" \
            -H "Authorization: Bearer ${api_token}" \
            -H "Content-Type: application/json" | \
            jq -r --arg name "${tunnel_name}" '.result[] | select(.name == $name and .deleted_at == null)')
        
        if [[ -n "${existing_tunnel}" ]]; then
            echo -e "\n${YELLOW}发现同名隧道，请选择操作：${RESET}"
            echo "1. 更新现有隧道配置"
            echo "2. 使用新的隧道名称"
            echo -n "请选择 [1/2]: "
            read -r choice
            
            case $choice in
                1)
                    tunnel_id=$(echo "${existing_tunnel}" | jq -r '.id')
                    ;;
                2)
                    echo -n "请输入新的隧道名称: "
                    read -r tunnel_name
                    tunnel_id=""  # 确保使用新名称时清空tunnel_id
                    ;;
                *)
                    print_message "${RED}" "无效的选择"
                    return 1
                    ;;
            esac
        fi
        
        echo -n "域名 [${domain_name}]: "
        read -r input
        [[ -n "${input}" ]] && domain_name="${input}"
        
        echo -e "\n${YELLOW}请选择服务类型：${RESET}"
        echo "1. HTTP/HTTPS 服务"
        echo "2. SSH 服务"
        echo -n "请选择 [1/2]: "
        read -r service_choice
        
        case $service_choice in
            1)
                service_type="http"
                echo -n "本地端口 [8080]: "
                read -r input
                [[ -n "${input}" ]] && local_port="${input}"
                ;;
            2)
                service_type="ssh"
                local_port="22"
                ;;
            *)
                print_message "${RED}" "无效的选择"
                return 1
                ;;
        esac
        
        echo -n "本地监听IP [${local_ip}]: "
        read -r input
        [[ -n "${input}" ]] && local_ip="${input}"
        
        # 修改API Token的处理逻
        echo -n "API Token [${api_token}]: "
        read -r input
        # 只有当用户输入了新值时才更新api_token
        [[ -n "${input}" ]] && api_token="${input}"
    fi
    
    # 设置临时变量
    TUNNEL_NAME="${tunnel_name}"
    DOMAIN_NAME="${domain_name}"
    LOCAL_PORT="${local_port}"
    LOCAL_IP="${local_ip}"
    API_TOKEN="${api_token}"  # 这里会使用默认值或用户输入的新值
    
    # 执行创建或更新
    if [[ -n "${tunnel_id}" ]]; then
        if update_tunnel_config "${tunnel_id}" "${service_type}"; then
            print_message "${GREEN}" "隧道配置更新成功"
            start_tunnel
        else
            print_message "${RED}" "隧道配置更新失败"
            return 1
        fi
    else
        if install_cloudflared && create_tunnel_config "${service_type}" && start_tunnel; then
            print_message "${GREEN}" "隧道创建成功"
        else
            print_message "${RED}" "隧道创建失败"
            return 1
        fi
    fi
}

# --- 函数：获取根域名 ---
get_root_domain() {
    local domain=$1
    local parts=(${domain//./ })
    local length=${#parts[@]}
    
    # 如果域名部分小于2，返回整个域名
    if [ $length -lt 2 ]; then
        echo "$domain"
        return
    fi
    
    # 尝试从最后往前找到可用的区域
    local root_domain=""
    for ((i=length-1; i>=0; i--)); do
        if [ $i -eq $((length-1)) ]; then
            root_domain="${parts[i]}"
        else
            root_domain="${parts[i]}.${root_domain}"
            # 检查这个组合是否是有效的区域
            local zone_check=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${root_domain}" \
                -H "Authorization: Bearer ${API_TOKEN}" \
                -H "Content-Type: application/json")
            
            if echo "${zone_check}" | jq -e '.result[0].id' >/dev/null 2>&1; then
                echo "${root_domain}"
                return
            fi
        fi
    done
    
    # 如果没有找到，返回两部
    echo "${parts[$((length-2))]}.${parts[$((length-1))]}"
}

# --- 函数：获取证书 ---
get_origin_cert() {
    # 由于我们使用API Token方式，不需要证书
    return 0
}

# --- 函数：创建隧道配置 ---
create_tunnel_config() {
    local service_type=${1:-"http"}
    print_message "${YELLOW}" "正在创建隧道配置..."
    
    # 创建必要的目录并设置权限
    mkdir -p "${CRED_DIR}" "${CONFIG_DIR}" "${HOME}/.cloudflared"
    chmod 755 "${CONFIG_DIR}"
    chmod 700 "${CRED_DIR}" "${HOME}/.cloudflared"
    
    # 获取账户ID
    print_message "${YELLOW}" "获取账户信息..."
    local account_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local account_id=$(echo "${account_info}" | jq -r '.result[0].id')
    
    if [[ -z "${account_id}" || "${account_id}" == "null" ]]; then
        print_message "${RED}" "获取账户信息失败，API响应："
        echo "${account_info}" | jq '.'
        return 1
    fi
    
    print_message "${GREEN}" "获取到账户ID: ${account_id}"
    
    # 检查是否存在同名隧道
    print_message "${YELLOW}" "检查现有隧道..."
    local existing_tunnel=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" | \
        jq -r --arg name "${TUNNEL_NAME}" '.result[] | select(.name == $name and .deleted_at == null)')
    
    local tunnel_id=""
    if [[ -n "${existing_tunnel}" ]]; then
        tunnel_id=$(echo "${existing_tunnel}" | jq -r '.id')
        print_message "${YELLOW}" "发现现有隧道:"
        print_message "${YELLOW}" "ID: ${tunnel_id}"
        print_message "${YELLOW}" "名称: ${TUNNEL_NAME}"
        
        # 验证现有隧道状态
        local tunnel_status=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        print_message "${YELLOW}" "隧道状态："
        echo "${tunnel_status}" | jq '.'
    else
        # 创建新隧道
        print_message "${YELLOW}" "创建新隧道..."
        
        # 生成随机密钥
        local tunnel_secret=$(openssl rand -hex 32)
        
        # 使用API创建隧道
        local create_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"name\":\"${TUNNEL_NAME}\",
                \"tunnel_secret\":\"${tunnel_secret}\"
            }")
        
        if ! echo "${create_response}" | jq -e '.success' >/dev/null; then
            print_message "${RED}" "创建隧道失败，API响应："
            echo "${create_response}" | jq '.'
            return 1
        fi
        
        tunnel_id=$(echo "${create_response}" | jq -r '.result.id')
        print_message "${GREEN}" "新隧道创建成功:"
        print_message "${GREEN}" "ID: ${tunnel_id}"
        
        # 创建凭证文件
        mkdir -p "${CRED_DIR}"
        cat > "${CRED_DIR}/${tunnel_id}.json" <<EOL
{
    "AccountTag": "$(echo "${create_response}" | jq -r '.result.account_tag')",
    "TunnelID": "${tunnel_id}",
    "TunnelSecret": "${tunnel_secret}"
}
EOL
        chmod 600 "${CRED_DIR}/${tunnel_id}.json"
    fi
    
    # 准备配置数据
    print_message "${YELLOW}" "创建配置文件..."
    if [[ "${service_type}" == "ssh" ]]; then
        # SSH 隧道配置
        cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${tunnel_id}
credentials-file: ${CRED_DIR}/${tunnel_id}.json
protocol: http2
ingress:
  - hostname: ${DOMAIN_NAME}
    service: ssh://127.0.0.1:22
    originRequest:
      noTLSVerify: true
      proxyType: direct
      tcpKeepAlive: 30s
      keepAliveTimeout: 30s
      keepAliveConnections: 10
  - service: http_status:404
metrics: 127.0.0.1:20241
EOL
        print_message "${GREEN}" "SSH隧道配置完成，连接信息："
        print_message "${GREEN}" "域名: ${DOMAIN_NAME}"
        print_message "${YELLOW}" "=== 客户端配置 ==="
        print_message "${YELLOW}" "1. Windows 系统:"
        print_message "${YELLOW}" "   下载: https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
        print_message "${YELLOW}" "   重命名为 cloudflared.exe 并移动到 C:\\Windows\\System32\\"
        print_message "${YELLOW}" "   连接命令: ssh -o ProxyCommand=\"C:\\Windows\\System32\\cloudflared.exe access ssh --hostname %h\" root@${DOMAIN_NAME}"
        print_message "${YELLOW}" ""
        print_message "${YELLOW}" "2. Linux/macOS 系统:"
        print_message "${YELLOW}" "   安装: curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
        print_message "${YELLOW}" "   sudo dpkg -i cloudflared.deb"
        print_message "${YELLOW}" "   连接命令: ssh -o ProxyCommand=\"cloudflared access ssh --hostname %h\" root@${DOMAIN_NAME}"
        print_message "${YELLOW}" ""
        print_message "${YELLOW}" "3. 一键安装脚本:"
        print_message "${YELLOW}" "   Windows (管理员 PowerShell):"
        print_message "${YELLOW}" '   $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"'
        print_message "${YELLOW}" '   Invoke-WebRequest -Uri $url -OutFile C:\Windows\System32\cloudflared.exe'
        print_message "${YELLOW}" ""
        print_message "${YELLOW}" "   Linux/macOS:"
        print_message "${YELLOW}" "   curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null"
        print_message "${YELLOW}" "   echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main' | sudo tee /etc/apt/sources.list.d/cloudflared.list"
        print_message "${YELLOW}" "   sudo apt update && sudo apt install cloudflared"
        echo -e "   # 如果 apt 安装失败，尝试直接下载 deb 包"
        echo -e "   if [ \$? -ne 0 ]; then"
        echo -e "       curl -L --output cloudflared.deb \"\${pkg_url}\""
        echo -e "       sudo dpkg -i cloudflared.deb"
        echo -e "   fi"
    else
        # HTTP/HTTPS 隧道配置
        cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${tunnel_id}
credentials-file: ${CRED_DIR}/${tunnel_id}.json
protocol: quic
originRequest:
  connectTimeout: 30s
  noTLSVerify: true
ingress:
  - hostname: ${DOMAIN_NAME}
    service: http://${LOCAL_IP}:${LOCAL_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOL
    fi
    
    chmod 644 "${CONFIG_DIR}/config.yml"
    
    # 验证配置文件
    print_message "${YELLOW}" "验证配置文件..."
    if ! ${CLOUDFLARED_BIN} tunnel ingress validate < "${CONFIG_DIR}/config.yml"; then
        print_message "${RED}" "配置文件验证失败"
        return 1
    fi
    
    # 配置DNS路由
    print_message "${YELLOW}" "配置隧道路由..."
    
    # 获取区域ID
    local root_domain=$(get_root_domain "${DOMAIN_NAME}")
    local zone_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${root_domain}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local zone_id=$(echo "${zone_info}" | jq -r '.result[0].id')
    if [[ -z "${zone_id}" || "${zone_id}" == "null" ]]; then
        print_message "${RED}" "获取区域ID失败，API响应："
        echo "${zone_info}" | jq '.'
        return 1
    fi
    
    print_message "${GREEN}" "获取到区域ID: ${zone_id}"
    
    # 创建或更新DNS记录
    local existing_record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${DOMAIN_NAME}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local record_id=$(echo "${existing_record}" | jq -r '.result[0].id // empty')
    local dns_response
    
    if [[ -n "${record_id}" ]]; then
        print_message "${YELLOW}" "更新现有DNS记录..."
        dns_response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\":\"CNAME\",
                \"name\":\"${DOMAIN_NAME}\",
                \"content\":\"${tunnel_id}.cfargotunnel.com\",
                \"proxied\":true,
                \"comment\":\"Managed by cloudflared\",
                \"tags\":[],
                \"ttl\":1
            }")
    else
        print_message "${YELLOW}" "创建新DNS记录..."
        dns_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\":\"CNAME\",
                \"name\":\"${DOMAIN_NAME}\",
                \"content\":\"${tunnel_id}.cfargotunnel.com\",
                \"proxied\":true,
                \"comment\":\"Managed by cloudflared\",
                \"tags\":[],
                \"ttl\":1
            }")
    fi
    
    if ! echo "${dns_response}" | jq -e '.success' >/dev/null; then
        print_message "${RED}" "配置DNS记录失败，API响应："
        echo "${dns_response}" | jq '.'
        return 1
    fi
    
    # 配置DNS设置
    print_message "${YELLOW}" "配置DNS设置..."
    local dns_settings_response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${zone_id}/settings/ipv6" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data '{"value":"off"}')
    
    if ! echo "${dns_settings_response}" | jq -e '.success' >/dev/null; then
        print_message "${YELLOW}" "警告: 无法禁用IPv6，API响应："
        echo "${dns_settings_response}" | jq '.'
    fi
    
    # 创建systemd服务
    print_message "${YELLOW}" "创建systemd服务..."
    cat > "${SERVICE_FILE}" <<EOL
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=root
Group=root
WorkingDirectory=/root
Environment=HOME=/root
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${CONFIG_DIR}/config.yml run
Restart=always
RestartSec=5
TimeoutStartSec=0
SendSIGKILL=no
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOL
    
    chmod 644 "${SERVICE_FILE}"
    
    print_message "${GREEN}" "隧道配置创建成功"
    print_message "${YELLOW}" "配置信息："
    print_message "${YELLOW}" "隧道ID: ${tunnel_id}"
    print_message "${YELLOW}" "域名: ${DOMAIN_NAME}"
    print_message "${YELLOW}" "配置文件: ${CONFIG_DIR}/config.yml"
    print_message "${YELLOW}" "凭证文件: ${CRED_DIR}/${tunnel_id}.json"
    print_message "${YELLOW}" "服务文件: ${SERVICE_FILE}"
    
    # 验证配置
    print_message "${YELLOW}" "验证隧道配置..."
    ${CLOUDFLARED_BIN} tunnel info "${tunnel_id}"
    
    # 添加 SSH 配置检查
    if [[ "${service_type}" == "ssh" ]]; then
        print_message "${YELLOW}" "检查 SSH 服务状态..."
        if ! systemctl is-active sshd >/dev/null 2>&1; then
            print_message "${RED}" "警告: SSH 服务未运行"
            print_message "${YELLOW}" "正在启动 SSH 服务..."
            systemctl start sshd
        fi

        print_message "${YELLOW}" "检查 SSH 端口..."
        if ! ss -tlnp | grep -q ':22 '; then
            print_message "${RED}" "警告: SSH 端口 22 未开放"
        fi

        # 检查防火墙规则
        print_message "${YELLOW}" "检查防火墙规则..."
        if command -v ufw >/dev/null 2>&1; then
            ufw allow 22/tcp >/dev/null 2>&1
        elif command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --add-port=22/tcp --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        fi
    fi
    
    return 0
}

# --- 函数：更新隧道配置 ---
update_tunnel_config() {
    local tunnel_id=$1
    local service_type=$2
    print_message "${YELLOW}" "正在更新隧道配置..."
    
    # 获取账户ID
    local account_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local account_id=$(echo "${account_info}" | jq -r '.result[0].id')
    
    if [[ -z "${account_id}" || "${account_id}" == "null" ]]; then
        print_message "${RED}" "获取账户信息失败"
        return 1
    fi
    
    # 准备配置数据
    if [[ "${service_type}" == "ssh" ]]; then
        # SSH 隧道配置
        cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${tunnel_id}
credentials-file: ${CRED_DIR}/${tunnel_id}.json
protocol: http2
ingress:
  - hostname: ${DOMAIN_NAME}
    service: ssh://127.0.0.1:22
    originRequest:
      noTLSVerify: true
      proxyType: direct
      tcpKeepAlive: 30s
      keepAliveTimeout: 30s
      keepAliveConnections: 10
  - service: http_status:404
metrics: 127.0.0.1:20241
EOL
    else
        # HTTP/HTTPS 隧道配置
        cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${tunnel_id}
credentials-file: ${CRED_DIR}/${tunnel_id}.json
protocol: http2
ingress:
  - hostname: ${DOMAIN_NAME}
    service: http://${LOCAL_IP}:${LOCAL_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
metrics: 127.0.0.1:20241
EOL
    fi
    
    chmod 644 "${CONFIG_DIR}/config.yml"
    
    # 获取根域名
    local root_domain=$(get_root_domain "${DOMAIN_NAME}")
    local zone_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${root_domain}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local zone_id=$(echo "${zone_info}" | jq -r '.result[0].id')
    if [[ -z "${zone_id}" || "${zone_id}" == "null" ]]; then
        print_message "${RED}" "获取区域ID失败"
        return 1
    fi
    
    # 更新 DNS 记录
    local existing_record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${DOMAIN_NAME}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local record_id=$(echo "${existing_record}" | jq -r '.result[0].id // empty')
    local dns_response
    
    if [[ -n "${record_id}" ]]; then
        print_message "${YELLOW}" "更新现有DNS记录..."
        dns_response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\":\"CNAME\",
                \"name\":\"${DOMAIN_NAME}\",
                \"content\":\"${tunnel_id}.cfargotunnel.com\",
                \"proxied\":true,
                \"comment\":\"Managed by cloudflared\",
                \"ttl\":1
            }")
    else
        print_message "${YELLOW}" "创建新DNS记录..."
        dns_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\":\"CNAME\",
                \"name\":\"${DOMAIN_NAME}\",
                \"content\":\"${tunnel_id}.cfargotunnel.com\",
                \"proxied\":true,
                \"comment\":\"Managed by cloudflared\",
                \"tags\":[],
                \"ttl\":1
            }")
    fi
    
    if ! echo "${dns_response}" | jq -e '.success' >/dev/null; then
        print_message "${RED}" "更新DNS记录失败"
        return 1
    fi
    
    print_message "${GREEN}" "隧道配置已更新"
    return 0
}

# --- 函数：启动隧道 ---
start_tunnel() {
    print_message "${YELLOW}" "正在启动隧道..."
    
    # 检查配置文件
    if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
        print_message "${RED}" "配置文件不存在: ${CONFIG_DIR}/config.yml"
        return 1
    fi
    
    # 检查配置文件内容
    print_message "${YELLOW}" "验证配置文件..."
    local tunnel_id=$(grep "^tunnel:" "${CONFIG_DIR}/config.yml" | cut -d' ' -f2)
    local cred_file=$(grep "^credentials-file:" "${CONFIG_DIR}/config.yml" | cut -d' ' -f2)
    
    if [[ -z "${tunnel_id}" ]]; then
        print_message "${RED}" "配置文件中未找到隧道ID"
        cat "${CONFIG_DIR}/config.yml"
        return 1
    fi
    
    if [[ -z "${cred_file}" ]]; then
        print_message "${RED}" "配置文件中未找到凭证文件路径"
        cat "${CONFIG_DIR}/config.yml"
        return 1
    fi
    
    # 检查凭证文件
    if [[ ! -f "${cred_file}" ]]; then
        print_message "${RED}" "凭证文件不存在: ${cred_file}"
        return 1
    fi
    
    # 验证凭证文件内容
    if ! jq -e . "${cred_file}" >/dev/null 2>&1; then
        print_message "${RED}" "凭证文件格式无效:"
        cat "${cred_file}"
        return 1
    fi
    
    # 设置凭证文件权限
    chmod 600 "${cred_file}"
    
    # 优化系统参数
    optimize_system_params
    
    # 停止可能存在的旧进程
    stop_service
    
    # 检查网络连接
    if ! ping -c 1 -W 5 cloudflare.com >/dev/null 2>&1; then
        print_message "${RED}" "无法连接到 Cloudflare，请检查网络连接"
        return 1
    fi
    
    # 清空旧日志
    echo "" > "${LOG_FILE}"
    chmod 644 "${LOG_FILE}"
    
    # 重新加载systemd
    print_message "${YELLOW}" "重新加载systemd配置..."
    systemctl daemon-reload
    
    # 启动服务
    print_message "${YELLOW}" "启动systemd服务..."
    if ! systemctl start cloudflared; then
        print_message "${RED}" "通过systemd启动服务失败，错误信息："
        systemctl status cloudflared
        journalctl -u cloudflared -n 50 --no-pager
        print_message "${YELLOW}" "尝试直接启动..."
    else
        # 等待服务启动
        sleep 5
        if systemctl is-active cloudflared >/dev/null 2>&1; then
            print_message "${GREEN}" "服务已通过systemd启动"
            systemctl enable cloudflared >/dev/null 2>&1
            
            # 检查隧道状态
            print_message "${YELLOW}" "检查隧道状态..."
            ${CLOUDFLARED_BIN} tunnel info "${tunnel_id}"
            
            # 显示日志
            print_message "${YELLOW}" "最近的日志："
            tail -n 20 "${LOG_FILE}"
            
            return 0
        fi
    fi
    
    # 如果systemd启动失败，���接启动进程
    print_message "${YELLOW}" "启动隧道服务..."
    cd /root
    export HOME=/root
    
    # 验证配置
    print_message "${YELLOW}" "验证配置..."
    if ! ${CLOUDFLARED_BIN} tunnel ingress validate --config "${CONFIG_DIR}/config.yml"; then
        print_message "${RED}" "配置验证失败"
        return 1
    fi
    
    # 启动进程
    nohup ${CLOUDFLARED_BIN} tunnel --config "${CONFIG_DIR}/config.yml" run > "${LOG_FILE}" 2>&1 &
    
    local pid=$!
    echo $pid > "${PID_FILE}"
    chmod 644 "${PID_FILE}"
    
    # 等待服务启动
    print_message "${YELLOW}" "等待服务启动..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if ! kill -0 $pid 2>/dev/null; then
            print_message "${RED}" "进程已终止，错误日志："
            tail -n 20 "${LOG_FILE}"
            return 1
        fi
        
        if grep -q "Registered tunnel connection\|Connection registered\|Started tunnel\|Tunnel is ready\|INF.*Connected" "${LOG_FILE}" 2>/dev/null; then
            print_message "${GREEN}" "隧道启动成功"
            print_message "${YELLOW}" "最近的日志："
            tail -n 20 "${LOG_FILE}"
            return 0
        fi
        
        if grep -q "error=duplicate tunnel\|certificate has expired\|invalid tunnel credentials\|error getting tunnel\|connection refused\|context canceled" "${LOG_FILE}" 2>/dev/null; then
            print_message "${RED}" "启动失败，错误日志："
            tail -n 20 "${LOG_FILE}"
            return 1
        fi
        
        sleep 1
        attempt=$((attempt + 1))
        if [ $((attempt % 5)) -eq 0 ]; then
            print_message "${YELLOW}" "等待服务启动中... ($attempt/$max_attempts)"
            tail -n 5 "${LOG_FILE}"
        fi
    done
    
    print_message "${RED}" "服务启动超时，完整日志："
    cat "${LOG_FILE}"
    return 1
}

# --- 函数：等待服务启动 ---
wait_for_service() {
    local timeout=$1
    local interval=2
    local count=0
    local max_count=$((timeout / interval))
    
    print_message "${YELLOW}" "等待服务启动..."
    while [ $count -lt $max_count ]; do
        # 检查进程是否存在
        if [[ -f "${PID_FILE}" ]]; then
            local pid=$(cat "${PID_FILE}")
            if ! kill -0 "${pid}" 2>/dev/null; then
                if grep -q "error=duplicate tunnel" "${LOG_FILE}" 2>/dev/null; then
                    print_message "${RED}" "隧道已在其他地方运行，请停止其他实例"
                elif grep -q "certificate has expired" "${LOG_FILE}" 2>/dev/null; then
                    print_message "${RED}" "证书已过期，请更新证书"
                elif grep -q "invalid tunnel credentials" "${LOG_FILE}" 2>/dev/null; then
                    print_message "${RED}" "隧道凭证无效，请检查配置"
                elif grep -q "error getting tunnel" "${LOG_FILE}" 2>/dev/null; then
                    print_message "${RED}" "无法获取隧道信息，请检查API Token权限"
                elif grep -q "connection refused" "${LOG_FILE}" 2>/dev/null; then
                    print_message "${RED}" "连接被拒绝，请检查本地服务是否在运行"
                elif grep -q "context canceled" "${LOG_FILE}" 2>/dev/null; then
                    print_message "${RED}" "连接被取消，可能是网络问题"
                elif grep -q "ERR" "${LOG_FILE}" 2>/dev/null; then
                    print_message "${RED}" "发生错误："
                    grep "ERR" "${LOG_FILE}" | tail -n 1
                else
                    print_message "${RED}" "服务进程已终止"
                fi
                return 1
            fi
        else
            print_message "${RED}" "PID文件不存在"
            return 1
        fi
        
        # 检查是否有成功连接的标志
        if grep -q "Registered tunnel connection\|Connection registered\|Started tunnel\|Tunnel is ready\|INF.*Connected" "${LOG_FILE}" 2>/dev/null; then
            print_message "${GREEN}" "服务启动成功"
            return 0
        fi
        
        # 检查是否有明确的错误信息
        if grep -q "failed to connect to origintunneld\|tunnel.Run failed\|failed to connect" "${LOG_FILE}" 2>/dev/null; then
            print_message "${RED}" "连接失败，查看错误信息："
            tail -n 5 "${LOG_FILE}"
            return 1
        fi
        
        sleep $interval
        count=$((count + 1))
        print_message "${YELLOW}" "等待服务启动中... ($count/$max_count)"
    done
    
    print_message "${RED}" "服务启动超时，请查看日志："
    tail -n 10 "${LOG_FILE}"
    return 1
}

# --- 函数：检查隧道是否配置自动 ---
is_tunnel_autostart() {
    local tunnel_id=$1
    
    # 检查systemd服务
    if [[ -f "${SERVICE_FILE}" ]] && grep -q "${tunnel_id}" "${SERVICE_FILE}"; then
        return 0
    fi
    
    # 检查rc.local
    if [[ -f "${RC_LOCAL_FILE}" ]] && grep -q "${tunnel_id}" "${RC_LOCAL_FILE}"; then
        return 0
    fi
    
    # 检查init.d脚本
    if [[ -f "${INIT_SCRIPT}" ]] && grep -q "${tunnel_id}" "${INIT_SCRIPT}"; then
        return 0
    fi
    
    return 1
}

# --- 函数：显示服务状态 ---
show_service_status() {
    clear
    echo -e "${BLUE}=== 服务状态 ===${RESET}\n"
    
    # 检查进程状态
    if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
        print_message "${GREEN}" "服务状态: 运行中"
        print_message "${GREEN}" "PID: $(cat "${PID_FILE}")"
    else
        print_message "${RED}" "服务状态: 未运行"
    fi
    
    # 检查systemd状态
    if command -v systemctl >/dev/null 2>&1; then
        echo -e "\n${YELLOW}Systemd 服务状态:${RESET}"
        systemctl status cloudflared 2>&1 | head -n 3
    fi
    
    # 显���端口监听状态
    echo -e "\n${YELLOW}端口监状态:${RESET}"
    netstat -tlpn 2>/dev/null | grep "cloudflared" || ss -tlpn 2>/dev/null | grep "cloudflared"
}

# --- 函数：重启服务 ---
restart_service() {
    print_message "${YELLOW}" "正在重启服务..."
    
    # 停止服务
    stop_service
    
    # 启动服务
    if start_tunnel; then
        print_message "${GREEN}" "服务重启成功"
    else
        print_message "${RED}" "服务重启失败"
    fi
}

# --- 函数：显示服务日志 ---
show_service_logs() {
    clear
    echo -e "${BLUE}=== 服务日志 ===${RESET}\n"
    
    if [[ -f "${LOG_FILE}" ]]; then
        tail -n 50 "${LOG_FILE}"
    else
        print_message "${RED}" "日志文件不存在"
    fi
}

# --- 函数：停止服务 ---
stop_service() {
    print_message "${YELLOW}" "正在停止服务..."
    
    # 停止systemd服务
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop cloudflared 2>/dev/null || true
        sleep 2
    fi
    
    # 停止进程
    if [[ -f "${PID_FILE}" ]]; then
        local pid=$(cat "${PID_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}"
            sleep 2
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
        fi
        rm -f "${PID_FILE}"
    fi
    
    # 查找并终止所有cloudflared进程
    pkill -f "cloudflared.*tunnel.*run" || true
    sleep 2
    
    # 确保所有进程都已终止
    if pgrep -f "cloudflared.*tunnel.*run" >/dev/null; then
        pkill -9 -f "cloudflared.*tunnel.*run" || true
    fi
    
    print_message "${GREEN}" "服务已停止"
}

# --- 函数：设置开机自启 ---
setup_autostart() {
    clear
    echo -e "${BLUE}=== 设置开机自启 ===${RESET}\n"
    
    local success=false
    
    # 尝试使用systemd
    if setup_systemd_autostart; then
        success=true
    fi
    
    # 如果systemd失败，尝试用rc.local
    if ! $success && setup_rclocal_autostart; then
        success=true
    fi
    
    # 如果rc.local也失败，尝试用init.d
    if ! $success && setup_initd_autostart; then
        success=true
    fi
    
    if $success; then
        print_message "${GREEN}" "开机自启设置成功"
    else
        print_message "${RED}" "开机自启设置失败"
    fi
}

# --- 函数：设置systemd自启 ---
setup_systemd_autostart() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    fi
    
    cat > "${SERVICE_FILE}" <<EOL
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${CONFIG_DIR}/config.yml run
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOL
    
    chmod 644 "${SERVICE_FILE}"
    
    if systemctl daemon-reload && \
       systemctl enable cloudflared >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# --- 函数：设置rc.local自启 ---
setup_rclocal_autostart() {
    if [[ ! -f "${RC_LOCAL_FILE}" ]]; then
        cat > "${RC_LOCAL_FILE}" <<EOL
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.

exit 0
EOL
        chmod +x "${RC_LOCAL_FILE}"
    fi
    
    # 在exit 0之前添加启动命令
    sed -i "/exit 0/i\\
${CLOUDFLARED_BIN} tunnel --config ${CONFIG_DIR}/config.yml run > ${LOG_FILE} 2>&1 &" "${RC_LOCAL_FILE}"
    
    return 0
}

# --- 函数：设置init.d自启 ---
setup_initd_autostart() {
    cat > "${INIT_SCRIPT}" <<EOL
#!/bin/sh
### BEGIN INIT INFO
# Provides:          cloudflared
# Required-Start:    \$network \$remote_fs \$syslog
# Required-Stop:     \$network \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Cloudflare Tunnel
# Description:       Cloudflare Tunnel service
### END INIT INFO

DAEMON="${CLOUDFLARED_BIN}"
CONFIG="${CONFIG_DIR}/config.yml"
PIDFILE="${PID_FILE}"
LOGFILE="${LOG_FILE}"

case "\$1" in
    start)
        echo "Starting cloudflared"
        start-stop-daemon --start --background --make-pidfile --pidfile \$PIDFILE \\
            --exec \$DAEMON -- tunnel --config \$CONFIG run > \$LOGFILE 2>&1
        ;;
    stop)
        echo "Stopping cloudflared"
        start-stop-daemon --stop --pidfile \$PIDFILE
        rm -f \$PIDFILE
        ;;
    restart)
        \$0 stop
        sleep 2
        \$0 start
        ;;
    status)
        if [ -f \$PIDFILE ] && kill -0 \$(cat \$PIDFILE) 2>/dev/null; then
            echo "cloudflared is running"
        else
            echo "cloudflared is not running"
            exit 1
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
EOL
    
    chmod +x "${INIT_SCRIPT}"
    
    if command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d cloudflared defaults
    elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --add cloudflared
    else
        return 1
    fi
    
    return 0
}

# --- 函数：安装依赖 ---
install_dependencies() {
    print_message "${YELLOW}" "正在安装依赖..."
    if command -v apt-get >/dev/null; then
        apt-get update >/dev/null 2>&1
        apt-get install -y curl jq net-tools >/dev/null 2>&1
    elif command -v yum >/dev/null; then
        yum install -y curl jq net-tools >/dev/null 2>&1
    elif command -v pacman >/dev/null; then
        pacman -Sy --noconfirm curl jq net-tools >/dev/null 2>&1
    fi
    print_message "${GREEN}" "依赖安装完成"
}

# --- 函数：清理旧隧道 ---
cleanup_tunnel() {
    local tunnel_id=$1
    local account_id=$2
    print_message "${YELLOW}" "��在清理隧道 ${tunnel_id}..."
    
    # 先清 DNS 记录
    print_message "${YELLOW}" "清理 DNS 记录..."
    local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local tunnel_cname="${tunnel_id}.cfargotunnel.com"
    
    # 遍历所有区域查找并删除相关的 DNS 记录
    while read -r zone_id; do
        if [[ -n "${zone_id}" ]]; then
            local dns_records=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME" \
                -H "Authorization: Bearer ${API_TOKEN}" \
                -H "Content-Type: application/json")
            
            while read -r record_id; do
                if [[ -n "${record_id}" && "${record_id}" != "null" ]]; then
                    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
                        -H "Authorization: Bearer ${API_TOKEN}" \
                        -H "Content-Type: application/json" >/dev/null
                fi
            done < <(echo "${dns_records}" | jq -r --arg cname "${tunnel_cname}" '.result[] | select(.content == $cname) | .id')
        fi
    done < <(echo "${zones_response}" | jq -r '.result[].id')
    
    # 停止所有运行中的程序
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
    
    # 运行cleanup
    print_message "${YELLOW}" "清理隧道..."
    ${CLOUDFLARED_BIN} tunnel cleanup "${tunnel_id}" >/dev/null 2>&1 || true
    sleep 2
    
    # 删除隧道
    print_message "${YELLOW}" "删除隧道..."
    DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if ! echo "${DELETE_RESPONSE}" | jq -e '.success' >/dev/null; then
        local error_msg=$(echo "${DELETE_RESPONSE}" | jq -r '.errors[0].message // "未知错误"')
        if [[ "${error_msg}" == *"active connections"* ]]; then
            print_message "${YELLOW}" "仍有活动连接，等待后重试..."
            sleep 10
            ${CLOUDFLARED_BIN} tunnel cleanup "${tunnel_id}" >/dev/null 2>&1 || true
            sleep 2
            DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}" \
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
    
    # 清理配置文件
    rm -f "${CONFIG_DIR}/config.yml" "${CRED_DIR}/${tunnel_id}.json" >/dev/null 2>&1
    
    print_message "${GREEN}" "隧道清理完成"
    return 0
}

# --- 函数：验证配置 ---
validate_config() {
    # 验证IP地址格式
    if [[ ! "${LOCAL_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_message "${RED}" "错误: 无效的IP地址格式: ${LOCAL_IP}"
        return 1
    fi
    
    # 验证是否是有效的监听地址
    if [[ "${LOCAL_IP}" != "127.0.0.1" && "${LOCAL_IP}" != "0.0.0.0" ]]; then
        print_message "${YELLOW}" "警: 建议使用 127.0.0.1（仅本机）或 0.0.0.0（所有网卡）作为监听地址"
    fi
    
    # 验证端口号
    if ! [[ "${LOCAL_PORT}" =~ ^[0-9]+$ ]] || [ "${LOCAL_PORT}" -lt 1 ] || [ "${LOCAL_PORT}" -gt 65535 ]; then
        print_message "${RED}" "错误: 无效的端口号: ${LOCAL_PORT}"
        return 1
    fi
    
    # 验证API Token格式
    if [[ ! "${API_TOKEN}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_message "${RED}" "错误: API Token 格式无效"
        return 1
    fi
    
    return 0
}

# --- 函数：检查必要条件 ---
check_prerequisites() {
    # 检查是否root用户
    if [ "$(id -u)" != "0" ]; then
        print_message "${RED}" "错误: 本需要root权限运行"
        exit 1
    fi

    # 检查要的命令
    local required_commands=("curl" "jq")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            print_message "${RED}" "错误: 未找到命令 '$cmd'"
            exit 1
        fi
    done
}

# --- 函数：错误处理 ---
error_handler() {
    local exit_code=$1
    local line_no=$2
    local bash_lineno=$3
    local last_command=$4
    local func_trace=$5

    # 某些错误是可忽略的
    case $exit_code in
        0) return ;;  # 不是误
        100) return ;;  # cloudflared 的正常退出
        130) return ;;  # Ctrl+C
        137) return ;;  # kill -9
        143) return ;;  # kill
    esac

    # 如果是系统命令失败，不终止脚本
    if [[ "$last_command" =~ ^(sysctl|ulimit|kill|systemctl|start-stop-daemon) ]]; then
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

# --- 函数：清理资源 ---
cleanup() {
    # 在正的错误发生时执行清
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

# --- 函数：按任意键续 ---
press_any_key() {
    echo -e "\n${YELLOW}按任意键继续...${RESET}"
    read -n 1 -s
}

# --- 函数：显示帮助信息 ---
show_help() {
    echo -e "${BLUE}Cloudflare Tunnel 管理工具使用说明${RESET}

${GREEN}功能说明:${RESET}
1. 查看隧道状态
   - 显示所有隧道的状态信息
   - 支持删除指定隧道

2. 新增隧道
   - 静默方式：使用默认配置
   - 引导式：交互式配置

3. 服务管理
   - 查看服务状态
   - 重启服务
   - 查看服务日志
   - 停止服务
   - 设置开机自启

${GREEN}配置文件位置:${RESET}
- 主配置文件: ${CONFIG_DIR}/config.yml
- 凭证文件: ${CRED_DIR}/<tunnel-id>.json
- 日志文件: ${LOG_FILE}
- PID文件: ${PID_FILE}

${GREEN}注意事项:${RESET}
- 需要root权限运行
- 确保API Token有足够的权限
- DNS记录生效可能需要几分钟
- 建议使用0.0.0.0作为监听地址

${YELLOW}API Token需权限:${RESET}
- Account > Cloudflare Tunnel > Edit
- Account > SSL and Certificates > Edit
- Zone > DNS > Edit
- Zone > Zone > Read"
}

# --- 函数：检查服务状态 ---
check_service_status() {
    local status="未运行"
    local pid=""
    
    # 检查PID文件
    if [[ -f "${PID_FILE}" ]]; then
        pid=$(cat "${PID_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            status="运行中"
        fi
    fi
    
    # 检查systemd状态
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active cloudflared >/dev/null 2>&1; then
            status="运行中(systemd)"
            pid=$(systemctl show -p MainPID cloudflared | cut -d= -f2)
        fi
    fi
    
    echo "${status}:${pid}"
}

# --- 函数：检查自启动状态 ---
check_autostart_status() {
    local enabled="否"
    
    # 检查systemd
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled cloudflared >/dev/null 2>&1; then
            enabled="是(systemd)"
        fi
    fi
    
    # 检查rc.local
    if [[ -f "${RC_LOCAL_FILE}" ]] && grep -q "${CLOUDFLARED_BIN}" "${RC_LOCAL_FILE}"; then
        enabled="是(rc.local)"
    fi
    
    # 检查init.d
    if [[ -f "${INIT_SCRIPT}" ]]; then
        if { command -v chkconfig >/dev/null 2>&1 && chkconfig --list cloudflared >/dev/null 2>&1; } || \
           { command -v update-rc.d >/dev/null 2>&1 && [[ -x "${INIT_SCRIPT}" ]]; }; then
            enabled="是(init.d)"
        fi
    fi
    
    echo "${enabled}"
}

# --- 函数：检查端口占用 ---
check_port_usage() {
    local port=$1
    if command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":${port} "; then
            return 0
        fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":${port} "; then
            return 0
        fi
    fi
    return 1
}

# --- 函数：优化系统参数 ---
optimize_system_params() {
    print_message "${YELLOW}" "正在优化系统参数..."
    
    # 创建 sysctl 配置文件
    cat > /etc/sysctl.d/99-cloudflared.conf <<EOL
# Cloudflared UDP buffer sizes
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.core.rmem_default=26214400
net.core.wmem_default=26214400
net.ipv4.udp_mem=26214400 26214400 26214400
# TCP keepalive settings
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
# TCP optimization
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_max_syn_backlog=4096
net.core.somaxconn=4096
# ICMP settings
net.ipv4.ping_group_range=0 2147483647
# IPv6 settings
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOL
    
    # 应用 sysctl 配置
    sysctl -p /etc/sysctl.d/99-cloudflared.conf >/dev/null 2>&1
    
    # 设置 SSH 配置
    if [[ ! -f "/etc/ssh/sshd_config.d/cloudflared.conf" ]]; then
        cat > "/etc/ssh/sshd_config.d/cloudflared.conf" <<EOL
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
GatewayPorts yes
AllowTcpForwarding yes
EOL
        systemctl restart sshd
    fi
    
    return 0
}

# --- 函数：安装 cloudflared ---
install_cloudflared() {
    print_message "${YELLOW}" "正在安装 cloudflared..."
    
    # 创建必要的目录
    mkdir -p "$(dirname "${CLOUDFLARED_BIN}")" "${CONFIG_DIR}" "${CRED_DIR}" "${HOME}/.cloudflared"
    chmod 755 "$(dirname "${CLOUDFLARED_BIN}")" "${CONFIG_DIR}"
    chmod 700 "${CRED_DIR}" "${HOME}/.cloudflared"
    
    # 检查是否已安装
    if [[ -f "${CLOUDFLARED_BIN}" ]]; then
        local current_version=$(${CLOUDFLARED_BIN} version 2>/dev/null | grep -oP 'version \K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
        if [[ -n "${current_version}" ]]; then
            print_message "${GREEN}" "当前版本: ${current_version}"
            return 0
        fi
    fi
    
    # 尝试多种安装方式
    local install_success=false
    
    # 方式1: 使用包管理器安装
    print_message "${YELLOW}" "尝试使用包管理器安装..."
    if command -v apt-get >/dev/null; then
        # Debian/Ubuntu
        if curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --dearmor | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null && \
           echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main' | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null && \
           apt-get update >/dev/null 2>&1 && \
           apt-get install -y cloudflared >/dev/null 2>&1; then
            install_success=true
        fi
    elif command -v yum >/dev/null; then
        # RHEL/CentOS
        if curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo | sudo tee /etc/yum.repos.d/cloudflared.repo >/dev/null && \
           yum install -y cloudflared >/dev/null 2>&1; then
            install_success=true
        fi
    fi
    
    # 方式2: 直接下载二进制文件
    if ! $install_success; then
        print_message "${YELLOW}" "尝试直接下载二进制文件..."
        local arch=$(uname -m)
        local os=$(uname -s | tr '[:upper:]' '[:lower:]')
        local download_url=""
        
        case "${arch}" in
            x86_64|amd64)
                download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${os}-amd64"
                ;;
            aarch64|arm64)
                download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${os}-arm64"
                ;;
            armv7l)
                download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${os}-arm"
                ;;
            *)
                print_message "${RED}" "不支持的架构: ${arch}"
                ;;
        esac
        
        if [[ -n "${download_url}" ]]; then
            if curl -sL "${download_url}" -o "${CLOUDFLARED_BIN}" && \
               chmod +x "${CLOUDFLARED_BIN}"; then
                install_success=true
            fi
        fi
    fi
    
    # 方式3: 使用 wget 下载 deb 包
    if ! $install_success; then
        print_message "${YELLOW}" "尝试下载 deb 包安装..."
        local temp_dir=$(mktemp -d)
        local deb_file="${temp_dir}/cloudflared.deb"
        
        if wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" -O "${deb_file}" && \
           dpkg -i "${deb_file}" >/dev/null 2>&1; then
            install_success=true
        fi
        rm -rf "${temp_dir}"
    fi
    
    # 方式4: 使用 curl 下载 deb 包
    if ! $install_success; then
        print_message "${YELLOW}" "尝试使用 curl 下载 deb 包安装..."
        local temp_dir=$(mktemp -d)
        local deb_file="${temp_dir}/cloudflared.deb"
        
        if curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" -o "${deb_file}" && \
           dpkg -i "${deb_file}" >/dev/null 2>&1; then
            install_success=true
        fi
        rm -rf "${temp_dir}"
    fi
    
    # 验证安装
    if $install_success; then
        if ${CLOUDFLARED_BIN} version >/dev/null 2>&1; then
            local version=$(${CLOUDFLARED_BIN} version 2>/dev/null | grep -oP 'version \K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
            print_message "${GREEN}" "cloudflared 安装成功，版本: ${version}"
            return 0
        fi
    fi
    
    print_message "${RED}" "所有安装方式都失败了"
    print_message "${YELLOW}" "请尝试手动安装:"
    print_message "${YELLOW}" "1. 访问 https://github.com/cloudflare/cloudflared/releases"
    print_message "${YELLOW}" "2. 下载适合您系统的版本"
    print_message "${YELLOW}" "3. 解压并将二进制文件复制到 ${CLOUDFLARED_BIN}"
    print_message "${YELLOW}" "4. 执行: chmod +x ${CLOUDFLARED_BIN}"
    return 1
}

# --- 函数：检查并��装 cloudflared ---
ensure_cloudflared() {
    if [[ ! -f "${CLOUDFLARED_BIN}" ]] || ! ${CLOUDFLARED_BIN} version >/dev/null 2>&1; then
        if ! install_cloudflared; then
            print_message "${RED}" "无法安装 cloudflared"
            return 1
        fi
    fi
    return 0
}

# --- 主程序 ---
main() {
    # 检查必要条件
    check_prerequisites
    
    # 安装依赖
    install_dependencies
    
    # 主循环
    while true; do
        show_main_menu
        read -r choice
        
        case $choice in
            1)
                show_tunnel_status
                ;;
            2)
                show_new_tunnel_menu
                ;;
            3)
                show_service_menu
                ;;
            0)
                print_message "${GREEN}" "感谢使用，再见！"
                exit 0
                ;;
            *)
                print_message "${RED}" "无效的选择"
                sleep 1
                ;;
        esac
    done
}

# --- 主程序开始前置 ---
export LANG=en_US.UTF-8

# 执行主程序
main "$@"
