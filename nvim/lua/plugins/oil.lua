return {
  { "nvim-neo-tree/neo-tree.nvim", enabled = false },
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
    },
  },
  {
    "stevearc/oil.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    keys = {
      {
        "<leader>e",
        function()
          require("oil").open()
        end,
        desc = "Open parent directory",
      },
    },
    opts = {
      view_options = {
        show_hidden = true,
        is_hidden_file = function()
          return false
        end,
      },
    },
  },
}
