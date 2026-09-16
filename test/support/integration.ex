defmodule Sheetshow.Integration do
  @moduledoc false
  # Shared ground for the integration tests.
  #
  # They live in five files rather than one because ExUnit runs test *modules*
  # concurrently and the tests inside a module serially, so splitting the file
  # is the only thing that makes them overlap.
  #
  # No macro: each file says `import Sheetshow.Integration` and writes its own
  # four lines of preamble.
  #
  # The suite is written to fit inside Google's quota of 60 writes a minute with
  # room to spare, and the way it does that is to spend no request on anything
  # that is not the thing under test: a tab is created by the first write that
  # names it (see `tab/0`) and every tab goes in one batch at the end of the run
  # (see `clean_up/0`). An add and a delete per test was 27 of the suite's 49
  # writes, none of them testing anything.

  alias Sheetshow.{Op, ServiceAccount, Workbook}

  @credentials "SHEETSHOW_TEST_CREDENTIALS"
  @spreadsheet "SHEETSHOW_TEST_SPREADSHEET_ID"

  # Every tab these tests make, and nothing else in the spreadsheet.
  @temporary ~r/^sheetshow \d+/

  @doc "Whether there is an account and a spreadsheet to test against."
  def configured? do
    System.get_env(@credentials) != nil and System.get_env(@spreadsheet) != nil
  end

  def spreadsheet_id, do: System.fetch_env!(@spreadsheet)

  @doc """
  Starts the one thing these tests own: an agent holding the connected workbook.

  Five modules starting at once would otherwise each mint a token and fetch the
  metadata, five TLS handshakes deep before any of them has warmed anything.
  The agent serialises that into one connection the five then share, and a workbook
  is an immutable value, so sharing it is just sharing a number and a token.
  """
  def start, do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc "The connected workbook, as `setup_all`. Connects once per run."
  def connect do
    dialled =
      Agent.get_and_update(
        __MODULE__,
        fn
          nil ->
            case dial() do
              {:ok, workbook} -> {{:ok, workbook}, workbook}
              {:error, _} = error -> {error, nil}
            end

          workbook ->
            {{:ok, workbook}, workbook}
        end,
        60_000
      )

    case dialled do
      {:ok, workbook} -> %{workbook: workbook}
      {:error, error} -> raise error
    end
  end

  # Nothing here raises: an exception inside the agent would kill it, and the
  # link would take the whole run with it. The error travels back and is raised
  # in the test's own process, where it reads as one failed setup_all.
  defp dial do
    with {:ok, account} <- account(System.fetch_env!(@credentials)) do
      spreadsheet_id() |> Workbook.google(credentials: account) |> Sheetshow.connect()
    end
  end

  defp account("{" <> _ = json), do: ServiceAccount.from_json(json)
  defp account(path), do: ServiceAccount.from_file(path)

  @doc """
  A tab of this test's own: a name, not a request.

  Nothing is created here. `plan/2` puts an `AddSheet` in front of the cells for
  any sheet the workbook does not know, so the tab arrives in the same batch as
  the first cells written to it: one request instead of two, and it is that
  create-and-write path being exercised against the real API rather than only
  against `Memory`. A test that wants a tab must therefore write to it before it
  reads it, which every one of them does.

  The name carries a space so it can never read as an A1 reference, and a unique
  number so that two files running at once never ask for the same one, which,
  since a sheet's id comes from its title, is also what keeps their ids apart.
  """
  def tab, do: "sheetshow #{System.unique_integer([:positive])}"

  @doc "Plans the cells and writes them, making any tab they name on the way."
  def write(workbook, cells) do
    {:ok, workbook} =
      cells
      |> Sheetshow.plan!(existing_sheets: Map.keys(workbook.sheets))
      |> Sheetshow.run(workbook)

    workbook
  end

  @doc "A sheet title as an A1 range, quoted because these titles have spaces."
  def quoted(title), do: "'#{title}'"

  @doc """
  Takes away every tab the run made, in one request. Called once, from
  `ExUnit.after_suite/1`.

  It sweeps by name rather than by keeping a list, which costs one `fetch_sheets`
  and means a tab left behind by a run that was killed goes too. The test
  spreadsheet holds nothing else that could be called `sheetshow 123`.

  A failure here is printed rather than raised: the tests have already run, and a
  leaked tab is not a broken build.
  """
  def clean_up do
    if Process.whereis(__MODULE__) do
      case Agent.get(__MODULE__, & &1) do
        %Workbook{} = workbook -> sweep(workbook)
        _never_dialled -> :ok
      end
    else
      :ok
    end
  end

  defp sweep(workbook) do
    with {:ok, workbook} <- Sheetshow.fetch_sheets(workbook),
         plan = Enum.map(temporary(workbook.sheets), &Op.DeleteSheet.new/1),
         {:ok, _workbook} <- Sheetshow.run(plan, workbook) do
      :ok
    else
      {:error, error} ->
        IO.puts("\nThe test tabs could not be cleaned up: #{Exception.message(error)}")
    end
  end

  defp temporary(sheets) do
    for {title, _id} <- sheets, Regex.match?(@temporary, title), do: title
  end
end
