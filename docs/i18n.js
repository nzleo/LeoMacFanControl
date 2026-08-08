const LANGS = ["zh", "en", "ja"];
const LANG_ATTR = { zh: "zh-CN", en: "en", ja: "ja" };
const STORAGE_KEY = "leofan-lang";

const I18N = {
  zh: {
    "meta.title": "Leo 风扇控制 — macOS 菜单栏温控",
    "meta.description": "让 Mac 在高负载时真的把风扇转起来。按 CPU 温度自动调速或闭环稳温，支持 Apple 芯片与 Intel，开源免费。",
    "nav.why": "为什么",
    "nav.modes": "模式",
    "nav.install": "安装",
    "nav.series": "其他作品",
    "nav.download": "下载",
    "hero.eyebrow": "开源 · macOS 13+ · Apple Silicon & Intel",
    "hero.title": "Leo 风扇控制",
    "hero.sub": "让高负载时风扇真的转起来",
    "hero.lede": "菜单栏小工具：看温度、控转速。按曲线自动调速，或把核心平均温度闭环稳定在你指定的目标值。零网络、可审计、MIT。",
    "hero.ctaDownload": "下载最新版 DMG",
    "hero.ctaRepo": "查看源码",
    "hero.meta": "约 1.7 MB · 通用二进制 · 最新 v1.3",
    "hero.imgAlt": "Leo 风扇控制面板：目标温度 70°C，守护进程运行中",
    "why.title": "它解决什么问题",
    "why.desc": "macOS 默认风扇策略偏保守。满载时风扇常死守最低转速，温度一路爬升到芯片降频。这个工具把控速能力交还给你。",
    "why.badLabel": "macOS 默认 · 1000 RPM",
    "why.badTemp": "> 87°C",
    "why.badDesc": "核心平均持续上升，单核峰值可超 103°C。90 秒仍未收敛。",
    "why.goodLabel": "强制满速 · 4900 RPM",
    "why.goodTemp": "≈ 65°C",
    "why.goodDesc": "约 30 秒收敛稳定。同机同负载，温差约 22°C。",
    "why.note": "数据来自 M4 Mac mini（Mac16,10）10 线程满载实测。空闲约 52°C，曲线起点在此之上，闲时不会无谓提速。",
    "modes.title": "四种控制模式",
    "modes.desc": "从菜单栏点开面板即可切换。另有高温保护：单核峰值超阈值就强制满速。",
    "modes.aTitle": "系统自动",
    "modes.aDesc": "交还给 macOS。默认最安全，只监控不控速。",
    "modes.bTitle": "自动温控",
    "modes.bDesc": "按温度曲线升降速，可选静音 / 均衡 / 强力降温。",
    "modes.tag": "推荐",
    "modes.cTitle": "目标温度",
    "modes.cDesc": "设一个目标（如 70°C），风扇自动找到刚好压住它的转速。低于目标 4°C 才降速，避免抽速。",
    "modes.dTitle": "手动固定",
    "modes.dDesc": "用滑块锁一个固定转速百分比，适合先确认风扇是否响应。",
    "features.title": "设计取舍",
    "features.desc": "控速必须有 root。市面上同类软件你很难逐行确认它还做了什么——这里全部可审计。",
    "features.aTitle": "零网络",
    "features.aDesc": "不发任何请求。全工程只有本机 Unix socket，用于 GUI 与守护进程通信。",
    "features.bTitle": "源码可审",
    "features.bDesc": "只用 Apple 自带框架，无第三方依赖。MIT 开源。",
    "features.cTitle": "守护进程收敛",
    "features.cDesc": "root 进程只读写 SMC 风扇键，不监听网络端口。",
    "features.dTitle": "通用二进制",
    "features.dDesc": "Apple 芯片与 Intel 都能装。需要 macOS 13 或更高。",
    "install.title": "下载与安装",
    "install.desc": "先装 App 就能监控；要控速再装守护进程（需要一次管理员密码）。",
    "install.1t": "下载 DMG 并拖进「应用程序」",
    "install.1dHtml": "从 <a href=\"https://github.com/nzleo/LeoMacFanControl/releases/latest\">Releases</a> 下载 <code>LeoFanControl-*.dmg</code>，把 App 拖到应用程序文件夹。",
    "install.2t": "首次打开手动放行",
    "install.2dHtml": "未做 Apple 公证，会被 Gatekeeper 拦。按住 Control 点击 App → 打开 → 再点打开。或：<code>xattr -dr com.apple.quarantine /Applications/LeoFanControl.app</code>",
    "install.3t": "在菜单栏找到风扇图标",
    "install.3d": "没有窗口、不进程序坞。顶部菜单栏会出现风扇图标和当前温度。",
    "install.4t": "（可选）安装守护进程以控速",
    "install.4dHtml": "打开终端，进入 DMG 里的「守护进程（控速必需）」文件夹，执行 <code>sudo ./install.sh</code>。面板右上角会显示「守护进程运行中」。",
    "gate.eyebrow": "首次打开必看",
    "gate.title": "「无法验证开发者」是正常的",
    "gate.p": "这个 App 没有购买每年 99 美元的开发者证书，也未做公证。系统拦一下不代表文件损坏。",
    "gate.s1": "在「应用程序」里找到 LeoFanControl",
    "gate.s2Html": "<strong>按住 Control 键点击</strong> → 选择「打开」",
    "gate.s3": "弹窗里再点一次「打开」",
    "gate.asideTitle": "命令行最快",
    "shots.title": "长什么样",
    "shots.desc": "菜单栏常驻温度；点开就是完整控制面板。",
    "shots.panelAlt": "控制面板特写：目标温度模式",
    "shots.panelCap": "目标温度模式实拍。右上角绿色「守护进程运行中」+ 蓝色「正在控速」表示控速已生效。",
    "shots.menuAlt": "菜单栏上的风扇图标与温度",
    "shots.menuCap": "菜单栏：风扇图标 + 当前核心平均温度。按住 Command 可拖动位置。",
    "download.title": "下载并开始用",
    "download.desc": "免费开源。装完先监控，需要时再装守护进程接管风扇。",
    "download.cta": "下载 LeoFanControl DMG",
    "download.repo": "GitHub 仓库",
    "download.meta": "v1.3 · MIT License · 使用风扇控制请自担风险",
    "series.title": "Leo 开源系列",
    "series.desc": "看看我的其他作品。",
    "series.current": "当前页面",
    "series.other": "其他作品",
    "series.fanTitle": "Leo 风扇控制",
    "series.fanDesc": "macOS 菜单栏温控：按 CPU 温度自动调速或闭环稳温。",
    "series.mdDesc": "轻量 macOS Markdown 阅读 / 编辑：双击打开，左侧目录，右侧正文。",
    "series.tourboxDesc": "TourBox 键位预设分享：模型、推理强度、活跃任务、审批与全局语音一手搞定。",
    "footer.copy": "Leo 风扇控制 · MIT · 由 nzleo 维护",
    "footer.repo": "源码",
    "footer.md": "LeoMDReader",
    "footer.tourbox": "TourBox 预设",
    "footer.trouble": "故障排查"
  },
  en: {
    "meta.title": "Leo Fan Control — macOS menu-bar thermal control",
    "meta.description": "Make your Mac actually spin up the fans under load. Auto curves or closed-loop target temps. Apple Silicon & Intel. Free and open source.",
    "nav.why": "Why",
    "nav.modes": "Modes",
    "nav.install": "Install",
    "nav.series": "More work",
    "nav.download": "Download",
    "hero.eyebrow": "Open source · macOS 13+ · Apple Silicon & Intel",
    "hero.title": "Leo Fan Control",
    "hero.sub": "Make the fans actually spin under load",
    "hero.lede": "A menu-bar utility: watch temps, control RPM. Auto curves, or hold core average at a target you set. Zero network, auditable, MIT.",
    "hero.ctaDownload": "Download latest DMG",
    "hero.ctaRepo": "View source",
    "hero.meta": "~1.7 MB · universal binary · latest v1.3",
    "hero.imgAlt": "Leo Fan Control panel: target 70°C, daemon running",
    "why.title": "What it solves",
    "why.desc": "macOS fan policy is conservative. Under load the fans often stick at minimum RPM while temps climb toward thermal throttling. This tool gives control back to you.",
    "why.badLabel": "macOS default · 1000 RPM",
    "why.badTemp": "> 87°C",
    "why.badDesc": "Core average keeps rising; single-core peak can exceed 103°C. Still not settled after 90 seconds.",
    "why.goodLabel": "Forced max · 4900 RPM",
    "why.goodTemp": "≈ 65°C",
    "why.goodDesc": "Settles in about 30 seconds. Same machine, same load — ~22°C cooler.",
    "why.note": "Measured on M4 Mac mini (Mac16,10) with 10 threads at full load. Idle ~52°C; curves start above that so idle stays quiet.",
    "modes.title": "Four control modes",
    "modes.desc": "Switch from the menu-bar panel. Plus high-temp protection: force max RPM if single-core peak exceeds the threshold.",
    "modes.aTitle": "System auto",
    "modes.aDesc": "Hand control back to macOS. Safest default — monitor only.",
    "modes.bTitle": "Auto curve",
    "modes.bDesc": "Speed follows a temperature curve: Quiet / Balanced / Aggressive.",
    "modes.tag": "Recommended",
    "modes.cTitle": "Target temp",
    "modes.cDesc": "Pick a target (e.g. 70°C); fans find the RPM that holds it. Only slows when 4°C below target to avoid hunting.",
    "modes.dTitle": "Manual fixed",
    "modes.dDesc": "Lock a fixed RPM percentage — useful to confirm the fan responds first.",
    "features.title": "Design choices",
    "features.desc": "Fan control needs root. With many third-party apps you can’t audit what else that process does — here everything is reviewable.",
    "features.aTitle": "Zero network",
    "features.aDesc": "No outbound requests. Only a local Unix socket between GUI and daemon.",
    "features.bTitle": "Auditable source",
    "features.bDesc": "Apple frameworks only, no third-party deps. MIT licensed.",
    "features.cTitle": "Tight daemon",
    "features.cDesc": "Root process only reads/writes SMC fan keys — no network ports.",
    "features.dTitle": "Universal binary",
    "features.dDesc": "Runs on Apple Silicon and Intel. Requires macOS 13+.",
    "install.title": "Download & install",
    "install.desc": "Install the app to monitor; add the daemon only when you want control (one admin password).",
    "install.1t": "Download the DMG and drag into Applications",
    "install.1dHtml": "From <a href=\"https://github.com/nzleo/LeoMacFanControl/releases/latest\">Releases</a> grab <code>LeoFanControl-*.dmg</code> and drag the app into Applications.",
    "install.2t": "Bypass Gatekeeper on first open",
    "install.2dHtml": "Not notarized, so Gatekeeper blocks it. Control-click the app → Open → Open again. Or: <code>xattr -dr com.apple.quarantine /Applications/LeoFanControl.app</code>",
    "install.3t": "Find the fan icon in the menu bar",
    "install.3d": "No window, not in the Dock. A fan icon and current temperature appear in the menu bar.",
    "install.4t": "(Optional) Install the daemon to control fans",
    "install.4dHtml": "In Terminal, open the “daemon (required for control)” folder in the DMG and run <code>sudo ./install.sh</code>. The panel shows “Daemon running”.",
    "gate.eyebrow": "First launch",
    "gate.title": "“Unidentified developer” is expected",
    "gate.p": "No $99/year Apple Developer cert, not notarized. The block does not mean the file is corrupt.",
    "gate.s1": "Find LeoFanControl in Applications",
    "gate.s2Html": "<strong>Control-click</strong> → Open",
    "gate.s3": "Click Open again in the dialog",
    "gate.asideTitle": "Fastest via Terminal",
    "shots.title": "What it looks like",
    "shots.desc": "Temperature stays in the menu bar; click for the full control panel.",
    "shots.panelAlt": "Control panel close-up: target temperature mode",
    "shots.panelCap": "Target-temp mode. Green “Daemon running” + blue “Controlling” mean control is active.",
    "shots.menuAlt": "Menu-bar fan icon and temperature",
    "shots.menuCap": "Menu bar: fan icon + core average. Hold Command to reposition.",
    "download.title": "Download and start",
    "download.desc": "Free and open source. Monitor first; install the daemon when you want to take over the fans.",
    "download.cta": "Download LeoFanControl DMG",
    "download.repo": "GitHub repo",
    "download.meta": "v1.3 · MIT License · fan control at your own risk",
    "series.title": "Leo Open Source Series",
    "series.desc": "Check out my other work.",
    "series.current": "This page",
    "series.other": "More work",
    "series.fanTitle": "Leo Fan Control",
    "series.fanDesc": "macOS menu-bar thermal control — auto fan curves or closed-loop target temps.",
    "series.mdDesc": "Lightweight macOS Markdown reader/editor: double-click open, outline left, content right.",
    "series.tourboxDesc": "TourBox preset share: models, reasoning effort, active tasks, approvals, and global voice in one hand.",
    "footer.copy": "Leo Fan Control · MIT · by nzleo",
    "footer.repo": "Source",
    "footer.md": "LeoMDReader",
    "footer.tourbox": "TourBox preset",
    "footer.trouble": "Troubleshooting"
  },
  ja: {
    "meta.title": "Leo ファン制御 — macOS メニューバー温控",
    "meta.description": "高負荷時に本当にファンを回す。CPU 温度に応じた自動調速または目標温度の閉ループ制御。Apple Silicon / Intel 対応。無料オープンソース。",
    "nav.why": "なぜ",
    "nav.modes": "モード",
    "nav.install": "インストール",
    "nav.series": "他の作品",
    "nav.download": "ダウンロード",
    "hero.eyebrow": "オープンソース · macOS 13+ · Apple Silicon & Intel",
    "hero.title": "Leo ファン制御",
    "hero.sub": "高負荷時にファンを本当に回す",
    "hero.lede": "メニューバーの小さなツール。温度を見て回転数を制御。曲線に従う自動調速、またはコア平均温度を目標値に安定させる閉ループ。ゼロネットワーク、監査可能、MIT。",
    "hero.ctaDownload": "最新 DMG をダウンロード",
    "hero.ctaRepo": "ソースを見る",
    "hero.meta": "約 1.7 MB · ユニバーサルバイナリ · 最新 v1.3",
    "hero.imgAlt": "Leo ファン制御パネル：目標温度 70°C、デーモン稼働中",
    "why.title": "何を解決するか",
    "why.desc": "macOS の標準ファン戦略は控えめです。満負荷でも最低回転のまま温度が上がり、サーマルスロットリングに近づくことがあります。このツールで制御を取り戻します。",
    "why.badLabel": "macOS 標準 · 1000 RPM",
    "why.badTemp": "> 87°C",
    "why.badDesc": "コア平均が上昇し続け、単コアピークは 103°C 超も。90 秒でも収束せず。",
    "why.goodLabel": "強制最大 · 4900 RPM",
    "why.goodTemp": "≈ 65°C",
    "why.goodDesc": "約 30 秒で安定。同機・同負荷で約 22°C 差。",
    "why.note": "M4 Mac mini（Mac16,10）10 スレッド満負荷の実測。アイドル約 52°C。曲線の起点はその上なので、待機時は無駄に上げません。",
    "modes.title": "4 つの制御モード",
    "modes.desc": "メニューバーのパネルから切替。高温保護もあり：単コアピークが閾値を超えると強制最大回転。",
    "modes.aTitle": "システム自動",
    "modes.aDesc": "macOS に返す。最も安全な既定。監視のみ。",
    "modes.bTitle": "自動温控",
    "modes.bDesc": "温度曲線に従い昇降。静音 / バランス / 強力冷却。",
    "modes.tag": "おすすめ",
    "modes.cTitle": "目標温度",
    "modes.cDesc": "目標（例 70°C）を設定すると、ちょうど抑え込む回転数を自動探索。目標より 4°C 下がってから減速し、ハンチングを避ける。",
    "modes.dTitle": "手動固定",
    "modes.dDesc": "スライダーで固定パーセント。まずファンが応答するか確認するのに便利。",
    "features.title": "設計の取捨",
    "features.desc": "ファン制御には root が必要。市販ソフトではその先で何をするか監査しにくい——ここではすべて監査可能です。",
    "features.aTitle": "ゼロネットワーク",
    "features.aDesc": "外部通信なし。GUI とデーモン間のローカル Unix socket のみ。",
    "features.bTitle": "ソース監査可能",
    "features.bDesc": "Apple 純正フレームワークのみ、第三者依存なし。MIT。",
    "features.cTitle": "デーモンを絞る",
    "features.cDesc": "root プロセスは SMC ファンキーの読み書きのみ。ネットワークポートなし。",
    "features.dTitle": "ユニバーサル",
    "features.dDesc": "Apple Silicon と Intel 両対応。macOS 13 以上。",
    "install.title": "ダウンロードとインストール",
    "install.desc": "App を入れれば監視可能。制御するにはデーモンを追加（管理者パスワードが 1 回必要）。",
    "install.1t": "DMG をダウンロードし「アプリケーション」へ",
    "install.1dHtml": "<a href=\"https://github.com/nzleo/LeoMacFanControl/releases/latest\">Releases</a> から <code>LeoFanControl-*.dmg</code> を入手し、App をアプリケーションへドラッグ。",
    "install.2t": "初回は手動で許可",
    "install.2dHtml": "公証なしのため Gatekeeper に止まります。Control クリック → 開く → もう一度開く。または：<code>xattr -dr com.apple.quarantine /Applications/LeoFanControl.app</code>",
    "install.3t": "メニューバーのファンアイコンを探す",
    "install.3d": "ウィンドウなし、Dock にも出ません。メニューバーにファンと温度が出ます。",
    "install.4t": "（任意）制御用デーモンを入れる",
    "install.4dHtml": "ターミナルで DMG 内の「デーモン（制御に必要）」フォルダへ入り <code>sudo ./install.sh</code>。パネル右上に「デーモン稼働中」と出ます。",
    "gate.eyebrow": "初回起動の注意",
    "gate.title": "「開発元を確認できない」は正常です",
    "gate.p": "年額 99 ドルの開発者証明書も公証もありません。ブロックはファイル破損を意味しません。",
    "gate.s1": "「アプリケーション」で LeoFanControl を見つける",
    "gate.s2Html": "<strong>Control キーを押しながらクリック</strong> →「開く」",
    "gate.s3": "ダイアログでもう一度「開く」",
    "gate.asideTitle": "ターミナルが最速",
    "shots.title": "見た目",
    "shots.desc": "メニューバーに温度を常駐。クリックで制御パネル。",
    "shots.panelAlt": "制御パネル：目標温度モード",
    "shots.panelCap": "目標温度モードの実写。緑「デーモン稼働中」+ 青「制御中」で制御が有効。",
    "shots.menuAlt": "メニューバーのファンと温度",
    "shots.menuCap": "メニューバー：ファンアイコン + コア平均温度。Command 押しながらドラッグで移動。",
    "download.title": "ダウンロードして使う",
    "download.desc": "無料オープンソース。まず監視し、必要ならデーモンでファンを引き継ぎ。",
    "download.cta": "LeoFanControl DMG をダウンロード",
    "download.repo": "GitHub リポジトリ",
    "download.meta": "v1.3 · MIT License · ファン制御は自己責任で",
    "series.title": "Leo オープンソースシリーズ",
    "series.desc": "ほかの作品もどうぞ。",
    "series.current": "このページ",
    "series.other": "他の作品",
    "series.fanTitle": "Leo ファン制御",
    "series.fanDesc": "macOS メニューバー温控。CPU 温度に応じた自動調速または閉ループ安定化。",
    "series.mdDesc": "軽量 macOS Markdown リーダー / エディタ。ダブルクリックで開き、左目次・右本文。",
    "series.tourboxDesc": "TourBox プリセット共有：モデル・推論強度・アクティブタスク・承認・グローバル音声を一手に。",
    "footer.copy": "Leo ファン制御 · MIT · nzleo が維持",
    "footer.repo": "ソース",
    "footer.md": "LeoMDReader",
    "footer.tourbox": "TourBox プリセット",
    "footer.trouble": "トラブルシュート"
  }
};

function detectLang() {
  const q = new URLSearchParams(location.search).get("lang");
  if (LANGS.includes(q)) return q;
  const saved = localStorage.getItem(STORAGE_KEY);
  if (LANGS.includes(saved)) return saved;
  const nav = (navigator.language || "zh").toLowerCase();
  if (nav.startsWith("ja")) return "ja";
  if (nav.startsWith("en")) return "en";
  return "zh";
}

function applyLang(lang) {
  const dict = I18N[lang] || I18N.zh;
  document.documentElement.lang = LANG_ATTR[lang];
  document.title = dict["meta.title"];
  const meta = document.querySelector('meta[name="description"]');
  if (meta) meta.setAttribute("content", dict["meta.description"]);
  document.querySelectorAll("[data-i18n]").forEach((el) => {
    const key = el.getAttribute("data-i18n");
    if (dict[key] != null) el.textContent = dict[key];
  });
  document.querySelectorAll("[data-i18n-html]").forEach((el) => {
    const key = el.getAttribute("data-i18n-html");
    if (dict[key] != null) el.innerHTML = dict[key];
  });
  document.querySelectorAll("[data-i18n-alt]").forEach((el) => {
    const key = el.getAttribute("data-i18n-alt");
    if (dict[key] != null) el.setAttribute("alt", dict[key]);
  });
  document.querySelectorAll(".lang-switch button").forEach((btn) => {
    btn.setAttribute("aria-pressed", btn.dataset.lang === lang ? "true" : "false");
  });
  localStorage.setItem(STORAGE_KEY, lang);
  const url = new URL(location.href);
  url.searchParams.set("lang", lang);
  history.replaceState(null, "", url);
}

document.addEventListener("DOMContentLoaded", () => {
  applyLang(detectLang());
  document.querySelectorAll(".lang-switch button").forEach((btn) => {
    btn.addEventListener("click", () => applyLang(btn.dataset.lang));
  });

  const nav = document.querySelector(".nav-shell");
  if (nav) {
    const onScroll = () => {
      nav.classList.toggle("is-scrolled", window.scrollY > 8);
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }
});
