defmodule Sheetshow.Credentials do
  @moduledoc false
  # What `ServiceAccount` and `UserAccount` do alike: read a JSON credential
  # from a file or a string, and say what is wrong with one that will not do.

  alias Sheetshow.Error

  @doc "Reads the file and hands its contents to `from_json`; a path that will not read says so."
  @spec from_file(Path.t(), (String.t() -> {:ok, term()} | {:error, Error.t()})) ::
          {:ok, term()} | {:error, Error.t()}
  def from_file(path, from_json) when is_function(from_json, 1) do
    case File.read(path) do
      {:ok, json} ->
        from_json.(json)

      {:error, reason} ->
        {:error,
         invalid("could not read #{path}: #{List.to_string(:file.format_error(reason))}",
           path: path
         )}
    end
  end

  @doc "The JSON as a map, or an error naming the kind of credential expected."
  @spec decode(String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def decode(json, what) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, invalid("expected the JSON of #{what}")}
    end
  end

  @doc "A non-empty string under `key`, or an error naming the key."
  @spec fetch(map(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def fetch(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, invalid("the credential has no #{key}", key: key)}
    end
  end

  @spec invalid(String.t(), keyword()) :: Error.t()
  def invalid(message, details \\ []), do: Error.new(:invalid_credentials, message, details)
end
