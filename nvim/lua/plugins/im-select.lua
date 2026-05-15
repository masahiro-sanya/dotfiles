return {
  {
    "keaising/im-select.nvim",
    lazy = false,
    priority = 100,
    cond = function()
      return vim.fn.has("mac") == 1 and vim.fn.executable("macism") == 1
    end,
    config = function()
      require("im_select").setup({
        default_im_select = "com.apple.keylayout.ABC",
        default_command = "macism",
        set_default_events = { "VimEnter", "FocusGained", "InsertLeave", "CmdlineLeave" },
        set_previous_events = { "InsertEnter" },
        keep_quiet_on_no_binary = false,
        async_switch_im = true,
      })
      vim.fn.jobstart({ "macism", "com.apple.keylayout.ABC" }, { detach = true })
    end,
  },
}
