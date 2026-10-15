#!/bin/bash
# ============================================================================
# Self-hosted Actions Runner —— 一键 注册 / 重启 / 注销
#
# 用法（在编译机上）:
#   RUNNER_TOKEN=<token> ./scripts/setup-runner.sh                 # 注册并启动
#   RUNNER_TOKEN=<token> PROXY_URL=http://<代理IP>:9001 ./scripts/setup-runner.sh
#   ./scripts/setup-runner.sh --start                              # 机器重启后重新拉起
#   RUNNER_TOKEN=<token> ./scripts/setup-runner.sh --uninstall     # 从 GitHub 注销（之后可放心删机）
#
# 环境变量:
#   RUNNER_TOKEN   GitHub token，两种皆可:
#                    1) fine-grained token（github_pat_...，需本仓库 Administration: read+write）
#                    2) 仓库 Settings → Actions → Runners 页面显示的一次性 registration token
#   RUNNER_NAME    runner 名称，默认 ubootmod-vm
#   PROXY_URL      HTTP 代理，如 http://192.168.101.1:9001（国内网络访问 GitHub 需要；
#                  写入 runner 的 .env，构建任务也会继承）
#   REPO / OWNER   默认自动识别本仓库（git remote 或目录名），OWNER 默认 dontshootitsme
#   RUNNER_VERSION 默认 2.338.0（已验证可用）
#
# 系统要求: x86_64 Linux（Ubuntu/Debian 均可），装好 git curl tar python3，
#           磁盘空闲 ≥ 60G（一次完整构建约 30G）。以普通用户运行即可，无需 root。
#
# 说明:
#   - runner 是仓库级的：一台机器可同时承载多个仓库的 runner，
#     每个仓库独立实例目录 ~/.runners/<仓库名>，互不干扰。
#   - 实例目录里保留 runner 二进制，机器上已有其他仓库的 tarball 缓存会自动复用。
#   - 注销走 REST API（DELETE /actions/runners/{id}）：官方 config.sh remove
#     在 fine-grained token 下会 404，且不支持 --name 参数，故不用它。
# ============================================================================
set -e

MODE="${1:-register}"
NAME="${RUNNER_NAME:-ubootmod-vm}"
VER="${RUNNER_VERSION:-2.338.0}"
TARBALL="actions-runner-linux-x64-$VER.tar.gz"

# --- 识别仓库 ---
if [ -z "${REPO:-}" ]; then
  REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^git@[^:]+:##; s#^https?://github.com/##; s#\.git$##' | awk -F/ '{print $NF}' || true)
  [ -n "$REPO" ] || REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
fi
OWNER="${OWNER:-dontshootitsme}"
DIR="$HOME/.runners/$REPO"

# --- 停掉本实例的进程（Listener 按路径匹配；run.sh 包装进程按 /proc cwd 定位）---
stop_instance() {
  pkill -f "$DIR/bin/Runner.Listener" 2>/dev/null || true
  for d in /proc/[0-9]*/cwd; do
    if [ "$(readlink "$d" 2>/dev/null)" = "$DIR" ]; then
      kill "$(basename "$(dirname "$d")")" 2>/dev/null || true
    fi
  done
}

# --- 注销 ---
if [ "$MODE" = "--uninstall" ] || [ "$MODE" = "uninstall" ]; then
  [ -d "$DIR" ] || { echo "本仓库没有 runner 实例（$DIR），无需注销"; exit 0; }
  stop_instance
  sleep 2
  if [ -n "${RUNNER_TOKEN:-}" ]; then
    export RUNNER_NAME="$NAME"
    for id in $(curl -sSL --max-time 30 \
        -H "Authorization: Bearer $RUNNER_TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$REPO/actions/runners" \
        | python3 -c 'import json,os,sys
try: rs=json.load(sys.stdin).get("runners",[])
except Exception: rs=[]
n=os.environ.get("RUNNER_NAME","")
[print(r["id"]) for r in rs if (not n or r.get("name")==n)]' 2>/dev/null); do
      code=$(curl -sSL --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer $RUNNER_TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$REPO/actions/runners/$id")
      echo "  已注销 runner id=$id (HTTP $code)"
    done
  else
    echo "未提供 RUNNER_TOKEN：只停了本地进程，未向 GitHub 注销"
  fi
  echo "==> $REPO 的 runner 已注销（实例目录 $DIR 保留，可手动删除）"
  exit 0
fi

# --- 启动已有实例 ---
if [ "$MODE" = "--start" ] || [ "$MODE" = "start" ]; then
  [ -d "$DIR" ] || { echo "找不到实例: $DIR（请先跑注册流程）" >&2; exit 1; }
  cd "$DIR"
  stop_instance
  sleep 2
  nohup ./run.sh > "$DIR/runner.log" 2>&1 &
  sleep 6
  tail -3 "$DIR/runner.log" 2>/dev/null
  echo "==> runner 已启动: $DIR"
  exit 0
fi

# --- 注册（默认） ---
: "${RUNNER_TOKEN:?需要 RUNNER_TOKEN（fine-grained token 或 registration token）}"
for c in git curl tar; do
  command -v "$c" > /dev/null || { echo "缺少依赖: $c（Ubuntu: apt install $c）" >&2; exit 1; }
done
df -h . | awk 'NR==2{gsub("G","",$3); if ($3+0 < 40) print "警告: 磁盘空闲不足 40G，完整构建需要约 30G"}'

mkdir -p "$HOME/.runners"
if [ ! -d "$DIR" ]; then
  mkdir -p "$DIR"
  CACHED=$(find "$HOME/.runners" /tmp -maxdepth 2 -name "$TARBALL" 2>/dev/null | head -1 || true)
  if [ -n "$CACHED" ]; then
    echo "==> 复用已缓存的 runner tarball: $CACHED"
    cp "$CACHED" /tmp/$TARBALL
  else
    echo "==> 下载 actions runner $VER"
    curl -sSL --max-time 600 -o /tmp/$TARBALL \
      "https://github.com/actions/runner/releases/download/v$VER/$TARBALL"
  fi
  tar xzf /tmp/$TARBALL -C "$DIR" --strip-components 1
fi
cd "$DIR"

# 代理（写入 .env；runner 进程及其触发的构建任务均继承）
if [ -n "${PROXY_URL:-}" ]; then
  cat > .env <<EOF
http_proxy=$PROXY_URL
https_proxy=$PROXY_URL
no_proxy=127.0.0.1,localhost
EOF
  chmod 600 .env
  echo "==> 已写入代理: $PROXY_URL"
fi

# PAT → 换一次性 registration token
RT="$RUNNER_TOKEN"
case "$RUNNER_TOKEN" in
  github_pat_*|ghp_*)
    echo "==> 获取一次性 registration token"
    RT=$(curl -sSL --max-time 30 \
      -H "Authorization: Bearer $RUNNER_TOKEN" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$OWNER/$REPO/actions/runners/registration-token" \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")')
    [ -n "$RT" ] || { echo "获取 registration token 失败（token 需本仓库 Administration: read+write）" >&2; exit 1; }
    ;;
esac

echo "==> 注册 $OWNER/$REPO 的 runner（名称: $NAME）"
./config.sh --url "https://github.com/$OWNER/$REPO" --name "$NAME" --token "$RT" --replace --no-prompt

stop_instance
sleep 2
nohup ./run.sh > "$DIR/runner.log" 2>&1 &
sleep 8
tail -5 "$DIR/runner.log" 2>/dev/null
echo
echo "==> 完成。验证: 仓库 Settings → Actions → Runners 应显示 $NAME online"
echo "    实例目录: $DIR   日志: $DIR/runner.log"
echo "    机器重启后恢复: ./scripts/setup-runner.sh --start"
