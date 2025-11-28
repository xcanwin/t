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
docker run -d --name xt --restart=always -p 80:80 -p 8443:8443 xcanwin/t:latest
# 或者
docker run -d --name xt --restart=always -p 8443:8443 xcanwin/t:latest
```
