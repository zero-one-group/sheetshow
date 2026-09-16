defmodule Sheetshow.Value do
  @moduledoc """
  What a cell can hold.

  | Kind        | Elixir                                              | In Sheets            |
  |-------------|-----------------------------------------------------|----------------------|
  | `:empty`    | `nil`                                               | an empty cell        |
  | `:number`   | `integer()` or `float()`                            | a number (a double)  |
  | `:string`   | `String.t()`                                        | text                 |
  | `:boolean`  | `true` or `false`                                   | TRUE / FALSE         |
  | `:formula`  | `{:formula, "=SUM(A1:A9)"}`                         | a formula            |
  | `:date`     | `Date.t()`                                          | a serial number      |
  | `:datetime` | `NaiveDateTime.t()` or `DateTime.t()`               | a serial number      |
  | `:time`     | `Time.t()`                                          | a serial number      |

  Sheets keeps dates as days since 1899-12-30 with the time of day as the
  fraction, and shows them as dates only through a number format. Writers use
  `to_serial/1` and `default_number_format/1`; readers use `from_serial/2`.
  A `DateTime` is written as its own wall-clock time with the zone dropped, so
  what you see in Elixir is what you see in the sheet.

  Integers beyond 2^53 and `Decimal`s do not survive a double; store them as
  strings.
  """

  alias Sheetshow.Error

  @type kind :: :empty | :number | :string | :boolean | :formula | :date | :datetime | :time

  @type t ::
          nil
          | number()
          | String.t()
          | boolean()
          | {:formula, String.t()}
          | Date.t()
          | NaiveDateTime.t()
          | DateTime.t()
          | Time.t()

  @epoch ~D[1899-12-30]
  @ms_per_day 86_400_000

  @doc """
  The kind of a valid value. Raises `ArgumentError` for anything else; use
  `validate/1` for the checked version.

      iex> Sheetshow.Value.kind(2.5)
      :number
      iex> Sheetshow.Value.kind({:formula, "=A1*2"})
      :formula
      iex> Sheetshow.Value.kind(~N[2026-09-12 08:30:00])
      :datetime
  """
  @spec kind(t()) :: kind()
  def kind(nil), do: :empty
  def kind(v) when is_number(v), do: :number
  def kind(v) when is_binary(v), do: :string
  def kind(v) when is_boolean(v), do: :boolean
  def kind({:formula, "=" <> _}), do: :formula
  def kind(%Date{}), do: :date
  def kind(%NaiveDateTime{}), do: :datetime
  def kind(%DateTime{}), do: :datetime
  def kind(%Time{}), do: :time

  def kind(other) do
    raise ArgumentError, "not a cell value: #{inspect(other)}"
  end

  @doc """
  Checks a value.

      iex> Sheetshow.Value.validate("hello")
      :ok
      iex> {:error, %Sheetshow.Error{reason: :invalid_value}} = Sheetshow.Value.validate({:formula, "SUM(A1)"})
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(value) do
    if valid?(value) do
      :ok
    else
      why =
        case value do
          {:formula, _} ->
            "a formula must start with \"=\""

          _ ->
            "expected nil, a number, string, boolean, {:formula, \"=...\"}, Date, NaiveDateTime, DateTime or Time"
        end

      {:error,
       Error.new(:invalid_value, "invalid cell value #{inspect(value)}: #{why}", value: value)}
    end
  end

  @doc "Whether the term is a cell value."
  @spec valid?(term()) :: boolean()
  def valid?(nil), do: true
  def valid?(v) when is_number(v) or is_binary(v) or is_boolean(v), do: true
  def valid?({:formula, "=" <> _}), do: true
  def valid?(%struct{}) when struct in [Date, NaiveDateTime, DateTime, Time], do: true
  def valid?(_), do: false

  @doc """
  A temporal value as a Sheets serial number.

      iex> Sheetshow.Value.to_serial(~D[1970-01-01])
      25569
      iex> Sheetshow.Value.to_serial(~N[2024-01-01 12:00:00])
      45292.5
      iex> Sheetshow.Value.to_serial(~T[06:00:00])
      0.25
  """
  @spec to_serial(Date.t() | NaiveDateTime.t() | DateTime.t() | Time.t()) :: number()
  def to_serial(%Date{} = date), do: Date.diff(date, @epoch)
  def to_serial(%DateTime{} = dt), do: dt |> DateTime.to_naive() |> to_serial()

  def to_serial(%NaiveDateTime{} = ndt) do
    to_serial(NaiveDateTime.to_date(ndt)) + to_serial(NaiveDateTime.to_time(ndt))
  end

  def to_serial(%Time{} = time) do
    {seconds, micros} = Time.to_seconds_after_midnight(time)
    (seconds * 1_000_000 + micros) / (@ms_per_day * 1000)
  end

  @doc """
  A serial number back to a `Date`, `NaiveDateTime` or `Time`, rounded to the
  millisecond. Sub-second parts keep millisecond precision; whole seconds come
  back with none, so a second-precision value round-trips as `==`.

      iex> Sheetshow.Value.from_serial(25569, :date)
      ~D[1970-01-01]
      iex> Sheetshow.Value.from_serial(45292.5, :datetime)
      ~N[2024-01-01 12:00:00]
      iex> Sheetshow.Value.from_serial(0.25, :time)
      ~T[06:00:00]
  """
  @spec from_serial(number(), :date | :datetime | :time) ::
          Date.t() | NaiveDateTime.t() | Time.t()
  def from_serial(serial, kind) when is_number(serial) do
    total_ms = round(serial * @ms_per_day)
    days = Integer.floor_div(total_ms, @ms_per_day)
    ms = Integer.mod(total_ms, @ms_per_day)

    case kind do
      :date -> Date.add(@epoch, days)
      :time -> time_from_ms(ms)
      :datetime -> NaiveDateTime.new!(Date.add(@epoch, days), time_from_ms(ms))
    end
  end

  defp time_from_ms(ms) do
    precision = if rem(ms, 1000) == 0, do: 0, else: 3
    Time.from_seconds_after_midnight(div(ms, 1000), {rem(ms, 1000) * 1000, precision})
  end

  @doc """
  The number format that makes a temporal value readable in Sheets, or `nil`
  for values that need none. Writers apply it when a cell's style has no
  `:number_format` of its own.

      iex> Sheetshow.Value.default_number_format(~D[2026-09-12])
      "yyyy-mm-dd"
      iex> Sheetshow.Value.default_number_format(42)
      nil
  """
  @spec default_number_format(t()) :: String.t() | nil
  def default_number_format(value) do
    case kind(value) do
      :date -> "yyyy-mm-dd"
      :datetime -> "yyyy-mm-dd hh:mm:ss"
      :time -> "hh:mm:ss"
      _ -> nil
    end
  end
end
