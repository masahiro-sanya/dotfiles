return {
  {
    "keaising/im-select.nvim",
    event = "VeryLazy",
    cond = function()
      return vim.fn.has("mac") == 1 and vim.fn.executable("macism") == 1
    end,
    opts = {
      default_im_select = "com.apple.inputmethod.Kotoeri.RomajiTyping.Roman",
      default_command = "macism",
      set_default_events = { "VimEnter", "InsertLeave", "CmdlineLeave" },
      set_previous_events = { "InsertEnter" },
      keep_quiet_on_no_binary = false,
      async_switch_im = true,
    },
  },
}
