-- gopls の staticcheck stylecheck (ST系) を無効化する。
-- 日本語の doc コメント (例: `// ギフトの種類`) が
-- 「ST1021: comment on exported type should be of the form "Xxx ..."」等で
-- 大量に警告されるのを抑止する。
--
-- 補足:
--  * これらは staticcheck の "stylecheck" グループで、コードの正しさには無関係。
--  * チームの CI (golangci-lint) は staticcheck の SA 系のみで ST 系は元々無効なので、
--    無効化しても CI 挙動は変わらない。ここはエディタ (gopls) のノイズ抑止のみ。
--  * gopls は analyses にワイルドカードを使えないため ST 系を個別に列挙する。
return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      gopls = {
        settings = {
          gopls = {
            -- テスト用ファイル (//go:build test) を gopls に認識させる。
            -- これが無いと shared/testutils/... 等で
            -- "build constraints exclude all Go files" 警告が出る。
            -- CI の .golangci.yml も build-tags: [test] を指定済み。
            buildFlags = { "-tags=test" },
            analyses = {
              ST1000 = false, -- package comment
              ST1001 = false, -- dot imports
              ST1003 = false, -- naming conventions (initialisms 等)
              ST1005 = false, -- error strings の体裁
              ST1006 = false, -- receiver 名
              ST1008 = false, -- error は戻り値の最後
              ST1011 = false, -- time.Duration の命名
              ST1012 = false, -- error 変数の命名
              ST1013 = false, -- HTTP ステータス定数の使用
              ST1015 = false, -- switch の default 位置
              ST1016 = false, -- receiver 名の一貫性
              ST1017 = false, -- yoda 条件
              ST1018 = false, -- 制御文字を含む文字列
              ST1019 = false, -- import の重複
              ST1020 = false, -- comment on exported function の体裁
              ST1021 = false, -- comment on exported type の体裁
              ST1022 = false, -- comment on exported var の体裁
              ST1023 = false, -- 冗長な型宣言
            },
          },
        },
      },
    },
  },
}
