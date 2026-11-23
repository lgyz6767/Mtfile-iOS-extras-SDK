# 上架到 MTFile 扩展市场

扩展市场是 App 里「扩展管理 → 右上角市场」那个页。它没有后端，就是 GitHub 上一个静态目录 + 一个自动生成的 `index.json`，客户端每 24 秒超时拉一次索引、点安装就直接下包。

- 市场仓库：`lgyz6767/lgyz6767.github.io`（分支 `main`）
- 市场目录：`repo/ext/`
- 索引（三线路，客户端按顺序试）：
  - `https://lgyz6767.github.io/repo/ext/index.json`
  - `https://raw.githubusercontent.com/lgyz6767/lgyz6767.github.io/main/repo/ext/index.json`
  - `https://cdn.jsdelivr.net/gh/lgyz6767/lgyz6767.github.io@main/repo/ext/index.json`

---

## 1. 先满足三个硬条件

1. 包内 `manifest.json` 的 `framework` 是 `v2.x`（推荐 `v2.1.0`）。
2. `manifest.id` **等于**市场里的目录名。例：`id = com.example.myext` → 目录 `repo/ext/com.example.myext/`。
3. manifest 里 `dylib` 指向的文件真实在包里。

另外：

- 一个目录只放**一个**扩展。一个包塞多个（多扩展合包）只能本地安装，上市场会被 CI 拒。
- 包名用 `.mtextra`（`.zip` 也认，但 `.mtextra` 才是正式格式）。
- 包别超过 100MB（GitHub 单文件硬限制；超过 50MB 会有警告，raw 仍可下）。

---

## 2. 目录结构

```
repo/ext/
├── index.json                       ← 自动生成，别手改
└── com.example.myext/
    ├── MyExt.mtextra                ← 你的包（必须）
    └── （可选）源码、截图、说明.md
```

`index.json` 由 GitHub Actions（`.github/workflows/ext-index.yml` → `scripts/build_ext_index.py`）在每次 `repo/ext/**` 变更后自动重建并提交回来。它会从包里读：

```
{ id, name, version, author, description, category, icon, iconImage, size, sha256,
  download: "<目录名>/<文件名>", format: "mtextra" | "zip" }
```

`download` 是相对 `repo/ext/` 的路径，客户端直接拼索引地址下载。

---

## 3. 上架流程（有写权限 / 走 PR 两条路）

### 3.1 自己有权限

```bash
git clone https://github.com/lgyz6767/lgyz6767.github.io.git
cd lgyz6767.github.io
mkdir -p repo/ext/com.example.myext
cp /path/to/MyExt.mtextra repo/ext/com.example.myext/
git add repo/ext/com.example.myext
git commit -m "ext: 上架 MyExt 1.0.0"
git push
```

推完等 Actions 跑完（约 1 分钟），`repo/ext/index.json` 会自动多一条。App 里进市场下拉刷新即可看到。

### 3.2 没有权限（外部开发者，推荐 PR）

1. Fork `lgyz6767/lgyz6767.github.io`。
2. 在 fork 里加 `repo/ext/<你的 id>/你的包.mtextra`。
3. 提 PR 到 `main`。PR 会自动跑索引校验：
   - 目录名 ≠ id → 红叉，改目录名
   - 包内没 manifest、framework 不是 v2、dylib 不存在、多 manifest → 红叉，按提示改
4. 合入后 Actions 自动生成索引，客户端就能装。

不会用 GitHub 的，把包发到反馈群（QQ 1137296245），由维护者合入。

---

## 4. 版本更新

- 改 `manifest.json` 的 `version`（如 `1.0.0` → `1.1.0`），重新打包。
- 同名覆盖旧包即可；同目录留了多个包时，索引按版本号取**最大**的那个。
- 客户端在扩展管理里会显示「有更新」，点更新就是重新下载安装（同 id 会覆盖安装目录、清回退副本）。

---

## 5. 上架前自检

- [ ] 真机装过：`.mtextra` 双击能装，侧栏能出现，页面能开
- [ ] `id` = 目录名，`version` 比上一版大
- [ ] 图标：`iconImage` 指向包内 PNG（128×128、透明底最好）；没有就写一个合理的 `icon`（SF Symbol）
- [ ] 如果用了联网 / 终端：代码里走 `MTExtNetRequest` / `MTExtShellRun`，拒绝和沙盒两种情况都有提示（见 `readme.md` 第 7 节）
- [ ] 包内没有夹带构建产物垃圾（`.DS_Store`、`__MACOSX`、调试日志）
