defmodule ExWebp.Exif do
  @moduledoc """
  Minimal EXIF (TIFF) encoder and decoder for the fields that are useful when storing an image.

  Fields are given as a map of key to value. Keys can be atoms or strings, in any of the
  forms `:date_time_original`, `"date_time_original"` or `"DateTimeOriginal"`.

  | Key                                          | Value                                      |
  | -------------------------------------------- | ------------------------------------------ |
  | `:image_description`, `:make`, `:model`      | string                                     |
  | `:software`, `:artist`, `:copyright`         | string                                     |
  | `:orientation`                               | integer 1..8                               |
  | `:date_time`, `:date_time_original`          | `DateTime`, `NaiveDateTime` or a string    |
  | `:date_time_digitized`                       | `DateTime`, `NaiveDateTime` or a string    |
  | `:user_comment`, `:image_unique_id`          | string                                     |
  | `:gps_latitude`, `:gps_longitude`            | number, signed degrees                     |
  | `:gps_altitude`                              | number, metres (negative is below sea)     |
  | `:detections`                                | list of maps, see below                    |

  ## Detections

  `:detections` is a list of maps (atom or string keys, JSON encodable values) that is stored as
  JSON in the `UserComment`, together with a plain `:user_comment` when there is one:

      {"v":1,"comment":"Job 123","detections":[{"class":"cod","confidence":0.93,"x":12,...}]}

  Floats are rounded to 4 decimals. `decode/1` gives the list back as `:detections` with atom
  keys for the keys it knows (`class`, `confidence`, `x`, `y`, `width`, `height`, `angle`, `area`,
  `id`) and string keys for the rest. The whole EXIF has to fit in 64 KB, a few hundred detections.
  """

  @ifd0 [
    {:image_description, 0x010E, :ascii},
    {:make, 0x010F, :ascii},
    {:model, 0x0110, :ascii},
    {:orientation, 0x0112, :short},
    {:software, 0x0131, :ascii},
    {:date_time, 0x0132, :datetime},
    {:artist, 0x013B, :ascii},
    {:copyright, 0x8298, :ascii}
  ]

  @exif [
    {:date_time_original, 0x9003, :datetime},
    {:date_time_digitized, 0x9004, :datetime},
    {:user_comment, 0x9286, :comment},
    {:image_unique_id, 0xA420, :ascii}
  ]

  @gps_keys [:gps_latitude, :gps_longitude, :gps_altitude]

  @max_size 65_000
  @known_detection_keys ~w(class confidence x y width height angle area id)

  @exif_pointer 0x8769
  @gps_pointer 0x8825

  @type fields :: %{optional(atom() | String.t()) => term()}

  @doc "Encodes a map of fields into a TIFF structured EXIF binary."
  @spec encode(fields()) :: {:ok, binary()} | {:error, String.t()}
  def encode(fields) when is_map(fields) do
    with {:ok, fields} <- normalize(fields),
         {:ok, fields} <- merge_detections(fields),
         {:ok, ifd0} <- entries(fields, @ifd0),
         {:ok, exif} <- entries(fields, @exif),
         {:ok, gps} <- gps_entries(fields) do
      cond do
        ifd0 == [] and exif == [] and gps == [] -> {:error, "No EXIF fields provided"}
        true -> check_size(layout(ifd0, exif, gps))
      end
    end
  end

  @doc "Decodes an EXIF binary (TIFF structure) into a map with atom keys."
  @spec decode(binary()) :: {:ok, fields()} | {:error, String.t()}
  def decode(<<order::binary-2, _::binary>> = tiff) when order in ["II", "MM"] do
    endian = if order == "II", do: :little, else: :big

    with {:ok, 42} <- read(tiff, 2, 2, endian),
         {:ok, offset} <- read(tiff, 4, 4, endian),
         {:ok, ifd0} <- read_ifd(tiff, offset, endian) do
      exif = sub_ifd(tiff, ifd0, @exif_pointer, endian)
      gps = sub_ifd(tiff, ifd0, @gps_pointer, endian)

      {:ok,
       (decode_known(ifd0, @ifd0, tiff, endian) ++
          decode_known(exif, @exif, tiff, endian) ++ decode_gps(gps, tiff, endian))
       |> Map.new()
       |> split_detections()}
    else
      _ -> {:error, "Invalid EXIF data"}
    end
  end

  def decode(_), do: {:error, "Invalid EXIF data"}

  # --- Encoding ---

  defp check_size(tiff) when byte_size(tiff) > @max_size,
    do: {:error, "EXIF data is too large (#{byte_size(tiff)} B, max #{@max_size} B)"}

  defp check_size(tiff), do: {:ok, tiff}

  # The detections go in the UserComment as JSON, next to a comment given as text
  defp merge_detections(%{detections: detections} = fields) when is_list(detections) do
    document =
      %{"v" => 1, "detections" => Enum.map(detections, &json_value/1)}
      |> then(fn doc ->
        case Map.fetch(fields, :user_comment) do
          {:ok, comment} when is_binary(comment) -> Map.put(doc, "comment", comment)
          _ -> doc
        end
      end)

    {:ok, fields |> Map.delete(:detections) |> Map.put(:user_comment, JSON.encode!(document))}
  rescue
    _ -> {:error, "Invalid value for EXIF key `detections`"}
  end

  defp merge_detections(%{detections: _}), do: {:error, "Invalid value for EXIF key `detections`"}
  defp merge_detections(fields), do: {:ok, fields}

  defp json_value(value) when is_float(value), do: Float.round(value, 4)
  defp json_value(%_{} = struct), do: raise(ArgumentError, "unsupported #{inspect(struct)}")

  defp json_value(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_value(value)} end)

  defp json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  defp json_value(value), do: value

  defp normalize(fields) do
    known = Enum.map(@ifd0 ++ @exif, &elem(&1, 0)) ++ @gps_keys ++ [:detections]

    Enum.reduce_while(fields, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      name =
        key
        |> to_string()
        |> Macro.underscore()
        |> String.replace("-", "_")

      case Enum.find(known, &(Atom.to_string(&1) == name)) do
        nil -> {:halt, {:error, "Unknown EXIF key `#{key}`"}}
        name -> {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp entries(fields, table) do
    Enum.reduce_while(table, {:ok, []}, fn {name, tag, kind}, {:ok, acc} ->
      case Map.fetch(fields, name) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case value_entry(tag, kind, value) do
            {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
            :error -> {:halt, {:error, "Invalid value for EXIF key `#{name}`"}}
          end
      end
    end)
  end

  defp value_entry(tag, :ascii, value) when is_binary(value), do: {:ok, ascii(tag, value)}

  defp value_entry(tag, :datetime, %DateTime{} = value),
    do: value_entry(tag, :datetime, DateTime.to_naive(value))

  defp value_entry(tag, :datetime, %NaiveDateTime{} = value),
    do: {:ok, ascii(tag, Calendar.strftime(value, "%Y:%m:%d %H:%M:%S"))}

  defp value_entry(tag, :datetime, value) when is_binary(value), do: {:ok, ascii(tag, value)}

  defp value_entry(tag, :comment, value) when is_binary(value) do
    data = "ASCII\0\0\0" <> value
    {:ok, {tag, 7, byte_size(data), data}}
  end

  defp value_entry(tag, :short, value) when is_integer(value) and value in 0..65_535,
    do: {:ok, {tag, 3, 1, <<value::16-little>>}}

  defp value_entry(_, _, _), do: :error

  defp ascii(tag, value) do
    data = value <> <<0>>
    {tag, 2, byte_size(data), data}
  end

  defp gps_entries(fields) do
    with {:ok, lat} <- coordinate(fields, :gps_latitude, 0x0001, "N", "S", 0x0002),
         {:ok, lon} <- coordinate(fields, :gps_longitude, 0x0003, "E", "W", 0x0004),
         {:ok, alt} <- altitude(fields) do
      {:ok, lat ++ lon ++ alt}
    end
  end

  defp coordinate(fields, name, ref_tag, positive, negative, tag) do
    case Map.fetch(fields, name) do
      :error ->
        {:ok, []}

      {:ok, value} when is_number(value) ->
        abs_value = abs(value / 1)
        degrees = trunc(abs_value)
        minutes = trunc((abs_value - degrees) * 60)
        seconds = ((abs_value - degrees) * 60 - minutes) * 60

        data =
          rational(degrees, 1) <>
            rational(minutes, 1) <> rational(round(seconds * 10_000), 10_000)

        {:ok, [ascii(ref_tag, if(value >= 0, do: positive, else: negative)), {tag, 5, 3, data}]}

      _ ->
        {:error, "Invalid value for EXIF key `#{name}`"}
    end
  end

  defp altitude(fields) do
    case Map.fetch(fields, :gps_altitude) do
      :error ->
        {:ok, []}

      {:ok, value} when is_number(value) ->
        {:ok,
         [
           {0x0005, 1, 1, <<if(value < 0, do: 1, else: 0)>>},
           {0x0006, 5, 1, rational(round(abs(value) * 1000), 1000)}
         ]}

      _ ->
        {:error, "Invalid value for EXIF key `gps_altitude`"}
    end
  end

  defp rational(numerator, denominator), do: <<numerator::32-little, denominator::32-little>>

  # Header | IFD0 | Exif IFD | GPS IFD, each followed by its out of line data. The pointers in
  # IFD0 need the offsets of the other two, which only depend on their sizes.
  defp layout(ifd0, exif, gps) do
    pointers =
      Enum.reject(
        [{@exif_pointer, exif}, {@gps_pointer, gps}],
        fn {_, entries} -> entries == [] end
      )

    placeholders = Enum.map(pointers, fn {tag, _} -> {tag, 4, 1, <<0::32>>} end)
    exif_offset = 8 + ifd_size(ifd0 ++ placeholders)
    gps_offset = exif_offset + if(exif == [], do: 0, else: ifd_size(exif))

    offsets = %{@exif_pointer => exif_offset, @gps_pointer => gps_offset}

    ifd0 =
      ifd0 ++ Enum.map(pointers, fn {tag, _} -> {tag, 4, 1, <<offsets[tag]::32-little>>} end)

    IO.iodata_to_binary([
      "II",
      <<42::16-little, 8::32-little>>,
      encode_ifd(ifd0, 8),
      if(exif == [], do: [], else: encode_ifd(exif, exif_offset)),
      if(gps == [], do: [], else: encode_ifd(gps, gps_offset))
    ])
  end

  defp ifd_size(entries) do
    out_of_line =
      for {_, _, _, data} <- entries, byte_size(data) > 4, reduce: 0 do
        acc -> acc + pad_even(byte_size(data))
      end

    2 + 12 * length(entries) + 4 + out_of_line
  end

  defp encode_ifd(entries, offset) do
    entries = Enum.sort_by(entries, &elem(&1, 0))
    data_offset = offset + 2 + 12 * length(entries) + 4

    {fields, data, _} =
      Enum.reduce(entries, {[], [], data_offset}, fn {tag, type, count, value}, {f, d, next} ->
        if byte_size(value) <= 4 do
          padded = value <> :binary.copy(<<0>>, 4 - byte_size(value))
          {[<<tag::16-little, type::16-little, count::32-little, padded::binary>> | f], d, next}
        else
          field = <<tag::16-little, type::16-little, count::32-little, next::32-little>>
          padded = value <> :binary.copy(<<0>>, pad_even(byte_size(value)) - byte_size(value))
          {[field | f], [padded | d], next + byte_size(padded)}
        end
      end)

    [<<length(entries)::16-little>>, Enum.reverse(fields), <<0::32>>, Enum.reverse(data)]
  end

  defp pad_even(size), do: size + rem(size, 2)

  # --- Decoding ---

  defp split_detections(%{user_comment: comment} = fields) do
    with {:ok, %{"detections" => detections} = document} when is_list(detections) <-
           JSON.decode(comment) do
      fields = Map.delete(fields, :user_comment)
      fields = if c = document["comment"], do: Map.put(fields, :user_comment, c), else: fields
      Map.put(fields, :detections, Enum.map(detections, &atomize/1))
    else
      _ -> fields
    end
  end

  defp split_detections(fields), do: fields

  defp atomize(%{} = detection) do
    Map.new(detection, fn {key, value} ->
      {if(key in @known_detection_keys, do: String.to_atom(key), else: key), value}
    end)
  end

  defp atomize(value), do: value

  defp uint(bin, :little), do: :binary.decode_unsigned(bin, :little)
  defp uint(bin, :big), do: :binary.decode_unsigned(bin, :big)

  defp read(bin, offset, size, endian) do
    case bin do
      <<_::binary-size(offset), value::binary-size(size), _::binary>> ->
        {:ok, uint(value, endian)}

      _ ->
        :error
    end
  end

  defp read_ifd(tiff, offset, endian) do
    with {:ok, count} <- read(tiff, offset, 2, endian) do
      entries =
        for i <- 0..(count - 1)//1 do
          base = offset + 2 + i * 12
          {:ok, tag} = read(tiff, base, 2, endian)
          {:ok, type} = read(tiff, base + 2, 2, endian)
          {:ok, n} = read(tiff, base + 4, 4, endian)
          {tag, type, n, base + 8}
        end

      {:ok, entries}
    end
  rescue
    MatchError -> :error
  end

  defp sub_ifd(tiff, ifd, pointer, endian) do
    with {_, _, _, field} <- List.keyfind(ifd, pointer, 0),
         {:ok, offset} <- read(tiff, field, 4, endian),
         {:ok, entries} <- read_ifd(tiff, offset, endian) do
      entries
    else
      _ -> []
    end
  end

  defp type_size(3), do: 2
  defp type_size(4), do: 4
  defp type_size(5), do: 8
  defp type_size(_), do: 1

  # The raw bytes of a value, inline in the entry when it fits in 4 bytes
  defp raw({_tag, type, count, field}, tiff, endian) do
    size = type_size(type) * count

    offset =
      if size <= 4 do
        field
      else
        {:ok, offset} = read(tiff, field, 4, endian)
        offset
      end

    case tiff do
      <<_::binary-size(offset), data::binary-size(size), _::binary>> -> data
      _ -> <<>>
    end
  end

  defp decode_known(entries, table, tiff, endian) do
    for {name, tag, kind} <- table,
        entry = List.keyfind(entries, tag, 0),
        entry != nil,
        {:ok, value} <- [decode_value(kind, raw(entry, tiff, endian), endian)] do
      {name, value}
    end
  end

  defp decode_value(kind, data, _) when kind in [:ascii, :datetime],
    do: {:ok, String.trim_trailing(data, <<0>>)}

  defp decode_value(:comment, <<_prefix::binary-8, value::binary>>, _),
    do: {:ok, String.trim_trailing(value, <<0>>)}

  defp decode_value(:short, data, endian), do: {:ok, uint(data, endian)}

  defp decode_value(_, _, _), do: :error

  defp decode_gps(entries, tiff, endian) do
    ascii = fn tag ->
      with entry when not is_nil(entry) <- List.keyfind(entries, tag, 0),
           do: String.trim_trailing(raw(entry, tiff, endian), <<0>>)
    end

    coordinate = fn name, ref_tag, tag, negative ->
      with entry when not is_nil(entry) <- List.keyfind(entries, tag, 0),
           [d, m, s] <- rationals(raw(entry, tiff, endian), endian) do
        value = d + m / 60 + s / 3600
        [{name, if(ascii.(ref_tag) == negative, do: -value, else: value)}]
      else
        _ -> []
      end
    end

    altitude =
      with entry when not is_nil(entry) <- List.keyfind(entries, 0x0006, 0),
           [value] <- rationals(raw(entry, tiff, endian), endian) do
        below? =
          case List.keyfind(entries, 0x0005, 0) do
            nil -> false
            ref -> raw(ref, tiff, endian) == <<1>>
          end

        [{:gps_altitude, if(below?, do: -value, else: value)}]
      else
        _ -> []
      end

    coordinate.(:gps_latitude, 0x0001, 0x0002, "S") ++
      coordinate.(:gps_longitude, 0x0003, 0x0004, "W") ++ altitude
  end

  defp rationals(data, endian) do
    for <<n::binary-4, d::binary-4 <- data>> do
      {n, d} = {uint(n, endian), uint(d, endian)}
      if d == 0, do: 0.0, else: n / d
    end
  end
end
