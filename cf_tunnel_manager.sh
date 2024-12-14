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
        printf "序号  ID                                      名称           状态             域名                            自启动\n"
        printf "%s\n" "=============================================================================================================="
        
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
            
            # 显示隧道信息
            printf "%-5d %-36s %-17s %-13s %-32s %5s\n" \
                "${index}" \
                "${tunnel_id}" \
                "${tunnel_name}" \
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
                echo -n "请输入要删除的隧道序号: "
                read -r tunnel_index
                if [[ -n "${tunnel_ids[$tunnel_index]}" ]]; then
                    if cleanup_tunnel "${tunnel_ids[$tunnel_index]}" "${account_id}"; then
                        print_message "${GREEN}" "隧道删除成功"
                        continue
                    else
                        print_message "${RED}" "隧道删除失败"
                    fi
                else
                    print_message "${RED}" "无效的隧道序号"
                fi
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
        
        if ! echo "${tunnel_info}" | jq -e '.success' >/dev/null; then
            print_message "${RED}" "获取隧道信息失败"
            return 1
        fi
        
        # 提取基本信息
        local name=$(echo "${tunnel_info}" | jq -r '.result.name')
        local status=$(echo "${tunnel_info}" | jq -r '.result.status')
        local created_at=$(echo "${tunnel_info}" | jq -r '.result.created_at')
        local tunnel_type=$(echo "${tunnel_info}" | jq -r '.result.tunnel_type')
        
        echo -e "${GREEN}基本信息:${RESET}"
        echo -e "ID: ${tunnel_id}"
        echo -e "名称: ${name}"
        echo -e "状态: ${status}"
        echo -e "类型: ${tunnel_type}"
        echo -e "创建时间: ${created_at}"
        
        # 获取所有区域信息
        local zones_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        # 获取隧道的DNS记录
        echo -e "\n${GREEN}域名配置:${RESET}"
        local found_domains=false
        local tunnel_cname="${tunnel_id}.cfargotunnel.com"
        
        # 遍历所有区域查找CNAME记录
        while read -r zone_id; do
            if [[ -n "${zone_id}" ]]; then
                local zone_info=$(echo "${zones_response}" | jq -r --arg id "${zone_id}" '.result[] | select(.id == $id)')
                local zone_name=$(echo "${zone_info}" | jq -r '.name')
                
                local dns_records=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME" \
                    -H "Authorization: Bearer ${API_TOKEN}" \
                    -H "Content-Type: application/json")
                
                if echo "${dns_records}" | jq -e '.success' >/dev/null; then
                    while read -r record; do
                        if [[ -n "${record}" && "${record}" != "null" ]]; then
                            local hostname=$(echo "${record}" | jq -r '.name')
                            local content=$(echo "${record}" | jq -r '.content')
                            local proxied=$(echo "${record}" | jq -r '.proxied')
                            if [[ "${content}" == "${tunnel_cname}" ]]; then
                                echo -e "- 域名: ${hostname}"
                                echo -e "  区域: ${zone_name}"
                                echo -e "  代理状态: $([ "${proxied}" == "true" ] && echo "已启用" || echo "未启用")"
                                found_domains=true
                            fi
                        fi
                    done < <(echo "${dns_records}" | jq -c '.result[]')
                fi
            fi
        done < <(echo "${zones_response}" | jq -r '.result[].id')
        
        if [[ "${found_domains}" == "false" ]]; then
            echo "未找到定"
        fi
        
        # 获取隧道连接信息
        local conn_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}/connections" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        echo -e "\n${GREEN}连接信息:${RESET}"
        if echo "${conn_response}" | jq -e '.success' >/dev/null && [[ $(echo "${conn_response}" | jq '.result | length') -gt 0 ]]; then
            while read -r conn; do
                if [[ -n "${conn}" && "${conn}" != "null" ]]; then
                    local conn_id=$(echo "${conn}" | jq -r '.id')
                    # 尝试多可能的IP字段
                    local conn_ip=$(echo "${conn}" | jq -r '.origin.ip // .originIp // .ip // empty')
                    local conn_time=$(echo "${conn}" | jq -r '.connected_at')
                    local conn_version=$(echo "${conn}" | jq -r '.client_version')
                    echo -e "- 连接ID: ${conn_id}"
                    if [[ -n "${conn_ip}" && "${conn_ip}" != "null" ]]; then
                        echo -e "  客户端IP: ${conn_ip}"
                    fi
                    echo -e "  连接时间: ${conn_time}"
                    echo -e "  客户端版本: ${conn_version}"
                fi
            done < <(echo "${conn_response}" | jq -c '.result[]')
        else
            echo "当前无活动连接"
        fi
        
        # 获取隧道配置信息
        local config_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}/configurations" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        echo -e "\n${GREEN}路由配置:${RESET}"
        if echo "${config_response}" | jq -e '.success' >/dev/null; then
            while read -r ingress; do
                if [[ -n "${ingress}" && "${ingress}" != "null" ]]; then
                    local hostname=$(echo "${ingress}" | jq -r '.hostname // "catch-all"')
                    local service=$(echo "${ingress}" | jq -r '.service // "未配置"')
                    if [[ "${hostname}" != "null" && "${hostname}" != "" ]]; then
                        echo -e "- 主机名: ${hostname}"
                        echo -e "  服务: ${service}"
                    fi
                fi
            done < <(echo "${config_response}" | jq -c '.result.config.ingress[]' 2>/dev/null)
        else
            echo "未找到由置"
        fi
        
        # 示启动状��
        echo -e "\n${GREEN}自启动状态:${RESET}"
        if is_tunnel_autostart "${tunnel_id}"; then
            echo "已配置自启动"
        else
            echo "未配置自启动"
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
    echo -e "${GREEN}1.${RESET} 静默方式（使用默认配置）"
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
        echo -e "${GREEN}1.${RESET} 查看服务状态"
        echo -e "${GREEN}2.${RESET} 重启服务"
        echo -e "${GREEN}3.${RESET} 查看服务日志"
        echo -e "${GREEN}4.${RESET} 停止服务"
        echo -e "${GREEN}5.${RESET} 设置开机自启"
        echo -e "${GREEN}0.${RESET} 返回主菜单\n"
        echo -n "请选择操作 [0-5]: "
        
        read -r choice
        case $choice in
            1)
                show_service_status
                ;;
            2)
                restart_service
                ;;
            3)
                show_service_logs
                ;;
            4)
                stop_service
                ;;
            5)
                setup_autostart
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
        
        # 修改API Token的处理逻辑
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
    
    # 如果没有找到，返回两部分
    echo "${parts[$((length-2))]}.${parts[$((length-1))]}"
}

# --- 函数：创建隧道配置 ---
create_tunnel_config() {
    local service_type=${1:-"http"}  # 添加默认值
    print_message "${YELLOW}" "正在创建隧道配置..."
    
    # 获取账户ID
    local account_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local account_id=$(echo "${account_info}" | jq -r '.result[0].id')
    
    if [[ -z "${account_id}" || "${account_id}" == "null" ]]; then
        print_message "${RED}" "获取账户信息失败"
        return 1
    fi
    
    # 检查是否存在同名隧道
    local existing_tunnel=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" | \
        jq -r --arg name "${TUNNEL_NAME}" '.result[] | select(.name == $name and .deleted_at == null)')
    
    local tunnel_id=""
    if [[ -n "${existing_tunnel}" ]]; then
        tunnel_id=$(echo "${existing_tunnel}" | jq -r '.id')
        print_message "${YELLOW}" "使用现有隧道: ${TUNNEL_NAME}"
        
        # 删除旧的凭证文件
        rm -f "${CRED_DIR}/${tunnel_id}.json"
        
        # 重新获取隧道凭证
        print_message "${YELLOW}" "重新获取隧道凭证..."
        local tunnel_details=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json")
        
        if echo "${tunnel_details}" | jq -e '.success' >/dev/null; then
            mkdir -p "${CRED_DIR}"
            echo "${tunnel_details}" | jq -r '.result' > "${CRED_DIR}/${tunnel_id}.json"
            chmod 600 "${CRED_DIR}/${tunnel_id}.json"
            print_message "${GREEN}" "隧道凭证已更新"
        else
            print_message "${RED}" "获取隧道凭证失败"
            return 1
        fi
    else
        # 创建新隧道
        print_message "${YELLOW}" "创建新隧道..."
        local create_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"name\":\"${TUNNEL_NAME}\",\"config\":{}}")
        
        if ! echo "${create_response}" | jq -e '.success' >/dev/null; then
            print_message "${RED}" "创建隧道���败: $(echo "${create_response}" | jq -r '.errors[0].message // "未知错误"')"
            return 1
        fi
        
        tunnel_id=$(echo "${create_response}" | jq -r '.result.id')
        mkdir -p "${CRED_DIR}"
        echo "${create_response}" | jq -r '.result' > "${CRED_DIR}/${tunnel_id}.json"
        chmod 600 "${CRED_DIR}/${tunnel_id}.json"
    fi
    
    # 验证凭证文件
    if [[ ! -f "${CRED_DIR}/${tunnel_id}.json" ]]; then
        print_message "${RED}" "凭证文件不存在"
        return 1
    fi
    
    # 验证凭证文件内容
    if ! jq -e '.id' "${CRED_DIR}/${tunnel_id}.json" >/dev/null 2>&1; then
        print_message "${RED}" "凭证文件格式无效"
        return 1
    fi
    
    # 创建配置目录
    mkdir -p "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"
    
    # 根据服务类型创建配置
    if [[ "${service_type}" == "ssh" ]]; then
        cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${tunnel_id}
credentials-file: ${CRED_DIR}/${tunnel_id}.json
ingress:
  - hostname: ${DOMAIN_NAME}
    service: ssh://${LOCAL_IP}:${LOCAL_PORT}
  - service: http_status:404
EOL
    else
        cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${tunnel_id}
credentials-file: ${CRED_DIR}/${tunnel_id}.json
ingress:
  - hostname: ${DOMAIN_NAME}
    service: http://${LOCAL_IP}:${LOCAL_PORT}
  - service: http_status:404
EOL
    fi
    
    # 设置配置文件权限
    chmod 644 "${CONFIG_DIR}/config.yml"
    
    # 验证配置文件
    print_message "${YELLOW}" "验证配置文件..."
    if ! ${CLOUDFLARED_BIN} tunnel ingress validate "${CONFIG_DIR}/config.yml" >/dev/null 2>&1; then
        print_message "${RED}" "配置文件验证失败"
        return 1
    fi
    
    print_message "${GREEN}" "隧道配置创建成功"
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
    
    # 删除旧的凭证文件
    rm -f "${CRED_DIR}/${tunnel_id}.json"
    
    # 重新获取隧道凭证
    print_message "${YELLOW}" "重新获取隧道凭证..."
    local tunnel_details=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/tunnels/${tunnel_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    if ! echo "${tunnel_details}" | jq -e '.success' >/dev/null; then
        print_message "${RED}" "获取隧道信息失败"
        return 1
    fi
    
    # 创建新的凭证文件
    mkdir -p "${CRED_DIR}"
    echo "${tunnel_details}" | jq -r '.result | {
        "AccountTag": .account_tag,
        "TunnelID": .id,
        "TunnelName": .name,
        "TunnelSecret": .tunnel_secret
    }' > "${CRED_DIR}/${tunnel_id}.json"
    chmod 600 "${CRED_DIR}/${tunnel_id}.json"
    
    # 验证凭证文件
    if [[ ! -f "${CRED_DIR}/${tunnel_id}.json" ]]; then
        print_message "${RED}" "凭证文件不存在"
        return 1
    fi
    
    # 验证凭证文件内容
    if ! jq -e '.TunnelID' "${CRED_DIR}/${tunnel_id}.json" >/dev/null 2>&1; then
        print_message "${RED}" "凭证文件格式无效"
        return 1
    fi
    
    # 创建配置目录
    mkdir -p "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"
    
    # 根据服务类型创建配置
    if [[ "${service_type}" == "ssh" ]]; then
        cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${tunnel_id}
credentials-file: ${CRED_DIR}/${tunnel_id}.json
ingress:
  - hostname: ${DOMAIN_NAME}
    service: ssh://${LOCAL_IP}:${LOCAL_PORT}
  - service: http_status:404
EOL
    else
        cat > "${CONFIG_DIR}/config.yml" <<EOL
tunnel: ${tunnel_id}
credentials-file: ${CRED_DIR}/${tunnel_id}.json
ingress:
  - hostname: ${DOMAIN_NAME}
    service: http://${LOCAL_IP}:${LOCAL_PORT}
  - service: http_status:404
EOL
    fi
    
    chmod 644 "${CONFIG_DIR}/config.yml"
    
    # 验证配置文件
    print_message "${YELLOW}" "验证配置文件..."
    if ! ${CLOUDFLARED_BIN} tunnel ingress validate "${CONFIG_DIR}/config.yml" >/dev/null 2>&1; then
        print_message "${RED}" "配置文件验证失败"
        return 1
    fi
    
    print_message "${GREEN}" "配置文件已更新"
    return 0
}

# --- 函数：启动隧道 ---
start_tunnel() {
    print_message "${YELLOW}" "正在启动隧道..."
    
    # 检查配置文件
    if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
        print_message "${RED}" "配置文件不存在"
        return 1
    fi
    
    # 检查配置文件内容
    print_message "${YELLOW}" "验证配置文件..."
    local config_content=$(cat "${CONFIG_DIR}/config.yml")
    local tunnel_id=$(echo "${config_content}" | grep "^tunnel:" | cut -d' ' -f2)
    local cred_file=$(echo "${config_content}" | grep "^credentials-file:" | cut -d' ' -f2)
    
    if [[ -z "${tunnel_id}" ]]; then
        print_message "${RED}" "配置文件中未找到隧道ID"
        return 1
    fi
    
    if [[ -z "${cred_file}" ]]; then
        print_message "${RED}" "配置文件中未找到凭证文件路径"
        return 1
    fi
    
    # 检查凭证文件
    if [[ ! -f "${cred_file}" ]]; then
        print_message "${RED}" "凭证文件不存在: ${cred_file}"
        return 1
    fi
    
    # 验证凭证文件内容
    if ! jq -e . "${cred_file}" >/dev/null 2>&1; then
        print_message "${RED}" "凭证文件格式无效"
        return 1
    fi
    
    # 检查凭证文件权限
    local cred_perms=$(stat -c %a "${cred_file}")
    if [[ "${cred_perms}" != "600" ]]; then
        print_message "${YELLOW}" "修正凭证文件权限..."
        chmod 600 "${cred_file}"
    fi
    
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
    
    # 先尝试验证配置
    print_message "${YELLOW}" "验证隧道配置..."
    if ! ${CLOUDFLARED_BIN} tunnel ingress validate "${CONFIG_DIR}/config.yml"; then
        print_message "${RED}" "隧道配置验证失败"
        return 1
    fi
    
    # 启动隧道服务
    print_message "${YELLOW}" "启动隧道服务..."
    QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING=1 \
    ${CLOUDFLARED_BIN} tunnel --config "${CONFIG_DIR}/config.yml" \
        --metrics localhost:20241 \
        --protocol http2 \
        --no-autoupdate \
        run > "${LOG_FILE}" 2>&1 &
    
    echo $! > "${PID_FILE}"
    chmod 644 "${PID_FILE}"
    
    # 等待服务启动
    if wait_for_service 30; then
        print_message "${GREEN}" "隧道启动成功"
        return 0
    fi
    
    print_message "${RED}" "隧道启动失败，错误信息："
    if [[ -f "${LOG_FILE}" ]]; then
        echo "=== 最后50行日志 ==="
        tail -n 50 "${LOG_FILE}"
        echo "=== 错误信息 ==="
        grep -E "ERR|error|failed|failure" "${LOG_FILE}" | tail -n 5
    fi
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
        if [[ ! -f "${PID_FILE}" ]] || ! kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
            if grep -q "error=duplicate tunnel" "${LOG_FILE}" 2>/dev/null; then
                print_message "${RED}" "隧道已在其他地方运行，请先停止其他实例"
            elif grep -q "certificate has expired" "${LOG_FILE}" 2>/dev/null; then
                print_message "${RED}" "证书已过期，请更新证书"
            elif grep -q "invalid tunnel credentials" "${LOG_FILE}" 2>/dev/null; then
                print_message "${RED}" "隧道凭证无效，请检查配置"
            elif grep -q "error getting tunnel" "${LOG_FILE}" 2>/dev/null; then
                print_message "${RED}" "无法获取隧道信息，请检查API Token权限"
            elif grep -q "connection refused" "${LOG_FILE}" 2>/dev/null; then
                print_message "${RED}" "连接被拒绝，请检查本地服务是否正在运行"
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
        
        # 检查是否有成功连接的标志
        if grep -q "Registered tunnel connection\|Connection registered\|Started tunnel\|Tunnel is ready" "${LOG_FILE}" 2>/dev/null; then
            print_message "${GREEN}" "服务启动���功"
            return 0
        fi
        
        sleep $interval
        count=$((count + 1))
        print_message "${YELLOW}" "等待服务启动中... ($count/$max_count)"
    done
    
    print_message "${RED}" "服务启动超时，请查日志："
    tail -n 10 "${LOG_FILE}"
    return 1
}

# --- 函数：检查隧道是否配置自启动 ---
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
    
    # 显示端口监听状态
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
    
    # 如果systemd失败，尝试使用rc.local
    if ! $success && setup_rclocal_autostart; then
        success=true
    fi
    
    # 如果rc.local也失败，尝试使用init.d
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
    print_message "${YELLOW}" "正在清理隧道 ${tunnel_id}..."
    
    # 先尝试停止所有运行中的程序
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
    print_message "${YELLOW}" "清理隧道连接..."
    ${CLOUDFLARED_BIN} tunnel cleanup "${tunnel_id}" >/dev/null 2>&1 || true
    sleep 2

    # 现在试删除隧道
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
        print_message "${YELLOW}" "警告: 建议使用 127.0.0.1（仅本机）或 0.0.0.0（所有网卡）作为监听地址"
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
        0) return ;;  # 不是错误
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

# --- 函数：按任意键续 ---
press_any_key() {
    echo -e "\n${YELLOW}按任意键继续...${RESET}"
    read -n 1 -s
}

# --- 函数：显示帮助息 ---
show_help() {
    echo -e "${BLUE}Cloudflare Tunnel 管理工具使用说明${RESET}

${GREEN}功能说明:${RESET}
1. 查看隧道状态
   - 显示所有隧道的状态信息
   - 支持删除定隧道

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
- 确保API Token具有足够的权限
- DNS记录效可需要几分钟
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
    if [[ -f "${INIT_SCRIPT}" ]] && { command -v chkconfig >/dev/null 2>&1 && chkconfig --list cloudflared >/dev/null 2>&1 || command -v update-rc.d >/dev/null 2>&1 && [[ -x "${INIT_SCRIPT}" ]]; }; then
        enabled="是(init.d)"
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
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.ipv4.udp_mem=16777216 16777216 16777216
EOL
    
    # 应用 sysctl 配置
    sysctl -p /etc/sysctl.d/99-cloudflared.conf
    
    # 直接设置当前会话的值
    sysctl -w net.core.rmem_max=16777216
    sysctl -w net.core.wmem_max=16777216
    sysctl -w net.core.rmem_default=16777216
    sysctl -w net.core.wmem_default=16777216
    sysctl -w net.ipv4.udp_mem="16777216 16777216 16777216"
    
    # 增加文件描述符限制
    if ! grep -q "* soft nofile 65535" /etc/security/limits.conf; then
        echo "* soft nofile 65535" >> /etc/security/limits.conf
        echo "* hard nofile 65535" >> /etc/security/limits.conf
    fi
    
    ulimit -n 65535
    
    return 0
}

# --- 函数：安装 cloudflared ---
install_cloudflared() {
    print_message "${YELLOW}" "正在安装 cloudflared..."
    
    # 检查是否已安装
    if [[ -f "${CLOUDFLARED_BIN}" ]]; then
        local current_version=$(${CLOUDFLARED_BIN} version 2>/dev/null | grep -oP 'version \K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
        if [[ -n "${current_version}" ]]; then
            print_message "${GREEN}" "当前版本: ${current_version}"
            return 0
        fi
    fi
    
    # 创建必要的目录
    mkdir -p "$(dirname "${CLOUDFLARED_BIN}")" "${CONFIG_DIR}" "${CRED_DIR}"
    
    # 下载最新版本
    print_message "${YELLOW}" "下载最新版本..."
    if ! curl -sL "${CLOUDFLARED_URL}" -o "${CLOUDFLARED_BIN}"; then
        print_message "${RED}" "下载失败"
        return 1
    fi
    
    # 设置执行权限
    chmod +x "${CLOUDFLARED_BIN}"
    
    # 验证安装
    if ! ${CLOUDFLARED_BIN} version >/dev/null 2>&1; then
        print_message "${RED}" "安装验证失败"
        return 1
    fi
    
    print_message "${GREEN}" "cloudflared 装成功"
    return 0
}

# --- 函数：检查并安装 cloudflared ---
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

# --- 主程序开始前设置 ---
export LANG=en_US.UTF-8

# 执行主程序
main "$@"
