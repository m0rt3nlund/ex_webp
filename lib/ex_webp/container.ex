defmodule ExWebp.Container do
  @moduledoc false
  # Edits the RIFF container of a WebP file without touching the image data.

  import Bitwise

  @exif_flag 0x08
  @alpha_flag 0x10

  @spec chunks(binary()) :: {:ok, [{binary(), binary()}]} | {:error, String.t()}
  def chunks(<<"RIFF", size::32-little, "WEBP", rest::binary>>) when size >= 4 do
    {:ok, parse(rest, [])}
  catch
    :invalid -> {:error, "Invalid WebP data"}
  end

  def chunks(_), do: {:error, "Invalid WebP data"}

  @spec build([{binary(), binary()}]) :: binary()
  def build(chunks) do
    body = for {cc, payload} <- chunks, into: <<>>, do: chunk(cc, payload)
    <<"RIFF", byte_size(body) + 4::32-little, "WEBP", body::binary>>
  end

  @doc "Sets the EXIF chunk, replacing an existing one, and the matching flag in `VP8X`."
  @spec put_exif(binary(), binary()) :: {:ok, binary()} | {:error, String.t()}
  def put_exif(webp, exif) do
    with {:ok, chunks} <- chunks(webp),
         {:ok, chunks} <- ensure_vp8x(Enum.reject(chunks, &match?({"EXIF", _}, &1))) do
      [{"VP8X", <<flags, rest::binary>>} | tail] = chunks
      {:ok, build([{"VP8X", <<flags ||| @exif_flag, rest::binary>>} | tail] ++ [{"EXIF", exif}])}
    end
  end

  @spec get_exif(binary()) :: {:ok, binary()} | :error | {:error, String.t()}
  def get_exif(webp) do
    with {:ok, chunks} <- chunks(webp) do
      case List.keyfind(chunks, "EXIF", 0) do
        {"EXIF", "Exif\0\0" <> exif} -> {:ok, exif}
        {"EXIF", exif} -> {:ok, exif}
        nil -> :error
      end
    end
  end

  defp parse(<<>>, acc), do: Enum.reverse(acc)

  defp parse(<<cc::binary-4, size::32-little, rest::binary>>, acc) do
    padded = size + rem(size, 2)

    case rest do
      <<payload::binary-size(size), _pad::binary-size(padded - size), rest::binary>> ->
        parse(rest, [{cc, payload} | acc])

      # A missing pad byte on the last chunk is tolerated
      <<payload::binary-size(size)>> ->
        parse(<<>>, [{cc, payload} | acc])

      _ ->
        throw(:invalid)
    end
  end

  defp parse(_, _), do: throw(:invalid)

  defp chunk(cc, payload) do
    size = byte_size(payload)
    pad = if rem(size, 2) == 1, do: <<0>>, else: <<>>
    <<cc::binary, size::32-little, payload::binary, pad::binary>>
  end

  defp ensure_vp8x([{"VP8X", _} | _] = chunks), do: {:ok, chunks}

  defp ensure_vp8x(chunks) do
    case Enum.find_value(chunks, &dimensions/1) do
      {width, height, alpha?} ->
        flags = if alpha?, do: @alpha_flag, else: 0
        vp8x = <<flags, 0::24, width - 1::24-little, height - 1::24-little>>
        {:ok, [{"VP8X", vp8x} | chunks]}

      nil ->
        {:error, "Unable to find the image dimensions in the WebP data"}
    end
  end

  defp dimensions({"VP8L", <<0x2F, bits::32-little, _::binary>>}),
    do: {(bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1, (bits >>> 28 &&& 1) == 1}

  defp dimensions(
         {"VP8 ", <<_tag::24, 0x9D, 0x01, 0x2A, w::16-little, h::16-little, _::binary>>}
       ),
       do: {w &&& 0x3FFF, h &&& 0x3FFF, false}

  defp dimensions(_), do: nil
end
