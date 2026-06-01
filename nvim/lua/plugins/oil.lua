return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        sources = {
          explorer = {
            hidden = true,
            ignored = true,
          },
        },
      },
      image = { enabled = false },
    },
  },
  {
    "stevearc/oil.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    keys = {
      {
        "<leader>o",
        function()
          require("oil").open()
        end,
        desc = "Open parent directory (oil)",
      },
    },
    opts = {
      -- 上部 (winbar) に現在ディレクトリのフルパスを常時固定表示する。
      -- ディレクトリを深く潜っても「今どこにいるか」が常に上部に出る。
      win_options = {
        winbar = "%{v:lua.require('oil').get_current_dir()}",
      },
      view_options = {
        show_hidden = true,
        is_hidden_file = function()
          return false
        end,
      },
    },
  },
}
