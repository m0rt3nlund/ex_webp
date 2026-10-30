defmodule ExWebp do
  @moduledoc """
  A Fastest WebP image creator for Elixir.
  Originally created by https://github.com/ryochin
  """

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ex_webp,
    crate: "ex_webp",
    force_build: System.get_env("EXWEBP_COMPILE") in ["1", "true"],
    base_url: "https://github.com/m0rt3nlund/ex_webp/releases/download/v#{version}",
    version: version

  @spec encode(body :: binary(), opts :: Keyword.t()) ::
          {:ok, binary()}
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
         {:ok, encode_opts} <- verify_crop_options(encode_opts, Keyword.get(opts, :crop, nil)),
         {:ok, webp} <- _encode(body, encode_opts) do
      case Keyword.get(opts, :exif) do
        nil -> {:ok, webp}
        exif -> put_exif(webp, exif)
      end
    end
  end

  @doc """
  Adds EXIF data to an existing WebP image, replacing any EXIF data already in it.

  `exif` is a map of fields, see `ExWebp.Exif`, or an already encoded EXIF (TIFF) binary.
  The image data itself is not touched, only the RIFF container is rewritten.

      {:ok, webp} = ExWebp.put_exif(webp, %{date_time_original: DateTime.utc_now(), make: "Maskon"})
  """
  @spec put_exif(webp :: binary(), exif :: ExWebp.Exif.fields() | binary()) ::
          {:ok, binary()} | {:error, String.t()}
  def put_exif(webp, exif) when is_map(exif) do
    with {:ok, exif} <- ExWebp.Exif.encode(exif), do: put_exif(webp, exif)
  end

  def put_exif(webp, exif) when is_binary(webp) and is_binary(exif),
    do: ExWebp.Container.put_exif(webp, exif)

  @doc "Reads the EXIF data of a WebP image as a map, see `ExWebp.Exif`."
  @spec get_exif(webp :: binary()) :: {:ok, ExWebp.Exif.fields()} | :error | {:error, String.t()}
  def get_exif(webp) do
    with {:ok, exif} <- get_exif_binary(webp), do: ExWebp.Exif.decode(exif)
  end

  @doc "Reads the raw EXIF (TIFF) binary of a WebP image."
  @spec get_exif_binary(webp :: binary()) :: {:ok, binary()} | :error | {:error, String.t()}
  def get_exif_binary(webp), do: ExWebp.Container.get_exif(webp)

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
