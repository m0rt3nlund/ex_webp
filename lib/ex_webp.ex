defmodule ExWebp do
  @moduledoc """
  A Fastest WebP image creator for Elixir.
  Originally created by https://github.com/ryochin
  """

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ex_webp,
    crate: "ex_webp",
    force_build: System.get_env("RUSTLER_COMPILE") in ["1", "true"],
    base_url: "https://github.com/m0rt3nlund/ex_webp/releases/download/v#{version}",
    version: version

  @spec encode(body :: binary, opts :: Keyword.t()) ::
          {:ok, :binary}
          | {:error, String.t()}
  def encode(body, opts) do
    width = Keyword.get(opts, :width, 0)
    height = Keyword.get(opts, :height, 0)
    resize_percent = Keyword.get(opts, :resize_percent, 0.0)

    with {:ok, quality} <- verify_quality(Keyword.get(opts, :quality, 50)) do
      lossless = if Keyword.get(opts, :lossless, false), do: 1, else: 0

      _encode(
        body,
        %{
          width: width,
          height: height,
          resize_percent: resize_percent,
          lossless: lossless,
          quality: quality
        }
      )
    end
  end

  defp verify_quality(quality) when is_float(quality), do: {:ok, quality}
  defp verify_quality(quality) when is_integer(quality), do: {:ok, quality / 1}

  defp verify_quality(quality) when is_integer(quality),
    do: {:error, "Invalid quality parameter provided"}

  @spec decode(body :: binary) ::
          {:ok, :binary}
          | {:error, String.t()}
  def decode(body) do
    _decode(body)
  end

  # NIF function definition
  @spec _encode(
          body :: binary,
          config :: map
        ) ::
          {:ok, binary} | {:error, String.t()}
  defp _encode(_body, _config),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec _decode(body :: binary) ::
          {:ok, binary} | {:error, String.t()}
  defp _decode(_body),
    do: :erlang.nif_error(:nif_not_loaded)
end
