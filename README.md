# CloudStudio_ngrok_ollam
可在腾讯云GPU上一键部署ollam的服务，并且远程基于API调用
## 使用说明
### 下载脚本到服务器一键执行
- 相关需要配置的参数已在脚本内说明
### 安装terminal keeper插件实现开机自动运行
- 配置请参照terminal-keeper.json里的文件内容
### 自定义CF隧道api权限
- 必需的权限
  
| 类型      | 资源                | 权限   | 用途                                  |
| --------- | ------------------- | ------ | ------------------------------------- |
| Account   | Cloudflare Tunnel    | 编辑   | 创建、删除、管理隧道                      |
| Account   | SSL and Certificates | 编辑   | 管理证书和隧道认证                        |
| Zone      | DNS                 | 编辑   | 管理 DNS 记录                            |
| Zone      | Zone                | 读取   | 获取 Zone 信息                           |
