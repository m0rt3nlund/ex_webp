defmodule ExWebp.ExifTest do
  use ExUnit.Case, async: true

  # Adding EXIF only rewrites the container, so it should be very cheap compared to encoding
  @iterations 200
  @max_avg_microseconds 5_000

  @fields %{
    make: "Maskon",
    model: "mvision",
    software: "mvision_app",
    image_description: "Job 123",
    orientation: 1,
    date_time_original: ~U[2026-10-30 13:45:10Z],
    user_comment: "reference=store",
    gps_latitude: 59.9139,
    gps_longitude: -10.7522,
    gps_altitude: 12.5
  }

  setup_all do
    bmp = File.read!("./test/assets/images/sample.bmp")
    {:ok, lossy} = ExWebp.encode(bmp, quality: 50)
    {:ok, lossless} = ExWebp.encode(bmp, lossless: true)
    {:ok, lossy: lossy, lossless: lossless, bmp: bmp}
  end

  defp avg_microseconds(fun) do
    {total, _} = :timer.tc(fn -> for _ <- 1..@iterations, do: fun.() end)
    total / @iterations
  end

  describe "round trip" do
    test "lossy image without VP8X", %{lossy: webp} do
      assert :error = ExWebp.get_exif(webp)
      assert {:ok, with_exif} = ExWebp.put_exif(webp, @fields)
      assert {:ok, exif} = ExWebp.get_exif(with_exif)

      assert exif.make == "Maskon"
      assert exif.software == "mvision_app"
      assert exif.orientation == 1
      assert exif.date_time_original == "2026:10:30 13:45:10"
      assert exif.user_comment == "reference=store"
      assert_in_delta exif.gps_latitude, 59.9139, 0.0001
      assert_in_delta exif.gps_longitude, -10.7522, 0.0001
      assert_in_delta exif.gps_altitude, 12.5, 0.001
    end

    test "lossless image with string keys", %{lossless: webp} do
      assert {:ok, with_exif} = ExWebp.put_exif(webp, %{"Make" => "Maskon"})
      assert {:ok, %{make: "Maskon"}} = ExWebp.get_exif(with_exif)
    end

    test "image still decodes with the same pixels", %{lossless: webp} do
      assert {:ok, with_exif} = ExWebp.put_exif(webp, @fields)
      assert {:ok, original} = ExWebp.decode(webp)
      assert {:ok, ^original} = ExWebp.decode(with_exif)
    end

    test "replaces existing exif and keeps VP8X valid", %{lossy: webp} do
      {:ok, first} = ExWebp.put_exif(webp, %{make: "One", model: "x"})
      {:ok, second} = ExWebp.put_exif(first, %{make: "Two"})

      assert {:ok, %{make: "Two"} = exif} = ExWebp.get_exif(second)
      refute Map.has_key?(exif, :model)

      {:ok, chunks} = ExWebp.Container.chunks(second)
      assert [{"VP8X", <<flags, 0::24, _::binary>>} | _] = chunks
      assert Bitwise.band(flags, 0x08) == 0x08
      assert Enum.count(chunks, &match?({"EXIF", _}, &1)) == 1
    end

    test "VP8X canvas matches the image", %{lossless: webp, bmp: bmp} do
      {:ok, with_exif} = ExWebp.put_exif(webp, %{make: "x"})

      {:ok, [{"VP8X", <<_, 0::24, w::24-little, h::24-little>>} | _]} =
        ExWebp.Container.chunks(with_exif)

      <<"BM", _::binary-size(16), bmp_w::32-little, bmp_h::32-little-signed, _::binary>> = bmp
      assert {w + 1, h + 1} == {bmp_w, abs(bmp_h)}
    end

    test "encode/2 with the :exif option", %{bmp: bmp} do
      assert {:ok, webp} = ExWebp.encode(bmp, quality: 50, exif: %{make: "Maskon"})
      assert {:ok, %{make: "Maskon"}} = ExWebp.get_exif(webp)
    end

    test "accepts a ready made binary", %{lossy: webp} do
      {:ok, tiff} = ExWebp.Exif.encode(%{make: "Maskon"})
      assert {:ok, with_exif} = ExWebp.put_exif(webp, tiff)
      assert {:ok, ^tiff} = ExWebp.get_exif_binary(with_exif)
    end
  end

  describe "errors" do
    test "unknown key, invalid value and empty map", %{lossy: webp} do
      assert {:error, "Unknown EXIF key `nope`"} = ExWebp.put_exif(webp, %{nope: 1})
      assert {:error, "Invalid value for EXIF key `make`"} = ExWebp.put_exif(webp, %{make: 1})
      assert {:error, "No EXIF fields provided"} = ExWebp.put_exif(webp, %{})
    end

    test "not a WebP" do
      assert {:error, "Invalid WebP data"} = ExWebp.put_exif("nope", %{make: "x"})
    end
  end

  describe "timing" do
    test "adding exif is fast", %{lossy: lossy, lossless: lossless, bmp: bmp} do
      {:ok, tiff} = ExWebp.Exif.encode(@fields)

      lossy_avg = avg_microseconds(fn -> {:ok, _} = ExWebp.put_exif(lossy, @fields) end)
      lossless_avg = avg_microseconds(fn -> {:ok, _} = ExWebp.put_exif(lossless, @fields) end)
      binary_avg = avg_microseconds(fn -> {:ok, _} = ExWebp.put_exif(lossless, tiff) end)
      encode_avg = avg_microseconds(fn -> {:ok, _} = ExWebp.encode(bmp, quality: 50) end)

      IO.puts("""

      put_exif, average of #{@iterations} runs (#{byte_size(lossy)} B lossy, #{byte_size(lossless)} B lossless):
        lossy, map        #{Float.round(lossy_avg, 1)} µs
        lossless, map     #{Float.round(lossless_avg, 1)} µs
        lossless, binary  #{Float.round(binary_avg, 1)} µs
        encode (compare)  #{Float.round(encode_avg, 1)} µs
      """)

      assert lossy_avg < @max_avg_microseconds
      assert lossless_avg < @max_avg_microseconds
      assert binary_avg < @max_avg_microseconds
    end
  end
end
