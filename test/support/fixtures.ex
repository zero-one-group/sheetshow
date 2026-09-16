defmodule Sheetshow.Fixtures do
  @moduledoc false
  # Recorded answers from the real API, so the offline tests stop guessing at
  # Google's exact JSON.
  #
  # These are committed to a public repo, so nothing that identifies the
  # spreadsheet or the people who can see it goes in. `scrub/2` is what makes
  # that true, and it is tested offline like anything else.

  @secret_keys ~w(user owners emailAddress authorization Authorization access_token)
  @email ~r/[\w.+-]+@[\w-]+\.[\w.-]+/
  @tab ~r/sheetshow \d+/

  @doc """
  Replaces the spreadsheet id with a placeholder, drops the keys that name
  people, and blanks anything that still looks like an email address.

  A test tab's number is replaced too. It is different on every run and means
  nothing to the fixture, so leaving it in would make each recording show up as
  a change to a file that had not really changed.
  """
  @spec scrub(term(), String.t()) :: term()
  def scrub(value, spreadsheet_id)

  def scrub(map, id) when is_map(map) do
    for {key, value} <- map, key not in @secret_keys, into: %{} do
      {key, scrub(value, id)}
    end
  end

  def scrub(list, id) when is_list(list), do: Enum.map(list, &scrub(&1, id))

  def scrub(string, id) when is_binary(string) do
    string
    |> String.replace(id, "SPREADSHEET_ID")
    |> String.replace(@email, "someone@example.test")
    |> String.replace(@tab, "sheetshow N")
  end

  def scrub(other, _id), do: other

  @doc """
  Writes a scrubbed answer to `test/fixtures/<name>.json`, but only when
  `SHEETSHOW_RECORD_FIXTURES` is set, since an integration run should not rewrite
  what is committed unless it was asked to.
  """
  @spec record(String.t(), term(), String.t()) :: :ok
  def record(name, answer, spreadsheet_id) do
    if System.get_env("SHEETSHOW_RECORD_FIXTURES") do
      File.mkdir_p!(Path.dirname(path(name)))
      File.write!(path(name), JSON.encode!(scrub(answer, spreadsheet_id)))
    end

    :ok
  end

  @doc "Reads a recorded answer back, or nil when it was never recorded."
  @spec read(String.t()) :: map() | nil
  def read(name) do
    case File.read(path(name)) do
      {:ok, json} -> JSON.decode!(json)
      {:error, _} -> nil
    end
  end

  @doc "Where a recorded answer lives."
  @spec path(String.t()) :: String.t()
  def path(name), do: Path.join(["test", "fixtures", "#{name}.json"])
end
