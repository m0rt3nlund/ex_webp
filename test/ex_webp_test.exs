defmodule ExWebpTest do
  use ExUnit.Case
  doctest ExWebp

  setup_all do
    {:ok, content: File.read!("./test/assets/images/sample.bmp")}
  end

  test "Lossless", %{content: image_content} do
    assert {:ok, _image} = ExWebp.encode(image_content, quality: 1, lossless: true)
  end

  test "Lossless cropped", %{content: image_content} do
    assert {:ok, image_data} =
             ExWebp.encode(image_content,
               lossless: true,
               crop: %{x: 800, y: 100, width: 100, height: 100}
             )
  end
end
