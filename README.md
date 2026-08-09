# 介绍

好好学习的快速t

# 快速开始

## 当前环境运行

```
sudo bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"
# 或者
sudo MODE_XRAY=borrow bash -c "`curl -fsSL https://github.com/xcanwin/t/raw/main/t.sh`"
```

前者需要一个解析到本机的域名，后者需要一个外部站点。

## Docker容器运行

```
docker run -d --name xt -p 443:443 -p 80:80 -v xray:/opt/tool/xray xcanwin/t:latest
```

# 其他

## 构建与运行

构建镜像

```
git clone https://github.com/xcanwin/t.git
cd t
docker build -t xcanwin/t:latest -f t.Dockerfile .
docker image prune -f
```

新建并运行容器

```
docker run -d --name xt -p 443:443 -p 80:80 -e DOMAIN_XRAY=localhost -e PORT_XRAY=443 -v xray:/opt/tool/xray xcanwin/t:latest
```

配置容器自启动

```
podman generate systemd --name xt --files --new
mkdir -p $HOME/.config/systemd/user/
mv -f container-xt.service $HOME/.config/systemd/user/
systemctl enable --user container-xt.service
```

若需删除容器，需先删除自启动，再删除容器

```
systemctl disable --user container-xt.service
rm -rf $HOME/.config/systemd/user/container-xt.service
docker rm -f xt
```
