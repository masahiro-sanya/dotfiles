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

wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
  local background = "#5c6d74"
  local foreground = "#FFFFFF"
  local edge_background = "none"
  if tab.is_active then
    background = "#ae8b2d"
    foreground = "#FFFFFF"
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

----------------------------------------------------
-- keybinds
----------------------------------------------------
config.disable_default_key_bindings = true
config.keys = require("keybinds").keys
config.key_tables = require("keybinds").key_tables
config.leader = { key = "q", mods = "CTRL", timeout_milliseconds = 2000 }

return config
