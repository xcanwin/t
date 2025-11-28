# 介绍

好好学习的快速t

# 方法

## 当前环境运行

```
sudo bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"
```

## Docker容器运行

构建镜像

```
docker build -t xcanwin/t:latest -f t.Dockerfile .
docker image prune -f
```

运行容器
```
docker run -d --name xt --restart=always -p 8443:8443 xcanwin/t:latest
# 或者
docker run -d --name xt --restart=always -p 8443:8443 -p 80:80 -e DOMAIN_XRAY=localhost -e PORT_XRAY=8443 -e PASS_XRAY=TMPtmp-8 xcanwin/t:latest
```

配置容器自启动
```
podman generate systemd --name xt --files --new
mkdir -p $HOME/.config/systemd/user/
cp container-xt.service $HOME/.config/systemd/user/
systemctl enable --user container-xt.service
```
