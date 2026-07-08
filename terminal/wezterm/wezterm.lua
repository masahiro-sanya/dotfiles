local wezterm = require("wezterm")
local config = wezterm.config_builder()

config.automatically_reload_config = true
config.font = wezterm.font("Ricty Diminished")
config.font_size = 15.0
config.use_ime = true
config.front_end = "WebGpu"
config.window_background_opacity = 0.85
config.macos_window_background_blur = 20

----------------------------------------------------
-- Tab
----------------------------------------------------
-- タイトルバーを非表示
config.window_decorations = "RESIZE"
-- タブバーの表示
config.show_tabs_in_tab_bar = true
-- タブが一つの時は非表示
config.hide_tab_bar_if_only_one_tab = true
-- falseにするとタブバーの透過が効かなくなる
-- config.use_fancy_tab_bar = false

-- タブバーの透過
config.window_frame = {
  inactive_titlebar_bg = "none",
  active_titlebar_bg = "none",
}

-- タブバーを背景色に合わせる
config.window_background_gradient = {
  colors = { "#000000" },
}

-- タブの追加ボタンを非表示
config.show_new_tab_button_in_tab_bar = false
-- nightlyのみ使用可能
-- タブの閉じるボタンを非表示
-- config.show_close_tab_button_in_tabs = false

-- タブ同士の境界線を非表示
config.colors = {
  tab_bar = {
    inactive_tab_edge = "none",
  },
}

-- タブの形をカスタマイズ
-- タブの左側の装飾
local SOLID_LEFT_ARROW = wezterm.nerdfonts.ple_lower_right_triangle
-- タブの右側の装飾
local SOLID_RIGHT_ARROW = wezterm.nerdfonts.ple_upper_left_triangle

-- pane の cwd(OSC 7 で通知される)を絶対パスに変換する
local function cwd_to_path(cwd)
  if cwd == nil then
    return nil
  end
  local s
  if type(cwd) == "userdata" then
    s = cwd.file_path or tostring(cwd)
  else
    s = tostring(cwd)
  end
  s = s:gsub("^file://[^/]*", "")               -- scheme + host を除去
  s = s:gsub("%%(%x%x)", function(h)             -- percent-decode
    return string.char(tonumber(h, 16))
  end)
  return s
end

-- 同期的な存在チェック。format-tab-title はコルーチン外で走るため、
-- 非同期の wezterm.glob は "attempt to yield" で落ちる。io/os で判定する。
local function path_exists(p)
  local f = io.open(p, "r")                       -- macOS は dir も open できる
  if f then
    f:close()
    return true
  end
  return os.rename(p, p) and true or false        -- 保険（自己リネームは no-op）
end

-- cwd から git リポ名を割り出す。.git が見つかるまで親を辿り、
-- 見つからなければ cwd の basename を返す。cwd 未通知なら nil。
-- format-tab-title は毎フレーム呼ばれるので cwd→リポ名 を memoize する。
local repo_cache = {}
local function repo_name(cwd)
  local path = cwd_to_path(cwd)
  if not path or path == "" then
    return nil
  end
  path = path:gsub("/+$", "")                    -- 末尾スラッシュ除去
  local cached = repo_cache[path]
  if cached ~= nil then
    return cached
  end
  local name
  local dir = path
  while dir ~= "" and dir ~= "/" do
    if path_exists(dir .. "/.git") then
      name = dir:match("([^/]+)$")
      break
    end
    dir = dir:match("(.*)/[^/]+$") or ""
  end
  name = name or path:match("([^/]+)$")          -- git 外は cwd の basename
  repo_cache[path] = name
  return name
end

-- Claude Code の稼働状態を hook から受け取る。
-- hook (claude/hooks/wezterm-status.sh) が pane_id 単位の状態ファイル
--   ~/.claude/wezterm-state/pane-<pane_id>   （中身: busy|waiting|idle|sub:N）
-- を書くので、それを読むだけ。OSC(SetUserVar)を使わないのは、Claude Code の hook 子
-- プロセスに制御端末が無く /dev/tty へ OSC を出しても WezTerm に届かないため。
local CLAUDE_STATE_DIR = (os.getenv("HOME") or "") .. "/.claude/wezterm-state"
local function read_claude_state(pane_id)
  if pane_id == nil then
    return nil
  end
  local f = io.open(CLAUDE_STATE_DIR .. "/pane-" .. tostring(pane_id), "r")
  if not f then
    return nil
  end
  local v = f:read("*l")                          -- hook は改行なしで1語だけ書く
  f:close()
  return v
end

-- 状態キー → 表示（アイコン・文言・背景色 active/非active の明暗2段）。サブは総数 n を文言に使う。
local function status_display(key, n)
  if key == "sub" then
    return { icon = "⚙", label = "サブ×" .. n, bg = "#6f4a9c", bg_dim = "#43305e" }
  elseif key == "busy" then
    return { icon = "●", label = "実行中", bg = "#2f6f9f", bg_dim = "#204d6e" }
  elseif key == "waiting" then
    return { icon = "⚠", label = "要対応", bg = "#c0562a", bg_dim = "#7f3a1c" }
  elseif key == "idle" then
    return { icon = "✓", label = "待機中", bg = "#4a7c59", bg_dim = "#33553d" }
  end
  return nil
end

-- タブ内の全ペインの Claude 状態を緊急度で集約する。分割で複数セッションを回しても、
-- 一番注意が要るものをタブに出す。優先度: 要対応 > サブ稼働(総数合算) > 実行中 > 待機中。
-- どのペインにも状態が無ければ nil（タブはリポ名だけ）。
local function claude_tab_status(panes)
  local any_waiting, any_busy, any_idle = false, false, false
  local sub_total = 0
  for _, p in ipairs(panes) do
    local v = read_claude_state(p.pane_id)
    if v and v ~= "" then
      local n = v:match("^sub:(%d+)$")
      if n then
        sub_total = sub_total + tonumber(n)
      elseif v == "waiting" then
        any_waiting = true
      elseif v == "busy" then
        any_busy = true
      elseif v == "idle" then
        any_idle = true
      end
    end
  end
  if any_waiting then return status_display("waiting") end
  if sub_total > 0 then return status_display("sub", sub_total) end
  if any_busy then return status_display("busy") end
  if any_idle then return status_display("idle") end
  return nil
end

wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
  -- Claude 稼働状態(タブ内全ペインを緊急度で集約)があれば状態色、無ければ従来の active/非active 色。
  local status = claude_tab_status(tab.panes)
  local background = "#5c6d74"
  local foreground = "#FFFFFF"
  local edge_background = "none"
  if status then
    background = tab.is_active and status.bg or status.bg_dim
  elseif tab.is_active then
    background = "#ae8b2d"
  end
  local edge_foreground = background

  -- アクティブ pane のリポ名を主役にし、他リポがあれば +N で示す。
  -- (全リポ併記はペーンが増えると見切れるため。per-pane 識別は statusline 側で担保)
  local active_repo = repo_name(tab.active_pane.current_working_dir)
  local seen = {}
  local distinct = 0
  for _, p in ipairs(tab.panes) do
    local r = repo_name(p.current_working_dir)
    if r and not seen[r] then
      seen[r] = true
      distinct = distinct + 1
    end
  end
  if active_repo == nil then
    active_repo = next(seen)                      -- アクティブが取れなければ任意の1つ
  end
  local label
  if active_repo == nil then
    label = tab.active_pane.title                -- cwd 全滅時のフォールバック
  elseif distinct > 1 then
    label = active_repo .. " +" .. (distinct - 1)  -- 他リポ数を添える
  else
    label = active_repo
  end

  -- Claude 稼働状態を先頭に添える（リポ名より前＝truncate されても状態は残す）
  if status then
    label = status.icon .. " " .. status.label .. "  " .. label
  end

  local title = "   " .. wezterm.truncate_right(label, max_width - 1) .. "   "
  return {
    { Background = { Color = edge_background } },
    { Foreground = { Color = edge_foreground } },
    { Text = SOLID_LEFT_ARROW },
    { Background = { Color = background } },
    { Foreground = { Color = foreground } },
    { Text = title },
    { Background = { Color = edge_background } },
    { Foreground = { Color = edge_foreground } },
    { Text = SOLID_RIGHT_ARROW },
  }
end)

-- Claude 稼働状態(ファイル)は busy/idle/sub の遷移時にペイン出力を伴わないことがあり、
-- その間タブバーが再描画されず表示が固まる（例: 思考中なのに「待機中」／サブ稼働中なのに「実行中」）。
-- format-tab-title は再描画時しか再評価されないので、update-status を status_update_interval 間隔で
-- 発火させ、毎回 右ステータスを"内容を変えて"セットしてウィンドウ(=タブバー含む)の再描画を強制する。
-- 右ステータスを毎回同じにすると WezTerm は「変化なし」で再描画を省くため、不可視のトグル(""↔" ")で
-- 内容を変える（右端の半角スペースは透過タブバー上で見えない）。これで最大 status_update_interval の
-- 遅延で状態表示が追従する。
config.status_update_interval = 1000
local _repaint_toggle = false
wezterm.on("update-status", function(window, _pane)
  _repaint_toggle = not _repaint_toggle
  window:set_right_status(_repaint_toggle and "" or " ")
end)

----------------------------------------------------
-- keybinds
----------------------------------------------------
config.disable_default_key_bindings = true
config.keys = require("keybinds").keys
config.key_tables = require("keybinds").key_tables
config.leader = { key = "q", mods = "CTRL", timeout_milliseconds = 2000 }

return config
