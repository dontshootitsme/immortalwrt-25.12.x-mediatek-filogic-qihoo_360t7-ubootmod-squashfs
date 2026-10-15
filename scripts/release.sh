#!/bin/sh
# ============================================================================
# 为指定版本创建/更新 GitHub Release（含 3 个镜像 + sha256sums.txt）
#
# 用法:
#   GITHUB_TOKEN=<token> ./scripts/release.sh <版本> [构建产物目录]
#   例:  GITHUB_TOKEN=xxx ./scripts/release.sh 25.12.2 ~/iwrt-build/iwrt-25.12.2/bin/targets/mediatek/filogic
#
# 说明:
#   - REPO 默认取本仓库 git 目录名（= GitHub 仓库名），OWNER 默认 dontshootitsme
#   - Release 若已存在则整体重建（删除后重建，保证附件干净无残留）
#   - 附件上传走官方 gh CLI（部分网络环境下 curl 直传资产接口不稳定）
# ============================================================================
set -e

VERSION="${1:?用法: GITHUB_TOKEN=xxx ./scripts/release.sh <版本> [产物目录]}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${2:-$HOME/iwrt-build/iwrt-$VERSION/bin/targets/mediatek/filogic}"
OWNER="${OWNER:-dontshootitsme}"
REPO="${REPO:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo $ROOT)")}"
TOKEN="${GITHUB_TOKEN:?需要 GITHUB_TOKEN（fine-grained token，需 Contents: read/write 权限）}"

[ -d "$SRC" ] || { echo "找不到产物目录: $SRC" >&2; exit 1; }
cd "$SRC"

# 3 个 ubootmod 镜像（initramfs / factory / sysupgrade）
FILES=$(ls *ubootmod* 2>/dev/null | grep -E 'initramfs-kernel|squashfs-factory|squashfs-sysupgrade' || true)
[ -n "$FILES" ] || { echo "产物目录里找不到 ubootmod 三件套: $SRC" >&2; exit 1; }
echo "==> 将发布: $(printf '%s\n' $FILES | tr '\n' ' ')"

sha256sum $FILES > sha256sums.txt

API="https://api.github.com/repos/$OWNER/$REPO"
H1="Authorization: Bearer $TOKEN"
H2="Accept: application/vnd.github+json"
TAG="v$VERSION"

# Release 说明（quoted heredoc：反引号安全，版本用 sed 注入）
NOTE_FILE=$(mktemp)
cat > "$NOTE_FILE" <<'EOF'
本 release 由本仓库 `config/__VERSION__.config` 构建（官方 __VERSION__ tag + 本仓库 ubootmod overlay）。

| 文件 | 用途 |
|---|---|
| `*-initramfs-kernel.bin` | FIT 内核镜像（恢复/调试用；刷不死网页**不**吃它） |
| `*-squashfs-factory.bin` | **完整 UBI 镜像**——刷不死 U-Boot 网页（192.168.1.1）直接上传此文件 |
| `*-squashfs-sysupgrade.bin` | 在**运行中的系统内** sysupgrade 升级用（保留配置） |

## 刷机
1. 按住 reset + 通电 5~10 秒，进刷不死 U-Boot 网页（192.168.1.1，电脑直连 LAN 口设 192.168.1.2/24）
2. 上传 `*-squashfs-factory.bin` → 重启 → 完整系统
3. 版本间升级（保留配置）：把 `*-squashfs-sysupgrade.bin` 传入运行系统后执行 `sysupgrade <该文件>`
   （跨版本回退旧版时可能需 `sysupgrade -f`，见仓库 README）

## 红线
**不要刷 fip/preloader 分区**（会替换你的刷不死 U-Boot，失去恢复能力）。

SHA256 见 `sha256sums.txt`。
EOF
sed "s/__VERSION__/$VERSION/g" "$NOTE_FILE" > "$NOTE_FILE.v" && mv "$NOTE_FILE.v" "$NOTE_FILE"

# JSON 请求体（python 构造，避免引号地狱）
REL_JSON=$(python3 -c '
import json, sys
body = open(sys.argv[1]).read()
print(json.dumps({"tag_name": sys.argv[2], "name": "ImmortalWrt " + sys.argv[3] + " (ubootmod)", "body": body}))
' "$NOTE_FILE" "$TAG" "$VERSION")

# 已存在的 release 整体删除（含残留附件），随后重建
OLD=$(curl -sS --max-time 30 -H "$H1" -H "$H2" "$API/releases/tags/$TAG")
OLD_ID=$(printf '%s' "$OLD" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("id",""))
except Exception:
    print("")')
if [ -n "$OLD_ID" ]; then
  echo "==> 删除已存在的 release $OLD_ID（重建以保证附件干净）"
  curl -sS --max-time 30 -X DELETE -H "$H1" -H "$H2" "$API/releases/$OLD_ID" > /dev/null || true
  sleep 2
fi

echo "==> 创建 release $TAG"
printf '%s' "$REL_JSON" > /tmp/rel_create.json
CREATED=$(curl -sS --max-time 30 -X POST -H "$H1" -H "$H2" -d @/tmp/rel_create.json "$API/releases")
RID=$(printf '%s' "$CREATED" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("id",""))
except Exception:
    print("")')
[ -n "$RID" ] || { echo "创建 release 失败: $(printf '%s' "$CREATED" | head -c 300)" >&2; exit 1; }

# 上传附件：官方 gh CLI（缺失时自动下载）
GH=$(command -v gh 2>/dev/null || true)
if [ -z "$GH" ] && [ -x /tmp/gh ]; then GH=/tmp/gh; fi
if [ -z "$GH" ]; then
  echo "==> 安装 gh CLI"
  curl -sSL --max-time 300 -o /tmp/gh.tgz \
    "https://github.com/cli/cli/releases/download/v2.63.2/gh_2.63.2_linux_amd64.tar.gz"
  tar xzf /tmp/gh.tgz -C /tmp
  GH=/tmp/gh_2.63.2_linux_amd64/bin/gh
  chmod +x "$GH"
fi
echo "==> 上传附件（gh release upload）"
GH_TOKEN="$TOKEN" "$GH" release upload "$TAG" $FILES sha256sums.txt \
  --repo "$OWNER/$REPO" --clobber

echo "==> 完成: https://github.com/$OWNER/$REPO/releases/tag/$TAG"
