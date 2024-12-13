#!/bin/bash

# --- 配置项 ---
# OpenWebUI 安装目录
OPENWEBUI_DIR="$HOME/openwebui"
# conda 环境目录
CONDA_ENV_DIR="$OPENWEBUI_DIR/conda_env"
# OpenWebUI 端口
OPENWEBUI_PORT=8080
# ngrok 认证 token
NGROK_AUTH_TOKEN="xx"
# ngrok 域名
NGROK_DOMAIN="bursting-ibex-major.ngrok-free.app"
# ngrok 安装目录
NGROK_DIR="$HOME/ngrok"
# ngrok 压缩包路径
NGROK_TGZ_PATH="$HOME/ngrok-v3-stable-linux-amd64.tgz"
# OpenWebUI 模型目录 (新参数)
OPENWEBUI_MODEL_DIR="$OPENWEBUI_DIR/models"

# --- 函数定义 ---

# 检查命令是否存在
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# 安装 miniconda
install_miniconda() {
    echo "开始安装 miniconda..."
    if command_exists conda; then
        echo "conda 已安装，跳过安装步骤."
        return 0
    fi
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    MINICONDA_INSTALLER="$HOME/miniconda.sh"
    wget "$MINICONDA_URL" -O "$MINICONDA_INSTALLER"
    if [ $? -ne 0 ]; then
        echo "下载 miniconda 失败。"
        return 1
    fi
    bash "$MINICONDA_INSTALLER" -b -p "$HOME/miniconda3"
    if [ $? -ne 0 ]; then
        echo "安装 miniconda 失败。"
        return 1
    fi
    rm "$MINICONDA_INSTALLER"
    export PATH="$HOME/miniconda3/bin:$PATH"
    echo "miniconda 安装完成."
    return 0
}

# 创建 conda 环境并安装 OpenWebUI
install_openwebui_conda() {
    echo "开始创建 conda 环境并安装 OpenWebUI..."
    export PATH="$HOME/miniconda3/bin:$PATH"
    if [ -d "$CONDA_ENV_DIR" ]; then
      echo "conda 环境已存在，跳过创建步骤."
    else
      conda create -y -p "$CONDA_ENV_DIR" python=3.11
      if [ $? -ne 0 ]; then
          echo "创建 conda 环境失败。"
          return 1
      fi
    fi

    source "$HOME/miniconda3/bin/activate" "$CONDA_ENV_DIR"
    
    echo "安装 sqlite3..."
    conda install -y sqlite=3.40
    if [ $? -ne 0 ]; then
      echo "安装 sqlite3 失败"
      return 1
    fi
      
    echo "安装 OpenWebUI..."
    pip install --upgrade pip
    pip install open-webui
    if [ $? -ne 0 ]; then
      echo "安装 OpenWebUI 失败."
      return 1
    fi
    
    echo "安装 ffmpeg..."
    conda install -y ffmpeg
    if [ $? -ne 0 ]; then
        echo "安装 ffmpeg 失败。"
        return 1
    fi
  
    # 检查 open-webui 是否真的安装到了虚拟环境
    if ! command_exists "$CONDA_ENV_DIR/bin/open-webui"; then
      echo "错误: open-webui 未安装到 conda 环境，请检查安装过程"
      return 1
    fi
    
    echo "OpenWebUI 安装完成."
    return 0
}

# 检查 OpenWebUI 是否需要更新 (使用 pip list 和 --outdated)
check_openwebui_update() {
  echo "检查 OpenWebUI 更新..."
  source "$HOME/miniconda3/bin/activate" "$CONDA_ENV_DIR"
    local current_version
    current_version=$("$CONDA_ENV_DIR/bin/pip" show open-webui | grep "Version:" | awk '{print $2}')

    if [ -z "$current_version" ]; then
        echo "无法获取当前 OpenWebUI 版本，跳过更新检查"
        return 1
    fi

    local outdated
    outdated=$("$CONDA_ENV_DIR/bin/pip" list --outdated | grep "open-webui" )

    if [[ -n "$outdated" ]]; then
        echo "发现 OpenWebUI 新版本，开始更新..."
        "$CONDA_ENV_DIR/bin/pip" install --upgrade open-webui
        if [ $? -ne 0 ]; then
          echo "OpenWebUI 更新失败."
          return 1
        fi
        echo "OpenWebUI 更新完成."
    else
        echo "OpenWebUI 已是最新版本: $current_version."
    fi
  conda deactivate
  return 0
}

# 安装 ngrok (现在从已上传的压缩包解压)
install_ngrok() {
  echo "开始安装 ngrok..."
    if [ ! -f "$NGROK_TGZ_PATH" ]; then
        echo "ngrok 压缩包 ($NGROK_TGZ_PATH) 未找到，请将 ngrok 压缩包上传到根目录。"
        return 1
    fi
    
    if [ -d "$NGROK_DIR" ] && command_exists "$NGROK_DIR/ngrok"; then
      echo "ngrok 已安装，跳过安装步骤."
      return 0
    fi

  mkdir -p "$NGROK_DIR"
  tar -xzf "$NGROK_TGZ_PATH" -C "$NGROK_DIR"
  if [ $? -ne 0 ]; then
    echo "解压 ngrok 压缩包失败."
    return 1
  fi
  
  chmod +x "$NGROK_DIR/ngrok"
  echo "ngrok 安装完成."
  return 0
}

# 启动 ngrok
start_ngrok() {
    if [ ! -d "$NGROK_DIR" ] || ! command_exists "$NGROK_DIR/ngrok" ; then
        echo "ngrok 未找到，请确保已安装 ngrok。"
        return 1
    fi
  echo "启动 ngrok..."
  "$NGROK_DIR/ngrok" config add-authtoken "$NGROK_AUTH_TOKEN"
    if [ $? -ne 0 ]; then
        echo "设置 ngrok token 失败."
        return 1
    fi
  "$NGROK_DIR/ngrok" http --domain="$NGROK_DOMAIN" "$OPENWEBUI_PORT" > "$NGROK_DIR/ngrok.log" 2>&1 &
    if [ $? -ne 0 ]; then
        echo "启动 ngrok 失败."
        return 1
    fi
  echo "ngrok 启动成功，日志保存在: $NGROK_DIR/ngrok.log"
  return 0
}

# 启动 OpenWebUI
start_openwebui() {
  echo "启动 OpenWebUI..."
  source "$HOME/miniconda3/bin/activate" "$CONDA_ENV_DIR"
  
  # 检查 ffmpeg 是否已安装，如果需要音频处理
  if ! command_exists ffmpeg; then
    echo "警告: ffmpeg 未安装，音频处理功能可能无法使用。"
  fi

  # 尝试直接启动 OpenWebUI，不使用nohup，方便查看错误
  "$CONDA_ENV_DIR/bin/open-webui" serve --host 0.0.0.0 --port "$OPENWEBUI_PORT" &
  OPENWEBUI_PID=$!

  echo "OpenWebUI 启动成功，监听端口: $OPENWEBUI_PORT，日志保存在: $OPENWEBUI_DIR/openwebui.log"
  conda deactivate
  
  return 0
}

# --- 主逻辑 ---

# 创建安装目录
mkdir -p "$OPENWEBUI_DIR"
mkdir -p "$NGROK_DIR"
mkdir -p "$OPENWEBUI_MODEL_DIR" #创建模型目录

# 安装 miniconda
install_miniconda
if [ $? -ne 0 ]; then
    echo "miniconda 安装失败，请检查日志。"
    exit 1
fi

# 创建 conda 环境并安装 OpenWebUI
install_openwebui_conda
if [ $? -ne 0 ]; then
    echo "OpenWebUI 安装失败，请检查日志。"
    exit 1
fi

# 检查 OpenWebUI 更新
check_openwebui_update
if [ $? -ne 0 ]; then
    echo "OpenWebUI 更新检查失败，请检查日志。"
fi

# 安装 ngrok (从已上传的压缩包解压)
install_ngrok
if [ $? -ne 0 ]; then
    echo "ngrok 安装失败，请检查是否已上传 ngrok 压缩包到根目录。"
    exit 1
fi

# 启动 ngrok
start_ngrok
if [ $? -ne 0 ]; then
    echo "ngrok 启动失败，请检查日志。"
    exit 1
fi

# 启动 OpenWebUI
start_openwebui
if [ $? -eq 0 ]; then
    echo "所有服务启动完成."
    echo "请使用以下命令查看日志和管理服务:"
    echo ""
    echo "OpenWebUI:"
    echo "  - 启动: source $HOME/miniconda3/bin/activate $CONDA_ENV_DIR && $CONDA_ENV_DIR/bin/open-webui serve --host 0.0.0.0 --port $OPENWEBUI_PORT"
    echo "  - 日志: tail -f $OPENWEBUI_DIR/openwebui.log"
    echo "  - 重启: kill $OPENWEBUI_PID && source $HOME/miniconda3/bin/activate $CONDA_ENV_DIR && $CONDA_ENV_DIR/bin/open-webui serve --host 0.0.0.0 --port $OPENWEBUI_PORT &"
    echo ""
    echo "ngrok:"
    echo "  - 启动: $NGROK_DIR/ngrok http --domain=$NGROK_DOMAIN $OPENWEBUI_PORT"
    echo "  - 日志: tail -f $NGROK_DIR/ngrok.log"
    echo "  - 重启: killall ngrok && $NGROK_DIR/ngrok http --domain=$NGROK_DOMAIN $OPENWEBUI_PORT > $NGROK_DIR/ngrok.log 2>&1 &"
    echo ""
    echo "OpenWebUI 访问地址: http://$NGROK_DOMAIN"
else
    echo "服务启动失败，请检查日志。"
fi
