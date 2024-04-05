mix compile
cp priv/native/libex_webp.dll priv/native/
mix rustler_precompiled.download ExWebp --all --print