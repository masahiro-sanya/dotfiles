return {
  {
    "williamboman/mason.nvim",
    opts = {
      ensure_installed = {
        -- Lua
        "stylua",
        -- Go
        "gopls",
        "goimports",
        "golangci-lint",
        -- Python
        "pyright",
        "ruff",
        "black",
        -- TypeScript / JavaScript
        "typescript-language-server",
        "prettierd",
        "eslint_d",
        -- Terraform
        "terraform-ls",
        "tflint",
        -- YAML
        "yaml-language-server",
        -- JSON
        "json-lsp",
        -- Docker
        "hadolint",
        -- Markdown
        "markdownlint-cli2",
      },
    },
  },
}
