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
    encode_opts = %{
      width: abs(Keyword.get(opts, :width, 0)),
      height: abs(Keyword.get(opts, :height, 0)),
      lossless: if(Keyword.get(opts, :lossless, false), do: 1, else: 0),
      resize_percent: abs(Keyword.get(opts, :resize_percent, 0.0))
    }

    with {:ok, encode_opts} <-
           verify_quality_options(encode_opts, Keyword.get(opts, :quality, 50)),
         {:ok, encode_opts} <- verify_crop_options(encode_opts, Keyword.get(opts, :crop, nil)) do
      _encode(
        body,
        encode_opts
      )
    end
  end

  defp verify_quality_options(opts, quality) when is_float(quality),
    do: {:ok, Map.put(opts, :quality, quality)}

  defp verify_quality_options(opts, quality) when is_integer(quality),
    do: {:ok, Map.put(opts, :quality, quality / 1)}

  defp verify_quality_options(_opts, _quality),
    do: {:error, "Invalid quality parameter provided"}

  defp verify_crop_options(opts, nil), do: {:ok, Map.put(opts, :crop, :undefined)}

  defp verify_crop_options(opts, %{x: x, y: y, width: width, height: height}) do
    {:ok, Map.put(opts, :crop, %{x: abs(x), y: abs(y), width: abs(width), height: abs(height)})}
  end

  defp verify_crop_options(_opts, _), do: {:error, "Invalid crop options"}

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
