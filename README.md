# ncproxy.sh

自建脚本，目前还有些功能未能完善。

## 使用教程

您可以选择以下两种方式运行脚本：

**方式一：下载并执行**

1.  **下载脚本**

    您可以使用以下命令下载脚本：

    ```bash
    wget -N https://raw.githubusercontent.com/yukinomi-git/nginxpromax.sh/refs/heads/main/ncproxy.sh
    ```
    ```bash
    wget -N https://raw.githubusercontent.com/yukinomi-git/nginxpromax.sh/refs/heads/main/cproxy.sh
    ```

2.  **赋予脚本执行权限**

    下载完成后，您需要为脚本添加可执行权限：

    ```bash
    chmod +x ncproxy.sh
    ```
    ```bash
    chmod +x cproxy.sh
    ```

3.  **运行脚本**

    最后，您可以执行脚本：

    ```bash
    ./ncproxy.sh
    ```
     ```bash
    ./cproxy.sh
    ```

**方式二：直接运行**

您也可以使用以下命令直接运行脚本，无需先下载：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/yukinomi-git/nginxpromax.sh/refs/heads/main/ncproxy.sh)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/yukinomi-git/nginxpromax.sh/refs/heads/main/cproxy.sh)

