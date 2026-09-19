defmodule Sheetshow.MixProject do
  use Mix.Project

  @version "0.1.5"
  @source_url "https://github.com/zero-one-group/sheetshow"

  @description "Google Sheets from Elixir, as values, with a small database on a tab " <>
                 "and the same code over .xlsx files."

  def project do
    [
      app: :sheetshow,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      name: "Sheetshow",
      description: @description,
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  # `dev/` is scripts for a person to run, and `test/` and `assets/` are not the
  # library, so none of them ship.
  defp package do
    [
      licenses: ["Apache-2.0"],
      files: ~w(lib guides assets mix.exs README.md CHANGELOG.md LICENSE usage-rules.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  # Read by ex_doc, which is a dev-only dependency; see the README.
  defp docs do
    [
      main: "readme",
      # The logo and the badge the README shows; ex_doc copies the directory
      # into doc/ as is, and without this they are broken images on HexDocs.
      assets: %{"assets" => "assets"},
      extras: [
        "README.md",
        "guides/quick-start-google.md",
        "guides/quick-start-xlsx.md",
        "guides/google-setup.md",
        "guides/cookbook.md",
        "guides/instead-of-postgres.md",
        "guides/guarantees.md",
        "guides/cheatsheet.cheatmd",
        "usage-rules.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: [
          "guides/quick-start-google.md",
          "guides/quick-start-xlsx.md",
          "guides/google-setup.md",
          "guides/cookbook.md",
          "guides/instead-of-postgres.md"
        ],
        Reference: ["guides/guarantees.md", "guides/cheatsheet.cheatmd", "usage-rules.md"]
      ],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Start here": [Sheetshow],
        "Cells and layout": [
          Sheetshow.A1,
          Sheetshow.Cell,
          Sheetshow.Coord,
          Sheetshow.Range,
          Sheetshow.Style,
          Sheetshow.Value
        ],
        Plans: [
          Sheetshow.Op,
          Sheetshow.Op.AddSheet,
          Sheetshow.Op.AppendRows,
          Sheetshow.Op.DeleteRows,
          Sheetshow.Op.DeleteSheet,
          Sheetshow.Op.PutCells,
          Sheetshow.Op.SetDimensions
        ],
        "A database on a tab": [
          Sheetshow.Log,
          Sheetshow.Log.Event,
          Sheetshow.Schema,
          Sheetshow.Table,
          Sheetshow.Table.Change,
          Sheetshow.Table.Row,
          Sheetshow.Table.Snapshot,
          Sheetshow.ULID
        ],
        Backends: [
          Sheetshow.Backend,
          Sheetshow.Client,
          Sheetshow.Google,
          Sheetshow.Memory,
          Sheetshow.Store,
          Sheetshow.Store.Local,
          Sheetshow.Store.WebDAV,
          Sheetshow.Workbook,
          Sheetshow.Xlsx
        ],
        Credentials: [
          Sheetshow.OAuth,
          Sheetshow.ServiceAccount,
          Sheetshow.Token,
          Sheetshow.UserAccount
        ],
        Errors: [Sheetshow.CellError, Sheetshow.Error]
      ]
    ]
  end

  # :public_key signs the service-account assertion and vouches for Google's
  # certificate; :inets and :ssl are the HTTP client; :xmerl is the SAX parser
  # the xlsx backend reads worksheets with. No :logger, since the library does
  # not log.
  def application do
    [extra_applications: [:public_key, :inets, :ssl, :xmerl]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def cli do
    [preferred_envs: [check: :test, "check.all": :test]]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.36", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    gate = ["format --check-formatted", "compile --force --warnings-as-errors"]

    [
      check: gate ++ ["test"],
      "check.all": gate ++ ["test --include integration"]
    ]
  end
end
