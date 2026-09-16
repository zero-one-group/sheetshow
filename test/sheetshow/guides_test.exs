defmodule Sheetshow.GuidesTest do
  # `File.cd!/2` changes the working directory of the whole VM, so this module
  # cannot run beside others.
  use ExUnit.Case, async: false

  # The guides are run, not read: every fenced `elixir` block, in order, in one
  # binding, with the guide's own pattern matches as the assertions. A block that
  # would reach Google or a server is marked in the source and skipped, and the
  # test supplies the `workbook` such a block would have bound.

  alias Sheetshow.{Guides, Workbook}

  # Absolute, because some of these run from a scratch directory.
  @cookbook Path.expand("guides/cookbook.md")
  @postgres Path.expand("guides/instead-of-postgres.md")
  @xlsx Path.expand("guides/quick-start-xlsx.md")
  @google Path.expand("guides/quick-start-google.md")
  @setup Path.expand("guides/google-setup.md")

  describe "the xlsx quick start" do
    test "runs as written, in a directory of its own" do
      in_scratch_directory(fn ->
        binding = Guides.run(@xlsx)

        assert File.exists?("costs.xlsx")
        assert Workbook.titles(binding[:workbook]) == ["Costs", "expenses", "expenses log"]
      end)
    end
  end

  describe "the Google quick start" do
    test "runs against a memory workbook in place of the spreadsheet" do
      {:ok, workbook} = Sheetshow.connect(Workbook.memory())
      binding = Guides.run(@google, workbook: workbook)

      # The page tidies up after itself, so the spreadsheet is as it was.
      assert Workbook.titles(binding[:workbook]) == []
    end

    test "the code is the same as the xlsx page's, apart from the blocks the pages say differ" do
      # Both pages tell the same story; this keeps them from drifting apart
      # silently. Nine blocks (the cells, the plan, the log and the table) are
      # identical on both pages; the rest are about what only one backend does.
      xlsx = @xlsx |> Guides.blocks() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      google = @google |> Guides.blocks() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      assert MapSet.size(MapSet.intersection(xlsx, google)) == 9
    end
  end

  describe "the Google setup guide" do
    test "the blocks that need no account run as written" do
      binding = Guides.run(@setup)

      assert Sheetshow.UserAccount.authorized?(binding[:consented])
    end
  end

  for {guide, name} <- [{@cookbook, "the cookbook"}, {@postgres, "the Postgres guide"}] do
    describe name do
      test "runs against a memory workbook" do
        {:ok, workbook} = Sheetshow.connect(Workbook.memory())
        Guides.run(unquote(guide), workbook: workbook)
      end

      test "runs against an xlsx workbook" do
        in_scratch_directory(fn ->
          {:ok, workbook} = "guide.xlsx" |> Workbook.xlsx(create: true) |> Sheetshow.connect()
          Guides.run(unquote(guide), workbook: workbook)
        end)
      end
    end
  end

  defp in_scratch_directory(fun) do
    directory =
      Path.join(System.tmp_dir!(), "sheetshow-guide-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    File.cd!(directory, fun)
  end
end
